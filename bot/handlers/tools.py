"""Функции бота: дизайн по фото, калькулятор, смета, проверка работы, консультант, КП."""
import logging

from aiogram import Bot, F, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import db, kie
from ..calc import CALCS, parse_numbers
from ..config import FREE_CONSULT_PER_DAY, PRICES
from ..keyboards import after_design_kb, calcs_kb, home_kb, styles_kb
from ..prompts import (CHECK_SYSTEM, CONSULT_SYSTEM, DESIGN_PROMPT, DESIGN_STYLES,
                       ESTIMATE_SYSTEM, KP_SYSTEM)
from ..states import Flow
from .helpers import (ERROR_TEXT, TEXT_OR_VOICE, after_paid_success, not_enough, photo_url,
                      read_text, run_text_job)

log = logging.getLogger(__name__)
router = Router()



# ---------- 🛋 Дизайн по фото ----------

@router.callback_query(F.data == "menu:design")
async def design_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.design_photo)
    text = ("📸 Пришлите фото комнаты — покажу, как она будет выглядеть после ремонта.\n\n"
            "Совет: снимайте из угла, горизонтально, при дневном свете.\n"
            f"Стоимость: {PRICES['design']} кр. за вариант.")
    try:
        await cb.message.edit_text(text, reply_markup=home_kb())
    except Exception:
        await cb.message.answer(text, reply_markup=home_kb())
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


@router.message(Flow.design_photo)
async def design_need_photo(message: Message):
    await message.answer("Жду именно фото комнаты 📸 (не файлом, а как фото).", reply_markup=home_kb())


@router.callback_query(F.data == "design:again")
async def design_again(cb: CallbackQuery, state: FSMContext):
    data = await state.get_data()
    if not data.get("photo_url"):
        return await design_start(cb, state)
    await state.set_state(Flow.design_style)
    await cb.message.answer("Выберите другой стиль 👇", reply_markup=styles_kb())
    await cb.answer()


@router.callback_query(F.data.startswith("style:"))
async def design_generate(cb: CallbackQuery, state: FSMContext, bot: Bot):
    key = cb.data.split(":", 1)[1]
    data = await state.get_data()
    if key not in DESIGN_STYLES or not data.get("photo_url") or \
            await state.get_state() != Flow.design_style.state:
        # старая кнопка или фото потерялось — начинаем заново
        await cb.answer("Пришлите фото ещё раз", show_alert=False)
        await state.set_state(Flow.design_photo)
        return await cb.message.answer("📸 Пришлите фото комнаты заново.", reply_markup=home_kb())
    name, style = DESIGN_STYLES[key]
    await cb.answer()
    job_id = await db.charge(cb.from_user.id, PRICES["design"], "design")
    if job_id is None:
        return await not_enough(cb.message, PRICES["design"])
    extra = f"Client wishes (in Russian): {data['extra']}" if data.get("extra") else ""
    wait = await cb.message.answer(f"🎨 Рисую «{name}»… обычно 20–60 секунд.")
    try:
        urls = await kie.edit_image(data["photo_url"], DESIGN_PROMPT.format(style=style, extra=extra))
    except Exception:
        log.exception("design failed")
        await db.finish_job(job_id, ok=False)
        return await wait.edit_text(ERROR_TEXT, reply_markup=home_kb())
    await db.finish_job(job_id, ok=True)
    await after_paid_success(bot, cb.from_user.id)
    try:
        await wait.delete()
    except Exception:
        pass
    try:
        await cb.message.answer_photo(urls[0], caption=f"✨ Стиль: <b>{name}</b>",
                                      reply_markup=after_design_kb())
    except Exception:
        await cb.message.answer(f"✨ Стиль: <b>{name}</b>\n{urls[0]}", reply_markup=after_design_kb())
    await state.update_data(last_style=name)


# ---------- 🧮 Калькулятор ----------

