"""Mini App: платные функции бота через API — дизайн по фото, смета, проверка, консультант, КП,
советы по объекту, фотоотчёт, голос → текст, пополнение баланса и профиль.
Кредиты списываются так же, как в чате бота, и возвращаются, если ИИ не ответил."""
import asyncio
import html
import json
import logging
import re
import time
from datetime import date

from aiogram import Bot
from aiogram.types import BufferedInputFile, LabeledPrice
from aiohttp import web

from . import db, kie
from .config import FREE_CONSULT_PER_DAY, PACKS, PRICES, REFERRAL_BONUS, REPORT_MAX_PHOTOS, VOICE_MAX_SECONDS
from .keyboards import PRO_ROLES, ROLES
from .objects import summary
from .prompts import (CHECK_SYSTEM, CONSULT_SYSTEM, DESIGN_PROMPT, DESIGN_STYLES, ESTIMATE_SYSTEM,
                      KP_SYSTEM, MEASURE_SYSTEM, OBJECT_ADVICE_SYSTEM, REPORT_SYSTEM)
from .report import build_pdf

log = logging.getLogger(__name__)
BOT = web.AppKey("bot", Bot) if hasattr(web, "AppKey") else "bot"
TEXT_TOOLS = {"estimate": ESTIMATE_SYSTEM, "consult": CONSULT_SYSTEM, "kp": KP_SYSTEM}
MAX_PHOTO = 12 * 1024 * 1024
MAX_AUDIO = 8 * 1024 * 1024
MAX_TEXT = 4000
# последнее загруженное фото для дизайна: user_id → (url, время). Позволяет попробовать другой стиль
# без повторной загрузки. Живёт в памяти процесса, этого достаточно.
_design_photo: dict[int, tuple[str, float]] = {}
_ALLOWED = re.compile(r"&lt;(/?)(b|i|u|s|code|pre|strong|em)&gt;")


class NotEnough(Exception):
    def __init__(self, need: int):
        self.need = need


def safe_html(text: str) -> str:
    """Ответ модели в Telegram-HTML → безопасный HTML для страницы: оставляем только простые теги."""
    return _ALLOWED.sub(r"<\1\2>", html.escape(text or "", quote=False))


def _bot(request: web.Request) -> Bot | None:
    return request.app.get(BOT)


def _uid(request: web.Request) -> int:
    from .web import uid
    return uid(request)


async def _reward(request: web.Request, user_id: int) -> None:
    """Первая платная функция приглашённого → бонус пригласившему (как в боте)."""
    try:
        referrer = await db.reward_referrer(user_id, REFERRAL_BONUS)
        bot = _bot(request)
        if referrer and bot:
            await bot.send_message(referrer, f"🎁 Ваш друг начал пользоваться ботом — вам +{REFERRAL_BONUS} кредита!")
    except Exception:
        log.exception("referral reward failed")


async def paid(request: web.Request, kind: str, work, cost: int | None = None):
    """Списывает кредиты, выполняет work(); при ошибке возвращает кредиты и отвечает 502."""
    user_id = _uid(request)
    cost = PRICES[kind] if cost is None else cost
    job_id = None
    if cost:
        job_id = await db.charge(user_id, cost, kind)
        if job_id is None:
            raise NotEnough(cost)
    try:
        result = await work()
    except Exception:
        log.exception("web job %s failed", kind)
        if job_id:
            await db.finish_job(job_id, ok=False)
        raise web.HTTPBadGateway(text='{"error": "ai"}', content_type="application/json")
    if job_id:
        await db.finish_job(job_id, ok=True)
        await _reward(request, user_id)
    return result


async def credits_of(user_id: int) -> int:
    return (await db.get_user(user_id))["credits"]


def free_consult_left(user: dict) -> int:
    used = user.get("consult_used") or 0 if user.get("consult_day") == date.today().isoformat() else 0
    return max(0, FREE_CONSULT_PER_DAY - used)


@web.middleware
async def credits_middleware(request: web.Request, handler):
    try:
        return await handler(request)
    except NotEnough as e:
        return web.json_response({"error": "credits", "need": e.need,
                                  "credits": await credits_of(_uid(request))}, status=402)


