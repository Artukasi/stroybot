"""Приложение СтройСкан для iPhone (LiDAR, Apple RoomPlan) ↔ бот.
1. В Mini App или командой /scanner пользователь получает одноразовый код и ссылку.
2. Приложение меняет код на постоянный токен (/scan/pair).
3. Сканы комнат приходят на /scan/rooms (или файлом .stroyscan.json в чат): сохраняем, пишем в чат,
   показываем в «Замере по скану».
4. Ремонт в 3D: приложение и Mini App хранят выбор отделки и мебели (look), по снимку 3D-модели
   делают фото «как в жизни» (render) и подбирают мебель по размерам (furniture)."""
import asyncio
import base64
import binascii
import html
import json
import logging
import math
import time
from collections import defaultdict
from urllib.parse import quote

from aiohttp import web

from aiogram.types import InlineKeyboardButton as B, InlineKeyboardMarkup as M

from . import db, furniture, scan_ai
from .calc import scan_materials
from .keyboards import webapp_button
from .look import clean_look
from .prompts import DESIGN_STYLES
from .config import config
from .web_tools import BOT, MEASURE_KEYS, credits_of, paid, safe_html

log = logging.getLogger(__name__)
_attempts: dict[str, list[float]] = defaultdict(list)
MAX_ATTEMPTS = 20          # попыток ввести код с одного адреса за 10 минут
MAX_ITEMS = 80
MAX_WALLS = 40             # точных стен; больше — комнату строим по контуру пола
MAX_WALL_LEN = 30          # м, одна стена
MAX_COORD = 100            # м, координаты на плане
MAX_PLAN = 200             # точек контура пола
MAX_SCAN_PHOTO = 6 * 1024 * 1024
MAX_RENDER = 8 * 1024 * 1024       # снимок 3D-модели для фото «как в жизни»
MAX_LOOK_BODY = 64 * 1024
MAX_ISSUES, MAX_ISSUE_LEN = 10, 120
SCAN_KEYS = MEASURE_KEYS + ("skirting", "slopes")
OPENING_KINDS = ("window", "door", "opening")


def base_url(request: web.Request) -> str:
    return config.webapp_url or str(request.url.origin())


def pair_link(request: web.Request, code: str) -> str:
    return f"{base_url(request)}/scan/link?c={code}"


def _num(v, hi: float = 10000) -> float | None:
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return round(v, 3) if 0 < v < hi else None


def _coord(v, lo: float = -1000, hi: float = 1000) -> float | None:
    """Конечное число в пределах [lo, hi] (может быть нулём и отрицательным), иначе None."""
    if isinstance(v, bool):
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return round(v, 3) if math.isfinite(v) and lo <= v <= hi else None


def _list(v) -> list:
    return v if isinstance(v, list) else []


def _wall_lines(raw, count: int, plan: list) -> list:
    """Концы стен на плане. Хоть одна битая, длиннее 30 м или дальше 1 м от контура пола,
    или их не столько, сколько стен, — не берём ничего: комнату построим по контуру пола."""
    raw = _list(raw)
    if not 0 < len(raw) == count <= MAX_WALLS:
        return []
    xs, ys = [p[0] for p in plan], [p[1] for p in plan]
    box = (min(xs) - 1, min(ys) - 1, max(xs) + 1, max(ys) + 1) if len(plan) > 2 else None
    lines = []
    for ln in raw:
        pts = [_coord(v, -MAX_COORD, MAX_COORD) for v in ln] if isinstance(ln, (list, tuple)) and len(ln) == 4 \
            else [None]
        if None in pts or math.hypot(pts[2] - pts[0], pts[3] - pts[1]) > MAX_WALL_LEN:
            return []
        if box and not all(box[0] <= x <= box[2] and box[1] <= y <= box[3] for x, y in (pts[:2], pts[2:])):
            return []
        lines.append(pts)
    return lines


def _opening(o: dict, walls: int) -> dict:
    wall = o.get("wall")
    if isinstance(wall, float) and wall.is_integer():
        wall = int(wall)
    offset, bottom = _coord(o.get("offset"), -1, 100), _coord(o.get("bottom"), -1, 10)
    return {"kind": o.get("kind") if o.get("kind") in OPENING_KINDS else "opening",
            "width": _num(o.get("width"), 20), "height": _num(o.get("height"), 20),
            "wall": wall if isinstance(wall, int) and not isinstance(wall, bool) and 0 <= wall < walls else None,
            "offset": None if offset is None else max(0.0, offset),
            "bottom": None if bottom is None else max(0.0, bottom)}