@router.callback_query(F.data == "menu:calc")
async def calc_menu(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    await cb.message.edit_text("🧮 Что считаем? (бесплатно)", reply_markup=calcs_kb())
    await cb.answer()


@router.callback_query(F.data.startswith("calc:"))
async def calc_pick(cb: CallbackQuery, state: FSMContext):
    key = cb.data.split(":", 1)[1]
    if key not in CALCS:
        return await cb.answer()
    title, hint, _, _ = CALCS[key]
    await state.set_state(Flow.calc_input)
    await state.update_data(calc=key)
    await cb.message.edit_text(f"{title}\n\n{hint}", reply_markup=calcs_kb())
    await cb.answer()


@router.message(Flow.calc_input, TEXT_OR_VOICE)
async def calc_input(message: Message, state: FSMContext, bot: Bot):
    key = (await state.get_data()).get("calc")
    if key not in CALCS:
        return await message.answer("Выберите материал 👇", reply_markup=calcs_kb())
    title, hint, min_n, fn = CALCS[key]
    text = await read_text(message, bot)
    if text is None:
        return
    nums = parse_numbers(text)
    if len(nums) < min_n or any(n <= 0 for n in nums):
        return await message.answer(f"Не понял числа 🤔\n\n{hint}")
    result = fn(nums)
    await message.answer(
        result.text() + "\n\n<i>Расчёт ориентировочный. Можно ввести новые размеры или выбрать другой материал.</i>",
        reply_markup=calcs_kb(),
    )


# ---------- 📋 Смета ----------

async def estimate_prompt(message: Message, state: FSMContext):
    data = await state.get_data()
    await state.set_state(Flow.estimate)
    hint = f"\n\nПоследний выбранный стиль дизайна: <b>{data['last_style']}</b> — можно на него сослаться." \
        if data.get("last_style") else ""
    await message.answer(
        "📋 Опишите, что нужно сделать, одним сообщением — текстом или голосом 🎙:\n"
        "<i>что за помещение, площадь, какие работы, уровень отделки, город</i>\n\n"
        "Пример: <code>Ванная 4 м², Казань, демонтаж старой плитки, новая плитка на пол и стены, "
        "замена сантехники, средний уровень</code>" + hint +
        f"\n\nСтоимость: {PRICES['estimate']} кр.",
        reply_markup=home_kb(),
    )


@router.callback_query(F.data == "menu:estimate")
async def estimate_start(cb: CallbackQuery, state: FSMContext):
    await estimate_prompt(cb.message, state)
    await cb.answer()


async def estimate_do(message: Message, state: FSMContext, bot: Bot, user_id: int, text: str):
    data = await state.get_data()
    if data.get("last_style"):
        text += f"\n(Стиль ремонта, если важен: {data['last_style']})"
    await run_text_job(message, user_id, "estimate", ESTIMATE_SYSTEM, text, bot=bot)


@router.message(Flow.estimate, TEXT_OR_VOICE)
async def estimate_run(message: Message, state: FSMContext, bot: Bot):
    text = await read_text(message, bot)
    if text:
        await estimate_do(message, state, bot, message.from_user.id, text)


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
    await run_text_job(message, message.from_user.id, "check", CHECK_SYSTEM, text,
                       image_url=url, bot=bot)


@router.message(Flow.check_photo)
async def check_need_photo(message: Message):
    await message.answer("Жду фото работы 📸. Комментарий можно написать в подписи к фото.",
                         reply_markup=home_kb())


# ---------- 💬 Консультант ----------

@router.callback_query(F.data == "menu:consult")
async def consult_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.consult)
    await cb.message.edit_text(
        "💬 Задайте вопрос по ремонту или стройке — текстом или голосом 🎙.\n"
        f"Первые {FREE_CONSULT_PER_DAY} вопроса в день — бесплатно, дальше {PRICES['consult']} кр.",
        reply_markup=home_kb(),
    )
    await cb.answer()


async def consult_do(message: Message, bot: Bot, user_id: int, text: str):
    free = await db.use_free_consult(user_id, FREE_CONSULT_PER_DAY)
    ok = await run_text_job(message, user_id, "consult", CONSULT_SYSTEM, text,
                            cost=0 if free else None, bot=bot)
    if free and not ok:
        await db.refund_free_consult(user_id)


@router.message(Flow.consult, TEXT_OR_VOICE)
async def consult_run(message: Message, bot: Bot):
    text = await read_text(message, bot)
    if text:
        await consult_do(message, bot, message.from_user.id, text)


# ---------- 📄 КП (прораб/компания) ----------

@router.callback_query(F.data == "menu:kp")
async def kp_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Flow.kp)
    await cb.message.edit_text(
        "📄 Опишите объект и работы — текстом или голосом 🎙 — составлю коммерческое предложение.\n"
        "Укажите название вашей бригады/компании, если нужно.\n\n"
        f"Стоимость: {PRICES['kp']} кр.",
        reply_markup=home_kb(),
    )
    await cb.answer()


@router.message(Flow.kp, TEXT_OR_VOICE)
async def kp_run(message: Message, bot: Bot):
    text = await read_text(message, bot)
    if text:
        await run_text_job(message, message.from_user.id, "kp", KP_SYSTEM, text, bot=bot)
