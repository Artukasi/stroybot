"""Кнопки под сканом с iPhone: ремонт на картинке, мебель по размерам и смета по точным размерам.
Сюда же приходит файл скана (.stroyscan.json), если его прислать в чат."""
import html
import json
import logging
import time

from aiogram import Bot, F, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, InlineKeyboardButton as B, InlineKeyboardMarkup as M, Message

from .. import db, furniture, scan_ai
from ..config import PRICES
from ..keyboards import home_kb
from ..prompts import DESIGN_STYLES
from ..states import Flow
from ..web_scan import save_scan, scan_kb, scan_text
from .helpers import ERROR_TEXT, after_paid_success, not_enough, photo_url, run_text_job

log = logging.getLogger(__name__)
router = Router()

MAX_SCAN_FILE = 10 * 1024 * 1024    # фото комнаты внутри файла до 6 МБ — в base64 это ~8 МБ
MAX_CHAT_ITEMS = 8
PHOTO_TTL = 2 * 24 * 3600          # фото в хранилище kie.ai живёт ~3 дня
SHORT = {"Яндекс Маркет": "Маркет", "Wildberries": "WB", "Divan.ru": "Divan"}
HOW_TO_SEND = ("Пришлите файл «….stroyscan.json» из приложения СтройСкан: "
               "в приложении «Поделиться» → Telegram → этот бот.")


def scan_styles_kb(scan_id: int) -> M:
    items = list(DESIGN_STYLES.items())
    rows = [[B(text=v[0], callback_data=f"sds:{scan_id}:{k}") for k, v in items[i:i + 2]]
            for i in range(0, len(items), 2)]
    return M(inline_keyboard=rows)


def furniture_groups(items: list[dict]) -> list[tuple[dict, int]]:
    """Одинаковые вещи (стулья вокруг стола) — одной строкой: (вещь, сколько). Размер — чтобы встали все."""
    groups: dict[str, list] = {}
    for it in items:
        if it["query"] in groups:
            first = groups[it["query"]]
            first[1] += 1
            first[0]["max"] = {k: min(first[0]["max"][k], it["max"][k]) for k in ("width", "depth")}
        else:
            groups[it["query"]] = [{**it}, 1]
    return [(it, n) for it, n in groups.values()][:MAX_CHAT_ITEMS]


def furniture_text(scan: dict, groups: list[tuple[dict, int]]) -> str:
    lines = [f"🛋 <b>Мебель по размерам: {html.escape(scan['room'])}</b>", ""]
    for n, (it, count) in enumerate(groups, 1):
        size, top = it["size"], it["max"]
        now = f" сейчас {size['width']}×{size['depth']} см," if size.get("width") else ""
        many = f" ×{count}" if count > 1 else ""
        lines.append(f"{n}. <b>{html.escape(it['title'])}</b>{many} —{now} "
                     f"встанет до {top['width']}×{top['depth']} см")
        lines.append(f"<i>{html.escape(it['note'])}</i>")
    lines += ["", "Кнопки открывают поиск в магазинах — размеры уже в запросе. "
                  "Перед покупкой сверьте габариты рулеткой."]
    return "\n".join(lines)


def furniture_kb(groups: list[tuple[dict, int]]) -> M:
    rows = [[B(text=f"{n} · {SHORT.get(link['shop'], link['shop'])}", url=link["url"]) for link in it["links"]]
            for n, (it, _) in enumerate(groups, 1)]
    rows.append([B(text="⬅️ Меню", callback_data="menu:home")])
    return M(inline_keyboard=rows)


async def _scan(cb: CallbackQuery, raw: str) -> dict | None:
    try:
        scan = await db.get_scan(cb.from_user.id, int(raw))
    except ValueError:
        scan = None
    if not scan:
        await cb.answer("Скан не найден", show_alert=True)
    return scan


async def ask_style(message: Message, state: FSMContext, scan: dict):
    """Выбор стиля для ремонта по скану; пока выбирают — можно прислать своё фото этой комнаты."""
    await state.set_state(Flow.scan_photo)
    await state.update_data(scan_id=scan["id"], scan_photo=None)
    how = "перекрашу фото комнаты с iPhone" if scan_ai.photo_path(scan["id"]).exists() \
        else "нарисую комнату по размерам скана"
    look = " Учту ваш ремонт из 3D: отделку, свет и мебель." if scan.get("look") else ""
    await message.answer(f"🎨 Выберите стиль: {how}.{look} Стоит {PRICES['design']} кредита.\n\n"
                         "📸 Можно сначала прислать своё фото этой комнаты — сделаю ремонт на нём, "
                         "по точным размерам скана.", reply_markup=scan_styles_kb(scan["id"]))


@router.callback_query(F.data.startswith("sd:"))
async def scan_design_styles(cb: CallbackQuery, state: FSMContext):
    scan = await _scan(cb, cb.data.split(":")[1])
    if not scan:
        return
    await cb.answer()
    await ask_style(cb.message, state, scan)


