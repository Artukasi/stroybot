"""Кнопки под сканом с iPhone: ремонт на картинке и смета по точным размерам."""
import logging

from aiogram import Bot, F, Router
from aiogram.types import CallbackQuery, InlineKeyboardButton as B, InlineKeyboardMarkup as M

from .. import db, scan_ai
from ..config import PRICES
from ..keyboards import home_kb
from ..prompts import DESIGN_STYLES
from .helpers import ERROR_TEXT, after_paid_success, not_enough, run_text_job

log = logging.getLogger(__name__)
router = Router()


def scan_styles_kb(scan_id: int) -> M:
    items = list(DESIGN_STYLES.items())
    rows = [[B(text=v[0], callback_data=f"sds:{scan_id}:{k}") for k, v in items[i:i + 2]]
            for i in range(0, len(items), 2)]
    return M(inline_keyboard=rows)


async def _scan(cb: CallbackQuery, raw: str) -> dict | None:
    try:
        scan = await db.get_scan(cb.from_user.id, int(raw))
    except ValueError:
        scan = None
    if not scan:
        await cb.answer("Скан не найден", show_alert=True)
    return scan


@router.callback_query(F.data.startswith("sd:"))
async def scan_design_styles(cb: CallbackQuery):
    scan = await _scan(cb, cb.data.split(":")[1])
    if not scan:
        return
    await cb.answer()
    how = "перекрашу фото комнаты с iPhone" if scan_ai.photo_path(scan["id"]).exists() \
        else "нарисую комнату по размерам скана"
    await cb.message.answer(f"🎨 Выберите стиль: {how}. Стоит {PRICES['design']} кредита.",
                            reply_markup=scan_styles_kb(scan["id"]))


@router.callback_query(F.data.startswith("sds:"))
async def scan_design(cb: CallbackQuery, bot: Bot):
    _, raw, style = (cb.data.split(":") + ["", ""])[:3]
    scan = await _scan(cb, raw)
    if not scan:
        return
    if style not in DESIGN_STYLES:
        return await cb.answer("Такого стиля нет", show_alert=True)
    await cb.answer()
    name = DESIGN_STYLES[style][0]
    job_id = await db.charge(cb.from_user.id, PRICES["design"], "design")
    if job_id is None:
        return await not_enough(cb.message, PRICES["design"])
    wait = await cb.message.answer(f"🎨 Рисую ремонт «{name}» по скану… обычно 20–60 секунд.")
    try:
        image = await scan_ai.design_image(scan, style)
    except Exception:
        log.exception("scan design failed")
        await db.finish_job(job_id, ok=False)
        return await wait.edit_text(ERROR_TEXT, reply_markup=home_kb())
    await db.finish_job(job_id, ok=True)
    await after_paid_success(bot, cb.from_user.id)
    try:
        await wait.delete()
    except Exception:
        pass
    caption = f"✨ {scan['room']}, стиль «{name}»"
    try:
        await cb.message.answer_photo(image, caption=caption, reply_markup=scan_styles_kb(scan["id"]))
    except Exception:
        await cb.message.answer(f"{caption}\n{image}", reply_markup=scan_styles_kb(scan["id"]))


@router.callback_query(F.data.startswith("se:"))
async def scan_estimate(cb: CallbackQuery, bot: Bot):
    scan = await _scan(cb, cb.data.split(":")[1])
    if not scan:
        return
    await cb.answer()
    await run_text_job(cb.message, cb.from_user.id, "estimate", scan_ai.ESTIMATE_SYSTEM,
                       scan_ai.estimate_request(scan), bot=bot)