def _quality(q) -> dict | None:
    """Оценка скана и подсказки, что доснять (текст телефона — показываем экранированным)."""
    if not isinstance(q, dict):
        return None
    score = _coord(q.get("score"), -1e9, 1e9)
    issues = [" ".join(x.split())[:MAX_ISSUE_LEN] for x in _list(q.get("issues")) if isinstance(x, str) and x.strip()]
    return {"score": None if score is None else int(min(100, max(0, round(score)))), "issues": issues[:MAX_ISSUES]}


def clean_scan(data: dict) -> dict:
    """Проверяем и ужимаем то, что прислал телефон: только числа в разумных пределах.
    Понимает и первую версию (без концов стен, привязки окон и оценки качества), и вторую."""
    if not isinstance(data, dict):
        raise ValueError("json object expected")
    sizes_in = data.get("sizes") if isinstance(data.get("sizes"), dict) else {}
    sizes = {k: _num(sizes_in.get(k)) for k in SCAN_KEYS}
    if not any(sizes[k] for k in MEASURE_KEYS):
        raise ValueError("sizes")
    walls = [{"length": _num(w.get("length"), 100), "height": _num(w.get("height"), 20),
              "openings_area": _num(w.get("openings_area"), 100)}
             for w in _list(data.get("walls"))[:MAX_ITEMS] if isinstance(w, dict)]
    openings = [_opening(o, len(walls)) for o in _list(data.get("openings"))[:MAX_ITEMS] if isinstance(o, dict)]
    plan = []
    for p in _list(data.get("plan"))[:MAX_PLAN]:
        if isinstance(p, (list, tuple)) and len(p) == 2:
            x, y = _coord(p[0], -MAX_COORD, MAX_COORD), _coord(p[1], -MAX_COORD, MAX_COORD)
            if x is not None and y is not None:
                plan.append([x, y])
    objects = []
    for o in _list(data.get("objects"))[:MAX_ITEMS]:
        if not isinstance(o, dict):
            continue
        kind = str(o.get("kind") or "object")[:20]
        item = {"kind": kind if kind in scan_ai.FURNITURE else "object",
                **{k: _num(o.get(k), 20) for k in ("width", "depth", "height")}}
        for k, hi in (("x", MAX_COORD), ("y", MAX_COORD), ("angle", 1000)):
            item[k] = _coord(o.get(k), -hi, hi) or 0.0
        objects.append(item)
    return {"room": str(data.get("room") or "Комната").strip()[:60] or "Комната", "sizes": sizes,
            "walls": walls, "wall_lines": _wall_lines(data.get("wall_lines"), len(walls), plan),
            "openings": openings, "plan": plan, "objects": objects, "quality": _quality(data.get("quality")),
            "source": "lidar"}


