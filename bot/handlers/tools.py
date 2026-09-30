"""Функции бота: дизайн по фото, калькулятор, смета, проверка работы, консультант, КП."""
import logging

from aiogram import Bot, F, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import db, kie
from ..calc import CALCS, parse_numbers
from ..config import FREE_CONSULT_PER_DAY, PRICES
from ..keyboards import after_design_kb, calcs_kb, home_kb, packs_kb, styles_kb
from ..prompts import (CHECK_SYSTEM, CONSULT_SYSTEM, DESIGN_PROMPT, DESIGN_STYLES,
                       ESTIMATE_SYSTEM, KP_SYSTEM)
from ..states import Flow

log = logging.getLogger(__name__)
router = Router()

ERROR_TEXT = "😔 Не получилось, кредиты вернул на баланс. Попробуйте ещё раз чуть позже."


async def send_long(message: Message, text: str, **kw):
    """Отправляет длинный текст частями; если модель сломала HTML — шлёт без разметки."""
    chunks = [text[i:i + 3900] for i in range(0, len(text), 3900)] or [""]
    for i, chunk in enumerate(chunks):
        extra = kw if i == len(chunks) - 1 else {}
        try:
            await message.answer(chunk, **extra)
        except Exception:
            await message.answer(chunk, parse_mode=None, **extra)


async def not_enough(message: Message, need: int):
    await message.answer(
        f"Не хватает кредитов: нужно {need}. Пополните баланс 👇", reply_markup=packs_kb()
    )


async def photo_url(message: Message, bot: Bot) -> str:
    """Скачивает самое большое фото из сообщения и загружает в kie.ai."""
    buf = await bot.download(message.photo[-1].file_id)
    return await kie.upload_image(buf.read(), f"{message.from_user.id}_{message.message_id}.jpg")


async def run_text_job(message: Message, user_id: int, kind: str, system: str, text: str,
                       image_url: str | None = None, cost: int | None = None):
    """Списывает кредиты, вызывает текстовую модель, при ошибке возвращает кредиты."""
    cost = PRICES[kind] if cost is None else cost
    job_id = None
    if cost:
        job_id = await db.charge(user_id, cost, kind)
        if job_id is None:
            return await not_enough(message, cost)
    wait = await message.answer("⏳ Думаю…")
    try:
        answer = await kie.chat(system, text, image_url=image_url)
        if job_id:
            await db.finish_job(job_id, ok=True)
        await wait.delete()
        await send_long(message, answer, reply_markup=home_kb())
    except Exception:
        log.exception("text job %s failed", kind)
        if job_id:
            await db.finish_job(job_id, ok=False)
        try:
            await wait.edit_text(ERROR_TEXT, reply_markup=home_kb())
        except Exception:
            await message.answer(ERROR_TEXT, reply_markup=home_kb())


# ---------- 🛋 Дизайн по фото ----------

@router.callback_query(F.data == "menu:design")
async def design_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.design_photo)
    await cb.message.edit_text(
        "📸 Пришлите фото комнаты — покажу, как она будет выглядеть после ремонта.\n\n"
        "Совет: снимайте из угла, горизонтально, при дневном свете.\n"
        f"Стоимость: {PRICES['design']} кр. за вариант.",
        reply_markup=home_kb(),
    )
    await cb.answer()


@router.message(Flow.design_photo, F.photo)
async def design_photo(message: Message, state: FSMContext, bot: Bot):
    wait = await message.answer("⏳ Загружаю фото…")
    try:
        url = await photo_url(message, bot)
    except Exception:
        log.exception("upload failed")
        return await wait.edit_text("Не удалось загрузить фото, пришлите ещё раз.")
    await state.update_data(photo_url=url, extra=(message.caption or "").strip())
    await state.set_state(Flow.design_style)
    await wait.edit_text(
        "Выберите стиль 👇\n(в подписи к фото можно было указать пожелания — я их учту)",
        reply_markup=styles_kb(),
    )


@router.callback_query(F.data == "design:again")
async def design_again(cb: CallbackQuery, state: FSMContext):
    data = await state.get_data()
    if not data.get("photo_url"):
        return await design_start(cb, state)
    await state.set_state(Flow.design_style)
    await cb.message.answer("Выберите другой стиль 👇", reply_markup=styles_kb())
    await cb.answer()


@router.callback_query(Flow.design_style, F.data.startswith("style:"))
async def design_generate(cb: CallbackQuery, state: FSMContext):
    key = cb.data.split(":", 1)[1]
    name, style = DESIGN_STYLES[key]
    data = await state.get_data()
    await cb.answer()
    job_id = await db.charge(cb.from_user.id, PRICES["design"], "design")
    if job_id is None:
        return await not_enough(cb.message, PRICES["design"])
    extra = f"Client wishes (in Russian): {data['extra']}" if data.get("extra") else ""
    wait = await cb.message.answer(f"🎨 Рисую «{name}»… обычно 20–60 секунд.")
    try:
        urls = await kie.edit_image(data["photo_url"], DESIGN_PROMPT.format(style=style, extra=extra))
        await db.finish_job(job_id, ok=True)
        await wait.delete()
        try:
            await cb.message.answer_photo(urls[0], caption=f"✨ Стиль: <b>{name}</b>",
                                          reply_markup=after_design_kb())
        except Exception:
            await cb.message.answer(f"✨ Стиль: <b>{name}</b>\n{urls[0]}", reply_markup=after_design_kb())
        await state.update_data(last_style=name)
    except Exception:
        log.exception("design failed")
        await db.finish_job(job_id, ok=False)
        await wait.edit_text(ERROR_TEXT, reply_markup=home_kb())


