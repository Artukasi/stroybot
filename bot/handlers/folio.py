"""🖼 Портфолио «до/после»: работы прораба → картинка и пост для соцсетей, видео для Reels."""
import html
import logging

from aiogram import Bot, F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import (BufferedInputFile, CallbackQuery, InlineKeyboardButton as B,
                           InlineKeyboardMarkup as M, Message)

from .. import db, portfolio
from ..config import PRICES
from ..states import Folio
from .helpers import ERROR_TEXT, TEXT_OR_VOICE, after_paid_success, not_enough, read_text

log = logging.getLogger(__name__)
router = Router()

INTRO = ("🖼 <b>Портфолио «до и после»</b>\n\n"
         "Добавляйте готовые работы: фото до и после. Из каждой я сделаю картинку для поста, "
         f"текст для Telegram и VK ({PRICES['post']} кр.) и вертикальное видео для Reels, Shorts и VK Клипов (бесплатно).")


def list_kb(items: list[dict]) -> M:
    rows = [[B(text=f"🏠 {it['title'] or 'Работа ' + str(it['id'])}"[:60], callback_data=f"pf:item:{it['id']}")]
            for it in items[:20]]
    rows.append([B(text="➕ Добавить работу", callback_data="pf:new")])
    rows.append([B(text="✏️ Подпись бригады", callback_data="pf:brand"),
                 B(text="⬅️ Меню", callback_data="menu:home")])
    return M(inline_keyboard=rows)


def item_kb(item_id: int) -> M:
    return M(inline_keyboard=[
        [B(text=f"✍️ Пост для соцсетей · {PRICES['post']} кр.", callback_data=f"pf:post:{item_id}")],
        [B(text="🎬 Видео для Reels", callback_data=f"pf:reel:{item_id}")],
        [B(text="🗑 Удалить", callback_data=f"pf:del:{item_id}"),
         B(text="⬅️ Портфолио", callback_data="pf:list")],
    ])


def skip_kb() -> M:
    return M(inline_keyboard=[[B(text="Пропустить", callback_data="pf:skip")]])


async def show_list(message: Message, user_id: int, edit: bool = False):
    items = await db.list_portfolio(user_id)
    text = INTRO + (f"\n\nРабот: {len(items)}" if items else "\n\nПока пусто — добавьте первую работу 👇")
    if edit:
        try:
            return await message.edit_text(text, reply_markup=list_kb(items))
        except Exception:
            pass
    await message.answer(text, reply_markup=list_kb(items))


async def _brand(user_id: int) -> str:
    return ((await db.get_user(user_id)) or {}).get("brand") or ""


async def show_item(message: Message, user_id: int, item: dict):
    if not portfolio.has_photos(item["id"]):
        return await message.answer("Фото этой работы потерялись. Удалите её и добавьте заново.",
                                    reply_markup=item_kb(item["id"]))
    image = portfolio.item_collage(item, await _brand(user_id))
    await message.answer_photo(BufferedInputFile(image, f"portfolio_{item['id']}.jpg"),
                               caption=html.escape(item["title"] or "Работа"), reply_markup=item_kb(item["id"]))


@router.message(Command("portfolio"))
async def cmd_portfolio(message: Message, state: FSMContext):
    await state.set_state(None)
    await show_list(message, message.from_user.id)