def decode_image(raw, limit: int, png: bool = False) -> bytes | None:
    """base64 (можно data:…;base64,…) → JPEG (или PNG). Битое или огромное — None."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        image = base64.b64decode(raw.split(",")[-1], validate=True)
    except (binascii.Error, ValueError):
        return None
    if len(image) > limit or not (image.startswith(b"\xff\xd8") or png and image.startswith(b"\x89PNG")):
        return None
    return image


def decode_photo(data: dict) -> bytes | None:
    """Фото комнаты с iPhone (base64 JPEG) для картинки ремонта. Битое или огромное — пропускаем."""
    return decode_image(data.get("photo") if isinstance(data, dict) else None, MAX_SCAN_PHOTO)


async def save_scan(user_id: int, data: dict) -> dict:
    """Проверяет и сохраняет скан вместе с фото и ремонтом из 3D, если приложение положило его в файл.
    Один путь для приложения (/scan/rooms) и файла в чате."""
    scan = clean_scan(data)
    photo = decode_photo(data)
    scan["has_photo"] = photo is not None
    scan["id"] = await db.add_scan(user_id, scan["room"], {k: v for k, v in scan.items() if k != "room"})
    if photo:
        scan_ai.photo_path(scan["id"]).write_bytes(photo)
    try:
        look = clean_look(data.get("look"), scan) if isinstance(data.get("look"), dict) else {}
    except ValueError:          # слишком большой — скан всё равно берём, без ремонта
        look = {}
    if look:
        await db.set_scan_look(user_id, scan["id"], look)
    scan["look"] = look or None
    return scan


def scan_text(scan: dict) -> str:
    s = scan["sizes"]
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".").replace(".", ",") if v else "—"  # noqa: E731
    windows = sum(1 for o in scan["openings"] if o["kind"] == "window")
    doors = sum(1 for o in scan["openings"] if o["kind"] == "door")
    items = scan_ai.furniture_ru(scan)
    issues = (scan.get("quality") or {}).get("issues") or []
    return (f"📐 <b>Скан с iPhone: {html.escape(scan['room'])}</b>\n"
            f"Пол {f(s['floor_area'])} м², стены {f(s['wall_area'])} м², периметр {f(s['perimeter'])} м, "
            f"высота {f(s['height'])} м\nОкон: {windows}, дверей: {doors}\n"
            + (f"Мебель: {html.escape(', '.join(items))}\n" if items else "")
            + ("\n⚠️ <b>Нужно доснять:</b>\n" + "\n".join(f"• {html.escape(i)}" for i in issues)
               + "\nПересканируйте эти места в СтройСкане — размеры и ремонт будут точнее.\n" if issues else "")
            + ("\n🧊 Ваш ремонт из 3D сохранён: картинка, мебель и смета учтут его.\n" if scan.get("look") else "")
            + "\n" + scan_materials(scan).text()
            + "\n\nНиже можно посмотреть ремонт на картинке, подобрать мебель по размерам или получить смету.")


def scan_kb(scan_id: int) -> M:
    rows = [
        [B(text="🎨 Ремонт на картинке", callback_data=f"sd:{scan_id}")],
        [B(text="🛋 Мебель по размерам", callback_data=f"sf:{scan_id}")],
        [B(text="📋 Смета по скану", callback_data=f"se:{scan_id}")],
    ]
    app = webapp_button(f"#scan/{scan_id}", "🧊 Ремонт в 3D: крутить и менять")
    if app:
        rows.insert(1, [app])
    return M(inline_keyboard=rows)


# ---------- для Mini App (подпись Telegram) ----------

async def api_scan_code(request: web.Request):
    from .web import uid
    code = await db.create_scan_code(uid(request))
    return web.json_response({"code": code, "link": pair_link(request, code), "expires_in": 600})


def scan_view(scan: dict) -> dict:
    """Скан для Mini App: данные + готовые материалы и мебель по-русски. У старых сканов новых полей нет —
    отдаём их пустыми, чтобы страница строила 3D одинаково."""
    openings = [{"wall": None, "offset": None, "bottom": None, **o} for o in scan.get("openings") or []]
    return {**scan, "wall_lines": scan.get("wall_lines") or [], "openings": openings,
            "quality": scan.get("quality"), "look": scan.get("look") or {},
            "materials": scan_materials(scan).lines, "furniture": scan_ai.furniture_ru(scan)}


async def api_scans(request: web.Request):
    from .web import uid
    return web.json_response({"scans": [scan_view(x) for x in await db.list_scans(uid(request))]})


async def _owned_scan(user_id: int, scan_id) -> dict:
    try:
        scan = await db.get_scan(user_id, int(scan_id))
    except (TypeError, ValueError):
        scan = None
    if not scan:
        raise web.HTTPNotFound(text='{"error": "scan"}', content_type="application/json")
    return scan


async def _look(user_id: int, scan: dict, raw) -> dict | None:
    """Ремонт из 3D, присланный вместе с запросом картинки. Непустой — сохраняем: бот и смета его увидят."""
    if raw is None:
        return scan.get("look")
    look = clean_look(raw, scan)
    if look:
        await db.set_scan_look(user_id, scan["id"], look)
    return look


async def _design(request: web.Request, user_id: int, scan_id, style, look=None) -> web.Response:
    if style not in DESIGN_STYLES:
        return web.json_response({"error": "style"}, status=400)
    scan = await _owned_scan(user_id, scan_id)
    look = await _look(user_id, scan, look)
    image = await paid(request, "design", lambda: scan_ai.design_image(scan, style, look), user_id=user_id)
    return web.json_response({"image": image, "style": DESIGN_STYLES[style][0],
                              "credits": await credits_of(user_id)})


async def _render(request: web.Request, user_id: int, scan_id, data: dict) -> web.Response:
    """Снимок 3D-модели → фото «как в жизни». Стоит как картинка ремонта, при ошибке кредиты возвращаются."""
    style = data.get("style")
    if style not in DESIGN_STYLES:
        return web.json_response({"error": "style"}, status=400)
    image = decode_image(data.get("image"), MAX_RENDER, png=True)
    if image is None:
        return web.json_response({"error": "image"}, status=400)
    scan = await _owned_scan(user_id, scan_id)
    look = await _look(user_id, scan, data.get("look"))
    url = await paid(request, "design", lambda: scan_ai.render_image(scan, image, style, look), user_id=user_id)
    return web.json_response({"image": url, "style": DESIGN_STYLES[style][0], "credits": await credits_of(user_id)})


async def _furniture(user_id: int, scan_id) -> web.Response:
    scan = await _owned_scan(user_id, scan_id)
    # геометрия считается в отдельном потоке: бот и Mini App тем временем отвечают другим
    return web.json_response({"items": await asyncio.to_thread(furniture.pick, scan, scan.get("look"))})


async def _get_look(user_id: int, scan_id) -> web.Response:
    scan = await _owned_scan(user_id, scan_id)
    return web.json_response({"look": scan.get("look") or {}})


async def _put_look(request: web.Request, user_id: int, scan_id, raw) -> web.Response:
    if (request.content_length or 0) > MAX_LOOK_BODY:
        raise ValueError("look too large")
    scan = await _owned_scan(user_id, scan_id)
    look = clean_look(raw, scan)
    await db.set_scan_look(user_id, scan["id"], look)
    return web.json_response({"look": look})


async def api_scan(request: web.Request):
    from .web import uid
    return web.json_response(scan_view(await _owned_scan(uid(request), request.match_info["sid"])))


async def api_scan_design(request: web.Request):
    from .web import body, uid
    data = await body(request)
    return await _design(request, uid(request), request.match_info["sid"], data.get("style"), data.get("look"))


async def api_scan_render(request: web.Request):
    from .web import body, uid
    return await _render(request, uid(request), request.match_info["sid"], await body(request))


async def api_scan_furniture(request: web.Request):
    from .web import uid
    return await _furniture(uid(request), request.match_info["sid"])


async def api_scan_look(request: web.Request):
    from .web import uid
    return await _get_look(uid(request), request.match_info["sid"])


async def api_scan_look_put(request: web.Request):
    from .web import body, uid
    data = await body(request)
    return await _put_look(request, uid(request), request.match_info["sid"], data["look"] if "look" in data else data)


async def api_scan_estimate(request: web.Request):
    from .web import uid
    user_id = uid(request)
    scan = await _owned_scan(user_id, request.match_info["sid"])
    answer = await paid(request, "estimate", lambda: scan_ai.estimate(scan), user_id=user_id)
    return web.json_response({"html": safe_html(answer), "raw": answer, "credits": await credits_of(user_id)})


# ---------- для приложения на iPhone ----------

async def scan_link(request: web.Request):
    """Страница из Telegram-сообщения: открывает приложение СтройСкан с кодом."""
    code = "".join(ch for ch in request.query.get("c", "") if ch.isalnum())[:12]
    app_url = f"stroyscan://pair?server={quote(base_url(request), safe='')}&code={code}"
    page = f"""<!doctype html><html lang="ru"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>СтройСкан</title>