async def _form(request: web.Request) -> dict:
    """multipart-форма: файлы → (bytes, content_type), поля → str; несколько одинаковых имён → список."""
    out: dict = {}
    if not request.content_type.startswith("multipart/"):
        post = await request.post()
        return {k: str(v)[:MAX_TEXT] for k, v in post.items() if isinstance(v, str)}
    reader = await request.multipart()
    while (part := await reader.next()) is not None:
        if part.filename:
            data = await part.read(decode=False)
            value = (bytes(data), part.headers.get("Content-Type", "application/octet-stream"))
        else:
            value = (await part.text())[:MAX_TEXT]
        if part.name in out:
            if not isinstance(out[part.name], list):
                out[part.name] = [out[part.name]]
            out[part.name].append(value)
        else:
            out[part.name] = value
    return out


def _photo(form: dict, name: str = "photo") -> bytes:
    value = form.get(name)
    if not isinstance(value, tuple) or not value[0]:
        raise ValueError("photo required")
    if len(value[0]) > MAX_PHOTO:
        raise ValueError("photo too large")
    return value[0]


# ---------- профиль ----------

async def api_profile(request: web.Request):
    user_id = _uid(request)
    user = await db.get_user(user_id)
    invited, rewarded = await db.referral_stats(user_id)
    bot = _bot(request)
    link = ""
    if bot:
        try:
            link = f"https://t.me/{(await bot.me()).username}?start=ref_{user_id}"
        except Exception:
            log.exception("bot.me failed")
    return web.json_response({
        "credits": user["credits"], "role": user.get("role"), "roles": ROLES, "pro_roles": list(PRO_ROLES),
        "prices": PRICES, "free_consult_left": free_consult_left(user), "free_consult_per_day": FREE_CONSULT_PER_DAY,
        "styles": {k: v[0] for k, v in DESIGN_STYLES.items()},
        "packs": [{"id": p, "credits": c, "stars": s} for p, c, s in PACKS],
        "invite": {"link": link, "invited": invited, "rewarded": rewarded, "bonus": REFERRAL_BONUS},
        "report_max_photos": REPORT_MAX_PHOTOS, "voice_max_seconds": VOICE_MAX_SECONDS,
    })


async def api_set_role(request: web.Request):
    from .web import body
    role = str((await body(request)).get("role", ""))
    if role not in ROLES:
        raise ValueError("unknown role")
    await db.set_role(_uid(request), role)
    return web.json_response({"ok": True})


async def api_invoice(request: web.Request):
    from .web import body
    pid = str((await body(request)).get("pack", ""))
    pack = next((p for p in PACKS if p[0] == pid), None)
    bot = _bot(request)
    if not pack or not bot:
        raise ValueError("pack")
    _, credits, stars = pack
    link = await bot.create_invoice_link(
        title=f"{credits} кредитов СтройБота",
        description="Кредиты на дизайн по фото, сметы, проверку работ, КП и фотоотчёты.",
        payload=f"pack:{pid}", currency="XTR", provider_token="",
        prices=[LabeledPrice(label=f"{credits} кредитов", amount=stars)],
    )
    return web.json_response({"link": link})


# ---------- ИИ-функции ----------

async def api_text_tool(request: web.Request):
    from .web import body
    data = await body(request)
    kind = data.get("kind")
    text = str(data.get("text", "")).strip()[:MAX_TEXT]
    if kind not in TEXT_TOOLS or len(text) < 3:
        raise ValueError("text")
    user_id = _uid(request)
    if kind == "estimate" and data.get("style"):
        text += f"\n(Стиль ремонта, если важен: {str(data['style'])[:60]})"
    cost = None
    free = False
    if kind == "consult":
        free = await db.use_free_consult(user_id, FREE_CONSULT_PER_DAY)
        cost = 0 if free else None
    try:
        answer = await paid(request, kind, lambda: kie.chat(TEXT_TOOLS[kind], text), cost=cost)
    except web.HTTPBadGateway:
        if free:
            await db.refund_free_consult(user_id)
        raise
    return web.json_response({"html": safe_html(answer), "raw": answer, "credits": await credits_of(user_id)})


