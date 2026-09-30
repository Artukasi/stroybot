"""📸 Фотоотчёт прораба: фото + подписи (текстом или голосом) → PDF для заказчика."""
import asyncio
import html
import logging

from aiogram import Bot, F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from .. import db, kie
from ..config import PRICES, REPORT_MAX_PHOTOS
from ..keyboards import home_kb, report_kb, report_objects_kb
from ..prompts import REPORT_SYSTEM
from ..report import build_pdf
from ..states import Report
from .helpers import TEXT_OR_VOICE, after_paid_success, not_enough, read_text

log = logging.getLogger(__name__)
router = Router()

INTRO = (
    "📸 <b>Фотоотчёт для заказчика</b>\n\n"
    "Присылайте фото по одному или альбомом. Подпись — в подписи к фото или следующим сообщением "
    "(текстом или голосом 🎙): она добавится к последнему фото.\n"
    "Когда всё готово — «Собрать PDF». Я напишу короткое резюме для заказчика и соберу файл.\n\n"
    f"Стоимость: {PRICES['report']} кр. До {REPORT_MAX_PHOTOS} фото."
)


async def begin(target: Message, state: FSMContext, oid: int, edit: bool):
    await state.set_state(Report.collecting)
    await state.update_data(rep_oid=oid, rep_items=[], rep_notes="")
    if edit:
        try:
            return await target.edit_text(INTRO, reply_markup=report_kb(0))
        except Exception:
            pass
    await target.answer(INTRO, reply_markup=report_kb(0))


@router.message(Command("report"))
async def cmd_report(message: Message, state: FSMContext):
    objs = await db.list_objects(message.from_user.id)
    if objs:
        await state.set_state(None)
        return await message.answer("📸 Для какого объекта отчёт?", reply_markup=report_objects_kb(objs))
    await begin(message, state, 0, edit=False)


@router.callback_query(F.data == "rep:start")
async def rep_start(cb: CallbackQuery, state: FSMContext):
    objs = await db.list_objects(cb.from_user.id)
    if objs:
        await cb.message.edit_text("📸 Для какого объекта отчёт?", reply_markup=report_objects_kb(objs))
    else:
        await begin(cb.message, state, 0, edit=True)
    await cb.answer()


@router.callback_query(F.data.startswith("rep:start:"))
async def rep_start_obj(cb: CallbackQuery, state: FSMContext):
    oid = int(cb.data.split(":")[2])
    if oid and not await db.get_object(oid, cb.from_user.id):
        return await cb.answer("Объект не найден", show_alert=True)
    await begin(cb.message, state, oid, edit=True)
    await cb.answer()


@router.message(Report.collecting, F.photo)
async def rep_photo(message: Message, state: FSMContext):
    data = await state.get_data()
    items = data.get("rep_items", [])
    if len(items) >= REPORT_MAX_PHOTOS:
        return await message.answer(f"Уже {REPORT_MAX_PHOTOS} фото — это максимум. Собирайте PDF 👇",
                                    reply_markup=report_kb(len(items)))
    items.append({"file_id": message.photo[-1].file_id, "caption": (message.caption or "").strip()})
    await state.update_data(rep_items=items)
    # в альбоме фото приходят пачкой — отвечаем коротко
    await message.answer(f"📷 Фото {len(items)} добавлено.", reply_markup=report_kb(len(items)))


@router.message(Report.collecting, TEXT_OR_VOICE)
async def rep_text(message: Message, state: FSMContext, bot: Bot):
    text = await read_text(message, bot)
    if not text:
        return
    data = await state.get_data()
    items = data.get("rep_items", [])
    if items:
        last = items[-1]
        last["caption"] = (last["caption"] + "\n" + text).strip()
        await state.update_data(rep_items=items)
        await message.answer(f"✍️ Подпись к фото {len(items)} добавлена.", reply_markup=report_kb(len(items)))
    else:
        await state.update_data(rep_notes=(data.get("rep_notes", "") + "\n" + text).strip())
        await message.answer("✍️ Записал как общий комментарий. Теперь пришлите фото.",
                             reply_markup=report_kb(0))


@router.callback_query(F.data == "rep:cancel")
async def rep_cancel(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    await state.update_data(rep_items=[], rep_notes="")
    await cb.message.edit_text("Отчёт отменён.", reply_markup=home_kb())
    await cb.answer()


@router.callback_query(Report.collecting, F.data == "rep:build")
async def rep_build(cb: CallbackQuery, state: FSMContext, bot: Bot):
    data = await state.get_data()
    items = data.get("rep_items", [])
    if not items:
        return await cb.answer("Сначала пришлите фото", show_alert=True)
    await cb.answer()
    user_id = cb.from_user.id
    job_id = await db.charge(user_id, PRICES["report"], "report")
    if job_id is None:
        return await not_enough(cb.message, PRICES["report"])
    await state.set_state(None)
    wait = await cb.message.answer("⏳ Собираю отчёт…")

    obj = await db.get_object(data.get("rep_oid") or 0, user_id)
    obj_name = obj["name"] if obj else ""
    title = f"Фотоотчёт: {obj_name}" if obj_name else "Фотоотчёт о ходе работ"

    try:
        photos = []
        for it in items:
            buf = await bot.download(it["file_id"])
            photos.append((buf.read(), it["caption"]))
    except Exception:
        log.exception("report download failed")
        await db.finish_job(job_id, ok=False)
        return await wait.edit_text("😔 Не удалось скачать фото, кредит вернул. Попробуйте ещё раз.",
                                    reply_markup=home_kb())

    captions = "\n".join(f"Фото {i}: {c or 'без подписи'}" for i, (_, c) in enumerate(photos, 1))
    prompt = (f"Объект: {obj_name or 'не указан'}\n"
              f"Общий комментарий прораба: {data.get('rep_notes') or 'нет'}\n{captions}")
    summary, ai_ok = "", True
    try:
        summary = await kie.chat(REPORT_SYSTEM, prompt, max_tokens=800)
    except Exception:
        log.exception("report summary failed")
        ai_ok = False
        summary = data.get("rep_notes", "")

    try:
        pdf = await asyncio.to_thread(build_pdf, title, photos, summary, cb.from_user.full_name)
    except Exception:
        log.exception("pdf build failed")
        await db.finish_job(job_id, ok=False)
        return await wait.edit_text("😔 Не получилось собрать PDF, кредит вернул.", reply_markup=home_kb())

    # без ИИ-резюме отчёт всё равно отдаём, но кредит возвращаем
    await db.finish_job(job_id, ok=ai_ok)
    if ai_ok:
        await after_paid_success(bot, user_id)
    await state.update_data(rep_items=[], rep_notes="")
    try:
        await wait.delete()
    except Exception:
        pass
    name = "otchet.pdf" if not obj else f"otchet_{obj['id']}.pdf"
    caption = f"📄 <b>{html.escape(title)}</b>\nМожно сразу переслать заказчику."
    if not ai_ok:
        caption += "\n<i>Резюме не получилось написать, поэтому кредит вернул.</i>"
    await cb.message.answer_document(BufferedInputFile(pdf, filename=name), caption=caption,
                                     reply_markup=home_kb())