<style>body{{font:17px/1.45 system-ui,sans-serif;margin:0;padding:32px 20px;background:#E6ECF2;color:#14202E}}
a{{display:block;margin:22px 0;padding:16px;border-radius:14px;background:#F5C518;color:#14202E;text-align:center;font-weight:700;text-decoration:none}}
code{{font-size:22px;letter-spacing:.12em}}</style>
<h1>Подключить СтройСкан</h1>
<p>Нажмите кнопку, и приложение на iPhone подключится к вашему аккаунту в боте.</p>
<a href="{html.escape(app_url)}">Открыть СтройСкан</a>
<p>Если не открылось, введите в приложении адрес<br><b>{html.escape(base_url(request))}</b><br>и код <code>{html.escape(code)}</code>.
Код действует 10 минут.</p>
<script>setTimeout(function(){{location.href={json.dumps(app_url)}}},300)</script></html>"""
    return web.Response(text=page, content_type="text/html")


async def scan_pair(request: web.Request):
    ip = request.headers.get("X-Real-IP") or request.remote or "?"
    now = time.time()
    _attempts[ip] = [t for t in _attempts[ip] if now - t < 600]
    if len(_attempts[ip]) >= MAX_ATTEMPTS:
        return web.json_response({"error": "too many attempts"}, status=429)
    _attempts[ip].append(now)
    data = await request.json()
    res = await db.redeem_scan_code(str(data.get("code", "")), str(data.get("device", "")))
    if not res:
        return web.json_response({"error": "bad code"}, status=403)
    user = await db.get_user(res[0])
    return web.json_response({"token": res[1], "name": (user or {}).get("username") or ""})


async def _scan_user(request: web.Request) -> int:
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    user_id = await db.user_by_scan_token(token)
    if not user_id:
        raise web.HTTPUnauthorized(text='{"error": "unauthorized"}', content_type="application/json")
    return user_id


async def scan_me(request: web.Request):
    user_id = await _scan_user(request)
    user = await db.get_user(user_id)
    return web.json_response({"ok": True, "name": (user or {}).get("username") or ""})


async def scan_rooms(request: web.Request):
    user_id = await _scan_user(request)
    scan = await save_scan(user_id, await request.json())
    bot = request.app.get(BOT)
    if bot:
        try:
            await bot.send_message(user_id, scan_text(scan), reply_markup=scan_kb(scan["id"]))
        except Exception:
            log.exception("scan notify failed")
    return web.json_response({"id": scan["id"]}, status=201)


async def scan_design(request: web.Request):
    """Картинка ремонта прямо в приложении на iPhone."""
    from .web import body
    user_id = await _scan_user(request)
    data = await body(request)
    return await _design(request, user_id, data.get("scan_id", data.get("id")), data.get("style"), data.get("look"))


async def scan_render(request: web.Request):
    """Фото «как в жизни» по снимку 3D-модели из приложения."""
    from .web import body
    user_id = await _scan_user(request)
    data = await body(request)
    return await _render(request, user_id, data.get("scan_id"), data)


async def scan_furniture(request: web.Request):
    from .web import body
    user_id = await _scan_user(request)
    return await _furniture(user_id, (await body(request)).get("scan_id"))


async def scan_look(request: web.Request):
    user_id = await _scan_user(request)
    return await _get_look(user_id, request.query.get("scan_id"))


async def scan_look_put(request: web.Request):
    from .web import body
    user_id = await _scan_user(request)
    data = await body(request)
    return await _put_look(request, user_id, data.get("scan_id"), data.get("look"))


def add_routes(app: web.Application) -> None:
    r = app.router
    r.add_post("/api/scan-code", api_scan_code)
    r.add_get("/api/scans", api_scans)
    r.add_get("/api/scans/{sid}", api_scan)
    r.add_post("/api/scans/{sid}/design", api_scan_design)
    r.add_post("/api/scans/{sid}/render", api_scan_render)
    r.add_post("/api/scans/{sid}/estimate", api_scan_estimate)
    r.add_get("/api/scans/{sid}/furniture", api_scan_furniture)
    r.add_get("/api/scans/{sid}/look", api_scan_look)
    r.add_put("/api/scans/{sid}/look", api_scan_look_put)
    r.add_post("/scan/design", scan_design)
    r.add_post("/scan/render", scan_render)
    r.add_post("/scan/furniture", scan_furniture)
    r.add_get("/scan/look", scan_look)
    r.add_put("/scan/look", scan_look_put)
    r.add_get("/scan/link", scan_link)
    r.add_post("/scan/pair", scan_pair)
    r.add_get("/scan/me", scan_me)
    r.add_post("/scan/rooms", scan_rooms)