async def api_check(request: web.Request):
    form = await _form(request)
    photo = _photo(form)
    note = form.get("note") if isinstance(form.get("note"), str) else ""
    user_id = _uid(request)

    async def work():
        url = await kie.upload_image(photo, f"{user_id}_{int(time.time())}.jpg")
        text = "Оцени качество работы на фото." + (f" Комментарий заказчика: {note}" if note.strip() else "")
        return await kie.chat(CHECK_SYSTEM, text, image_url=url)
    answer = await paid(request, "check", work)
    return web.json_response({"html": safe_html(answer), "raw": answer, "credits": await credits_of(user_id)})


async def api_design(request: web.Request):
    form = await _form(request)
    style = form.get("style")
    if style not in DESIGN_STYLES:
        raise ValueError("style")
    wishes = form.get("wishes") if isinstance(form.get("wishes"), str) else ""
    user_id = _uid(request)
    photo = form.get("photo")
    cached = _design_photo.get(user_id)
    if not isinstance(photo, tuple) and not (cached and time.time() - cached[1] < 2 * 24 * 3600):
        raise ValueError("photo required")
    data = _photo(form) if isinstance(photo, tuple) else None
    name, prompt_style = DESIGN_STYLES[style]
    extra = f"Client wishes (in Russian): {wishes.strip()}" if wishes.strip() else ""

    async def work():
        if data is not None:
            _design_photo[user_id] = (await kie.upload_image(data, f"{user_id}_{int(time.time())}.jpg"), time.time())
        urls = await kie.edit_image(_design_photo[user_id][0], DESIGN_PROMPT.format(style=prompt_style, extra=extra))
        return urls[0]
    image = await paid(request, "design", work)
    return web.json_response({"image": image, "style": name, "credits": await credits_of(user_id)})


MEASURE_KEYS = ("length", "width", "height", "perimeter", "floor_area", "wall_area", "openings_area")


def parse_measure(text: str) -> dict:
    """Ответ модели с размерами → словарь чисел; недостающее досчитываем из длины, ширины и высоты."""
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        raise ValueError("no json")
    raw = json.loads(m.group(0))
    out: dict = {"room": str(raw.get("room") or "")[:60] or None, "notes": str(raw.get("notes") or "")[:200]}
    for k in MEASURE_KEYS:
        try:
            v = float(str(raw.get(k)).replace(",", "."))
            out[k] = round(v, 2) if 0 < v < 10000 else None
        except (TypeError, ValueError):
            out[k] = None
    length, width, height = out["length"], out["width"], out["height"]
    if length and width:
        out["perimeter"] = out["perimeter"] or round(2 * (length + width), 2)
        out["floor_area"] = out["floor_area"] or round(length * width, 2)
    if out["perimeter"] and height and not out["wall_area"]:
        out["wall_area"] = round(max(0.0, out["perimeter"] * height - (out["openings_area"] or 0)), 2)
    if not any(out[k] for k in MEASURE_KEYS):
        raise ValueError("no sizes")
    return out


async def api_measure(request: web.Request):
    """Замер: скриншот из приложения-рулетки/LiDAR-сканера или план → размеры комнаты."""
    form = await _form(request)
    photo = _photo(form)
    user_id = _uid(request)

    async def work():
        url = await kie.upload_image(photo, f"{user_id}_{int(time.time())}.jpg")
        return parse_measure(await kie.chat(MEASURE_SYSTEM, "Найди размеры помещения на картинке.",
                                            image_url=url, max_tokens=600))
    sizes = await paid(request, "measure", work)
    return web.json_response({"sizes": sizes, "credits": await credits_of(user_id)})


async def api_advice(request: web.Request):
    from .web import object_or_404
    obj = await object_or_404(request)
    card = summary(obj, await db.expense_totals(obj["id"]), await db.list_stages(obj["id"]))
    expenses = await db.list_expenses(obj["id"], limit=30)
    detail = "\n".join(f"{e['kind']}: {e['amount']} ₽ {e['note'] or ''}" for e in expenses)
    answer = await paid(request, "advice", lambda: kie.chat(
        OBJECT_ADVICE_SYSTEM, f"{card}\n\nПоследние расходы:\n{detail or 'нет'}"))
    return web.json_response({"html": safe_html(answer), "raw": answer, "credits": await credits_of(_uid(request))})