@router.callback_query(F.data == "pf:list")
async def pf_list(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    await cb.answer()
    await show_list(cb.message, cb.from_user.id, edit=not cb.message.photo)


@router.callback_query(F.data == "pf:new")
async def pf_new(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Folio.before)
    await cb.answer()
    await cb.message.answer("📷 Пришлите фото <b>ДО</b> ремонта. Лучше горизонтальное, с того же места, "
                            "откуда потом снимете «после».")


@router.message(Folio.before, F.photo)
async def pf_before(message: Message, state: FSMContext):
    await state.update_data(pf_before=message.photo[-1].file_id)
    await state.set_state(Folio.after)
    await message.answer("✨ Теперь фото <b>ПОСЛЕ</b>, с той же точки.")


@router.message(Folio.after, F.photo)
async def pf_after(message: Message, state: FSMContext, bot: Bot):
    data = await state.get_data()
    item_id = await db.add_portfolio(message.from_user.id)
    try:
        for side, file_id in (("before", data.get("pf_before")), ("after", message.photo[-1].file_id)):
            buf = await bot.download(file_id)
            portfolio.save_photo(item_id, side, buf.read())
    except Exception:
        log.exception("portfolio photo save failed")
        await db.delete_portfolio(message.from_user.id, item_id)
        portfolio.delete_photos(item_id)
        await state.set_state(None)
        return await message.answer("😔 Не получилось сохранить фото. Попробуйте ещё раз.")
    await state.update_data(pf_item=item_id)
    await state.set_state(Folio.title)
    await message.answer("✍️ Коротко: что за работа? Например «Ванная под ключ за 12 дней, Казань». "
                         "Можно голосом 🎙", reply_markup=skip_kb())


@router.message(Folio.before)
@router.message(Folio.after)
async def pf_need_photo(message: Message):
    await message.answer("Нужно фото 📷. Или вернитесь в меню: /menu")


@router.message(Folio.title, TEXT_OR_VOICE)
async def pf_title(message: Message, state: FSMContext, bot: Bot):
    text = await read_text(message, bot)
    if text is None:
        return
    item_id = (await state.get_data()).get("pf_item")
    await state.set_state(None)
    await db.set_portfolio_title(message.from_user.id, item_id, text.strip())
    item = await db.get_portfolio(message.from_user.id, item_id)
    if item:
        await show_item(message, message.from_user.id, item)


@router.callback_query(F.data == "pf:skip")
async def pf_skip(cb: CallbackQuery, state: FSMContext):
    item_id = (await state.get_data()).get("pf_item")
    await state.set_state(None)
    await cb.answer()
    item = await db.get_portfolio(cb.from_user.id, item_id or 0)
    if item:
        await show_item(cb.message, cb.from_user.id, item)
    else:
        await show_list(cb.message, cb.from_user.id)


async def _item(cb: CallbackQuery) -> dict | None:
    try:
        item = await db.get_portfolio(cb.from_user.id, int(cb.data.split(":")[2]))
    except (IndexError, ValueError):
        item = None
    if not item:
        await cb.answer("Работа не найдена", show_alert=True)
    return item


@router.callback_query(F.data.startswith("pf:item:"))
async def pf_item(cb: CallbackQuery):
    item = await _item(cb)
    if item:
        await cb.answer()
        await show_item(cb.message, cb.from_user.id, item)


@router.callback_query(F.data.startswith("pf:post:"))
async def pf_post(cb: CallbackQuery, bot: Bot):
    item = await _item(cb)
    if not item:
        return
    await cb.answer()
    job_id = await db.charge(cb.from_user.id, PRICES["post"], "post")
    if job_id is None:
        return await not_enough(cb.message, PRICES["post"])
    wait = await cb.message.answer("✍️ Пишу пост…")
    try:
        text = await portfolio.post_text(item, await _brand(cb.from_user.id))
    except Exception:
        log.exception("portfolio post failed")
        await db.finish_job(job_id, ok=False)
        return await wait.edit_text(ERROR_TEXT)
    await db.finish_job(job_id, ok=True)
    await after_paid_success(bot, cb.from_user.id)
    await wait.edit_text("Готово 👇 Перешлите картинку и текст в свой канал или скопируйте текст.")
    await cb.message.answer(html.escape(text), reply_markup=item_kb(item["id"]))


@router.callback_query(F.data.startswith("pf:reel:"))
async def pf_reel(cb: CallbackQuery):
    item = await _item(cb)
    if not item:
        return
    if not portfolio.has_photos(item["id"]):
        return await cb.answer("Фото этой работы потерялись", show_alert=True)
    await cb.answer()
    wait = await cb.message.answer("🎬 Собираю видео… обычно 10–30 секунд.")
    try:
        video = await portfolio.item_reel(item, await _brand(cb.from_user.id))
    except Exception:
        log.exception("portfolio reel failed")
        return await wait.edit_text("😔 Видео не собралось. Попробуйте ещё раз.")
    try:
        await wait.delete()
    except Exception:
        pass
    await cb.message.answer_video(BufferedInputFile(video, f"reels_{item['id']}.mp4"), width=portfolio.W,
                                  height=portfolio.H, supports_streaming=True,
                                  caption="🎬 Готово: 8 секунд, вертикальное. Подходит для Reels, Shorts и VK Клипов. "
                                          "Музыку добавьте в самом приложении.",
                                  reply_markup=item_kb(item["id"]))


@router.callback_query(F.data.startswith("pf:del:"))
async def pf_delete(cb: CallbackQuery):
    item = await _item(cb)
    if not item:
        return
    await db.delete_portfolio(cb.from_user.id, item["id"])
    portfolio.delete_photos(item["id"])
    await cb.answer("Удалено")
    await show_list(cb.message, cb.from_user.id)


@router.callback_query(F.data == "pf:brand")
async def pf_brand(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Folio.brand)
    await cb.answer()
    brand = await _brand(cb.from_user.id)
    await cb.message.answer("✏️ Как подписывать работы? Имя бригады и телефон или ник, например "
                            "«Бригада Артура · +7 900 000-00-00». Подпись будет на картинках и в конце видео."
                            + (f"\n\nСейчас: <b>{html.escape(brand)}</b>" if brand else ""))


@router.message(Folio.brand, TEXT_OR_VOICE)
async def pf_brand_set(message: Message, state: FSMContext, bot: Bot):
    text = await read_text(message, bot)
    if text is None:
        return
    await state.set_state(None)
    await db.set_brand(message.from_user.id, text)
    await message.answer("Готово, подпись сохранена ✅")
    await show_list(message, message.from_user.id)