# ---------- 🧮 Калькулятор ----------

@router.callback_query(F.data == "menu:calc")
async def calc_menu(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    await cb.message.edit_text("🧮 Что считаем? (бесплатно)", reply_markup=calcs_kb())
    await cb.answer()


@router.callback_query(F.data.startswith("calc:"))
async def calc_pick(cb: CallbackQuery, state: FSMContext):
    key = cb.data.split(":", 1)[1]
    title, hint, _, _ = CALCS[key]
    await state.set_state(Flow.calc_input)
    await state.update_data(calc=key)
    await cb.message.edit_text(f"{title}\n\n{hint}", reply_markup=calcs_kb())
    await cb.answer()


@router.message(Flow.calc_input, F.text)
async def calc_input(message: Message, state: FSMContext):
    key = (await state.get_data()).get("calc")
    title, hint, min_n, fn = CALCS[key]
    nums = parse_numbers(message.text)
    if len(nums) < min_n or any(n <= 0 for n in nums):
        return await message.answer(f"Не понял числа 🤔\n\n{hint}")
    result = fn(nums)
    await message.answer(
        result.text() + "\n\n<i>Расчёт ориентировочный. Можно ввести новые размеры или выбрать другой материал.</i>",
        reply_markup=calcs_kb(),
    )


# ---------- 📋 Смета ----------

@router.callback_query(F.data == "menu:estimate")
async def estimate_start(cb: CallbackQuery, state: FSMContext):
    data = await state.get_data()
    await state.set_state(Flow.estimate)
    hint = f"\n\nПоследний выбранный стиль дизайна: <b>{data['last_style']}</b> — можно на него сослаться." \
        if data.get("last_style") else ""
    await cb.message.answer(
        "📋 Опишите, что нужно сделать, одним сообщением:\n"
        "<i>что за помещение, площадь, какие работы, уровень отделки, город</i>\n\n"
        "Пример: <code>Ванная 4 м², Казань, демонтаж старой плитки, новая плитка на пол и стены, "
        "замена сантехники, средний уровень</code>" + hint +
        f"\n\nСтоимость: {PRICES['estimate']} кр.",
        reply_markup=home_kb(),
    )
    await cb.answer()


@router.message(Flow.estimate, F.text)
async def estimate_run(message: Message, state: FSMContext):
    data = await state.get_data()
    text = message.text
    if data.get("last_style"):
        text += f"\n(Стиль ремонта, если важен: {data['last_style']})"
    await run_text_job(message, message.from_user.id, "estimate", ESTIMATE_SYSTEM, text)


# ---------- 🔍 Проверка работы ----------

@router.callback_query(F.data == "menu:check")
async def check_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.check_photo)
    await cb.message.edit_text(
        "🔍 Пришлите фото выполненной работы (плитка, штукатурка, стяжка, электрика…).\n"
        "В подписи можно написать, что это и что смущает.\n\n"
        f"Стоимость: {PRICES['check']} кр.",
        reply_markup=home_kb(),
    )
    await cb.answer()


@router.message(Flow.check_photo, F.photo)
async def check_run(message: Message, bot: Bot):
    try:
        url = await photo_url(message, bot)
    except Exception:
        log.exception("upload failed")
        return await message.answer("Не удалось загрузить фото, пришлите ещё раз.")
    text = "Оцени качество работы на фото." + (
        f" Комментарий заказчика: {message.caption}" if message.caption else "")
    await run_text_job(message, message.from_user.id, "check", CHECK_SYSTEM, text, image_url=url)


# ---------- 💬 Консультант ----------

@router.callback_query(F.data == "menu:consult")
async def consult_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.consult)
    await cb.message.edit_text(
        "💬 Задайте вопрос по ремонту или стройке.\n"
        f"Первые {FREE_CONSULT_PER_DAY} вопроса в день — бесплатно, дальше {PRICES['consult']} кр.",
        reply_markup=home_kb(),
    )
    await cb.answer()


@router.message(Flow.consult, F.text)
async def consult_run(message: Message):
    free = await db.use_free_consult(message.from_user.id, FREE_CONSULT_PER_DAY)
    await run_text_job(message, message.from_user.id, "consult", CONSULT_SYSTEM, message.text,
                       cost=0 if free else None)


# ---------- 📄 КП (прораб/компания) ----------

@router.callback_query(F.data == "menu:kp")
async def kp_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.kp)
    await cb.message.edit_text(
        "📄 Опишите объект и работы — составлю коммерческое предложение для заказчика.\n"
        "Укажите название вашей бригады/компании, если нужно.\n\n"
        f"Стоимость: {PRICES['kp']} кр.",
        reply_markup=home_kb(),
    )
    await cb.answer()


@router.message(Flow.kp, F.text)
async def kp_run(message: Message):
    await run_text_job(message, message.from_user.id, "kp", KP_SYSTEM, message.text)


# ---------- прочее ----------

@router.message(F.voice)
async def voice_stub(message: Message):
    await message.answer("🎙 Голосовые скоро научусь понимать. Пока напишите текстом, пожалуйста.")


@router.message(F.photo)
async def photo_without_mode(message: Message):
    await message.answer("Что сделать с фото? Выберите в меню «Дизайн по фото» или «Проверить работу» → /menu")
