"""Приложение СтройСкан для iPhone (LiDAR, Apple RoomPlan) ↔ бот.
1. В Mini App или командой /scanner пользователь получает одноразовый код и ссылку.
2. Приложение меняет код на постоянный токен (/scan/pair).
3. Сканы комнат приходят на /scan/rooms: сохраняем, пишем в чат, показываем в «Замере по скану»."""
import html
import json
import logging
import time
from collections import defaultdict
from urllib.parse import quote

from aiohttp import web

from . import db
from .config import config
from .web_tools import BOT, MEASURE_KEYS

log = logging.getLogger(__name__)
_attempts: dict[str, list[float]] = defaultdict(list)
MAX_ATTEMPTS = 20          # попыток ввести код с одного адреса за 10 минут
MAX_ITEMS = 80


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


def clean_scan(data: dict) -> dict:
    """Проверяем и ужимаем то, что прислал телефон: только числа в разумных пределах."""
    if not isinstance(data, dict):
        raise ValueError("json object expected")
    sizes_in = data.get("sizes") or {}
    sizes = {k: _num(sizes_in.get(k)) for k in MEASURE_KEYS}
    if not any(sizes.values()):
        raise ValueError("sizes")
    walls = [{"length": _num(w.get("length"), 100), "height": _num(w.get("height"), 20)}
             for w in (data.get("walls") or [])[:MAX_ITEMS] if isinstance(w, dict)]
    openings = [{"kind": str(o.get("kind", "opening"))[:10], "width": _num(o.get("width"), 20),
                 "height": _num(o.get("height"), 20)}
                for o in (data.get("openings") or [])[:MAX_ITEMS] if isinstance(o, dict)]
    plan = []
    for p in (data.get("plan") or [])[:200]:
        if isinstance(p, (list, tuple)) and len(p) == 2:
            try:
                x, y = float(p[0]), float(p[1])
            except (TypeError, ValueError):
                continue
            if abs(x) < 1000 and abs(y) < 1000:
                plan.append([round(x, 3), round(y, 3)])
    return {"room": str(data.get("room") or "Комната").strip()[:60] or "Комната", "sizes": sizes,
            "walls": walls, "openings": openings, "plan": plan, "source": "lidar"}


def scan_text(scan: dict) -> str:
    s = scan["sizes"]
    f = lambda v: f"{v:.2f}".rstrip("0").rstrip(".").replace(".", ",") if v else "—"  # noqa: E731
    windows = sum(1 for o in scan["openings"] if o["kind"] == "window")
    doors = sum(1 for o in scan["openings"] if o["kind"] == "door")
    return (f"📐 <b>Скан с iPhone: {html.escape(scan['room'])}</b>\n"
            f"Пол {f(s['floor_area'])} м², стены {f(s['wall_area'])} м², периметр {f(s['perimeter'])} м, "
            f"высота {f(s['height'])} м\nОкон: {windows}, дверей: {doors}\n\n"
            "Откройте «Замер по скану» в приложении, чтобы посчитать материалы и смету.")


# ---------- для Mini App (подпись Telegram) ----------

async def api_scan_code(request: web.Request):
    from .web import uid
    code = await db.create_scan_code(uid(request))
    return web.json_response({"code": code, "link": pair_link(request, code), "expires_in": 600})


async def api_scans(request: web.Request):
    from .web import uid
    return web.json_response({"scans": await db.list_scans(uid(request))})


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
    scan = clean_scan(await request.json())
    sid = await db.add_scan(user_id, scan["room"], {k: v for k, v in scan.items() if k != "room"})
    bot = request.app.get(BOT)
    if bot:
        try:
            await bot.send_message(user_id, scan_text(scan))
        except Exception:
            log.exception("scan notify failed")
    return web.json_response({"id": sid}, status=201)


def add_routes(app: web.Application) -> None:
    r = app.router
    r.add_post("/api/scan-code", api_scan_code)
    r.add_get("/api/scans", api_scans)
    r.add_get("/scan/link", scan_link)
    r.add_post("/scan/pair", scan_pair)
    r.add_get("/scan/me", scan_me)
    r.add_post("/scan/rooms", scan_rooms)