async def api_voice(request: web.Request):
    """Голос → текст (бесплатно, как в боте)."""
    form = await _form(request)
    audio = form.get("audio")
    if not isinstance(audio, tuple) or not audio[0] or len(audio[0]) > MAX_AUDIO:
        raise ValueError("audio")
    mime = audio[1].split(";")[0] or "audio/webm"
    ext = {"audio/mp4": "m4a", "audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/wav": "wav"}.get(mime, "webm")
    try:
        text = await kie.transcribe(audio[0], f"{_uid(request)}_{int(time.time())}.{ext}", mime)
    except Exception:
        log.exception("web transcribe failed")
        raise web.HTTPBadGateway(text='{"error": "ai"}', content_type="application/json")
    return web.json_response({"text": text})


async def api_report(request: web.Request):
    """Фотоотчёт: фото + подписи → PDF приходит в чат с ботом."""
    bot = _bot(request)
    if not bot:
        raise web.HTTPServiceUnavailable(text='{"error": "bot"}', content_type="application/json")
    form = await _form(request)
    photos = form.get("photos")
    photos = photos if isinstance(photos, list) else [photos] if photos else []
    captions = form.get("captions") or []
    captions = captions if isinstance(captions, list) else [captions]
    if not photos or len(photos) > REPORT_MAX_PHOTOS or not all(isinstance(p, tuple) for p in photos):
        raise ValueError("photos")
    if any(len(p[0]) > MAX_PHOTO for p in photos):
        raise ValueError("photo too large")
    items = [(p[0], (captions[i] if i < len(captions) and isinstance(captions[i], str) else "").strip())
             for i, p in enumerate(photos)]
    notes = form.get("notes") if isinstance(form.get("notes"), str) else ""
    user_id = _uid(request)
    oid = int(form.get("oid") or 0) if str(form.get("oid") or "0").isdigit() else 0
    obj = await db.get_object(oid, user_id) if oid else None
    title = f"Фотоотчёт: {obj['name']}" if obj else "Фотоотчёт о ходе работ"
    from .web import USER
    author = str(request[USER].get("first_name") or "")

    async def work():
        caps = "\n".join(f"Фото {i}: {c or 'без подписи'}" for i, (_, c) in enumerate(items, 1))
        summary_text = await kie.chat(REPORT_SYSTEM, f"Объект: {obj['name'] if obj else 'не указан'}\n"
                                                     f"Общий комментарий прораба: {notes or 'нет'}\n{caps}",
                                      max_tokens=800)
        pdf = await asyncio.to_thread(build_pdf, title, items, summary_text, author)
        name = f"otchet_{obj['id']}.pdf" if obj else "otchet.pdf"
        await bot.send_document(user_id, BufferedInputFile(pdf, filename=name),
                                caption=f"📄 <b>{html.escape(title)}</b>\nМожно сразу переслать заказчику.")
        return summary_text
    summary_text = await paid(request, "report", work)
    return web.json_response({"ok": True, "summary": summary_text, "credits": await credits_of(user_id)})


async def api_send(request: web.Request):
    """Отправить ответ себе в чат с ботом, чтобы не потерялся."""
    from .web import body
    bot = _bot(request)
    if not bot:
        raise web.HTTPServiceUnavailable(text='{"error": "bot"}', content_type="application/json")
    data = await body(request)
    text = str(data.get("text", ""))[:12000]
    photo = str(data.get("photo", ""))
    user_id = _uid(request)
    if photo.startswith("https://"):
        await bot.send_photo(user_id, photo, caption=text[:1000] or None)
        return web.json_response({"ok": True})
    if not text.strip():
        raise ValueError("text")
    for i in range(0, len(text), 3900):
        chunk = text[i:i + 3900]
        try:
            await bot.send_message(user_id, chunk)
        except Exception:
            await bot.send_message(user_id, chunk, parse_mode=None)
    return web.json_response({"ok": True})


def add_routes(app: web.Application) -> None:
    r = app.router
    r.add_get("/api/profile", api_profile)
    r.add_post("/api/profile/role", api_set_role)
    r.add_post("/api/invoice", api_invoice)
    r.add_post("/api/ai/text", api_text_tool)
    r.add_post("/api/ai/check", api_check)
    r.add_post("/api/ai/design", api_design)
    r.add_post("/api/ai/voice", api_voice)
    r.add_post("/api/ai/measure", api_measure)
    r.add_post("/api/objects/{oid:\\d+}/advice", api_advice)
    r.add_post("/api/report", api_report)
    r.add_post("/api/send", api_send)