@router.message(Flow.scan_photo, F.photo)
async def scan_room_photo(message: Message, state: FSMContext, bot: Bot):
    """Своё фото комнаты для ремонта по скану: размеры берём из скана, вид — с фото."""
    scan_id = (await state.get_data()).get("scan_id")
    scan = await db.get_scan(message.from_user.id, int(scan_id or 0))
    if not scan:
        await state.set_state(None)
        return await message.answer("Скан не найден. Выберите его заново в меню «Дизайн по фото».",
                                    reply_markup=home_kb())
    wait = await message.answer("⏳ Загружаю фото…")
    try:
        url = await photo_url(message, bot)
    except Exception:
        log.exception("upload failed")
        return await wait.edit_text("Не удалось загрузить фото, пришлите ещё раз.")
    await state.update_data(scan_photo=url, scan_photo_at=time.time())
    await wait.edit_text(f"📸 Фото есть. Выберите стиль — сделаю ремонт на нём по размерам скана "
                         f"«{html.escape(scan['room'])}» 👇", reply_markup=scan_styles_kb(scan["id"]))


@router.callback_query(F.data.startswith("sds:"))
async def scan_design(cb: CallbackQuery, state: FSMContext, bot: Bot):
    _, raw, style = (cb.data.split(":") + ["", ""])[:3]
    scan = await _scan(cb, raw)
    if not scan:
        return
    if style not in DESIGN_STYLES:
        return await cb.answer("Такого стиля нет", show_alert=True)
    await cb.answer()
    data = await state.get_data()
    fresh = time.time() - (data.get("scan_photo_at") or 0) < PHOTO_TTL
    own_photo = data.get("scan_photo") if data.get("scan_id") == scan["id"] and fresh else None
    name = DESIGN_STYLES[style][0]
    job_id = await db.charge(cb.from_user.id, PRICES["design"], "design")
    if job_id is None:
        return await not_enough(cb.message, PRICES["design"])
    wait = await cb.message.answer(f"🎨 Рисую ремонт «{name}» по скану… обычно 20–60 секунд.")
    try:
        image = await scan_ai.design_image(scan, style, photo_url=own_photo)
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
    caption = f"✨ {html.escape(scan['room'])}, стиль «{name}»" + (" · на вашем фото" if own_photo else "")
    try:
        await cb.message.answer_photo(image, caption=caption, reply_markup=scan_styles_kb(scan["id"]))
    except Exception:
        await cb.message.answer(f"{caption}\n{image}", reply_markup=scan_styles_kb(scan["id"]))


@router.callback_query(F.data.startswith("sf:"))
async def scan_furniture(cb: CallbackQuery):
    scan = await _scan(cb, cb.data.split(":")[1])
    if not scan:
        return
    await cb.answer()
    groups = furniture_groups(furniture.pick(scan, scan.get("look")))
    if not groups:
        return await cb.message.answer("🛋 На скане нет мебели, а свободные стены не нашлись. "
                                       "Отсканируйте комнату вместе с мебелью — подберу по размерам.",
                                       reply_markup=home_kb())
    await cb.message.answer(furniture_text(scan, groups), reply_markup=furniture_kb(groups))


@router.callback_query(F.data.startswith("se:"))
async def scan_estimate(cb: CallbackQuery, bot: Bot):
    scan = await _scan(cb, cb.data.split(":")[1])
    if not scan:
        return
    await cb.answer()
    await run_text_job(cb.message, cb.from_user.id, "estimate", scan_ai.ESTIMATE_SYSTEM,
                       scan_ai.estimate_request(scan), bot=bot)


# ---------- 📎 файл скана из приложения ----------

def _json_file(message: Message) -> bool:
    d = message.document
    return bool(d) and ((d.file_name or "").lower().endswith(".json") or d.mime_type == "application/json")


@router.message(F.document, _json_file)
async def scan_file(message: Message, state: FSMContext, bot: Bot):
    """Файл «Комната.stroyscan.json» из СтройСкана: сохраняем как скан из приложения и сразу показываем."""
    doc = message.document
    if (doc.file_size or 0) > MAX_SCAN_FILE:
        return await message.answer("📄 Файл больше 10 МБ — это не скан. " + HOW_TO_SEND,
                                    reply_markup=home_kb())
    await db.get_or_create_user(message.from_user.id, message.from_user.username)
    try:
        raw = (await bot.download(doc.file_id)).read(MAX_SCAN_FILE + 1)
    except Exception:
        log.exception("scan file download failed")
        return await message.answer("😔 Не удалось скачать файл. Пришлите его ещё раз.")
    try:
        data = json.loads(raw.decode("utf-8-sig")) if len(raw) <= MAX_SCAN_FILE else None
    except (ValueError, RecursionError):
        data = None
    named = (doc.file_name or "").lower().endswith(".stroyscan.json")
    if not isinstance(data, dict) or data.get("format") != "stroyscan" and not named:
        return await message.answer("🤔 Это не файл скана. " + HOW_TO_SEND, reply_markup=home_kb())
    in_design = await state.get_state() in (Flow.design_photo.state, Flow.design_style.state,
                                            Flow.scan_photo.state)
    try:
        scan = await save_scan(message.from_user.id, data)     # тот же путь, что у приложения (/scan/rooms)
    except ValueError:
        return await message.answer("😔 В файле нет размеров комнаты. Отсканируйте комнату ещё раз "
                                    "и пришлите новый файл.", reply_markup=home_kb())
    await message.answer(scan_text(scan), reply_markup=scan_kb(scan["id"]))
    if in_design:
        await ask_style(message, state, scan)
