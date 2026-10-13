"""Mini App: веб-сервер (aiohttp) — отдаёт страницу приложения и JSON API для объектов и калькулятора
(платные ИИ-функции — в web_tools.py).
Каждый запрос к API подписан Telegram (initData), поэтому пользователь видит только свои объекты."""
import hashlib
import hmac
import json
import logging
import time
from pathlib import Path
from urllib.parse import parse_qsl

from aiohttp import web

from . import db
from .calc import CALCS
from .config import config
from .db import EXPENSE_KINDS
from .objects import parse_date

log = logging.getLogger(__name__)
WEBAPP_DIR = Path(__file__).parent / "webapp"
MAX_AGE = 24 * 3600
USER = web.RequestKey("user", dict) if hasattr(web, "RequestKey") else "user"


def validate_init_data(init_data: str, bot_token: str, max_age: int = MAX_AGE,
                       now: float | None = None) -> dict | None:
    """Проверяет подпись initData от Telegram. Возвращает данные пользователя или None."""
    try:
        pairs = dict(parse_qsl(init_data, keep_blank_values=True, strict_parsing=True))
    except ValueError:
        return None
    received = pairs.pop("hash", None)
    if not received:
        return None
    check = "\n".join(f"{k}={v}" for k, v in sorted(pairs.items()))
    secret = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    expected = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, received):
        return None
    try:
        auth_date = int(pairs.get("auth_date", "0"))
        user = json.loads(pairs.get("user", "{}"))
    except ValueError:
        return None
    if max_age and (now or time.time()) - auth_date > max_age:
        return None
    if not isinstance(user, dict) or not isinstance(user.get("id"), int):
        return None
    return user


# Эти функции Mini App доступны и приложению на iPhone: оно входит по ключу из /scanner (Bearer), а не по initData
APP_PATHS = ("/api/profile", "/api/invoice", "/api/ai/text", "/api/ai/check", "/api/ai/design", "/api/ai/voice",
             "/api/ai/measure", "/api/report", "/api/send")


async def app_user(request: web.Request) -> dict | None:
    """Пользователь приложения по ключу; только для APP_PATHS."""
    if request.path not in APP_PATHS:
        return None
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    user_id = await db.user_by_scan_token(token) if token else None
    if not user_id:
        return None
    row = await db.get_user(user_id) or {}
    return {"id": user_id, "username": row.get("username"), "first_name": "", "app": True}


@web.middleware
async def auth_middleware(request: web.Request, handler):
    if request.path.startswith("/api/"):
        user = validate_init_data(request.headers.get("X-Telegram-Init-Data", ""), config.bot_token)
        if not user:
            user = await app_user(request)
        if not user:
            return web.json_response({"error": "unauthorized"}, status=401)
        request[USER] = user
        await db.get_or_create_user(user["id"], user.get("username"))
    try:
        return await handler(request)
    except web.HTTPException:
        raise
    except (ValueError, KeyError, TypeError) as e:
        return web.json_response({"error": f"bad request: {e}"}, status=400)


def uid(request: web.Request) -> int:
    return request[USER]["id"]


async def body(request: web.Request) -> dict:
    data = await request.json()
    if not isinstance(data, dict):
        raise ValueError("json object expected")
    return data


def clean_amount(value) -> int:
    amount = int(round(float(value)))
    if amount <= 0 or amount > 10_000_000_000:
        raise ValueError("amount out of range")
    return amount


def clean_due(value) -> str | None:
    if not value:
        return None
    value = str(value)
    if len(value) == 10 and value[4] == "-" and value[7] == "-":
        return value
    return parse_date(value)


async def object_or_404(request: web.Request) -> dict:
    obj = await db.get_object(int(request.match_info["oid"]), uid(request))
    if not obj:
        raise web.HTTPNotFound(text=json.dumps({"error": "not found"}), content_type="application/json")
    return obj


# ---------- страницы ----------

async def index(request: web.Request):
    return web.FileResponse(WEBAPP_DIR / "index.html", headers={"Cache-Control": "no-cache"})


async def script(request: web.Request):
    """Скрипты страницы: 3D-комната (room3d.js) и three.js в vendor/ — грузятся, только когда открыли 3D.
    В vendor/ версия в имени файла, поэтому кешируем надолго; сжимаем на лету."""
    name = request.match_info["name"]
    path = WEBAPP_DIR / name
    if not path.is_file():
        raise web.HTTPNotFound()
    cache = "public, max-age=31536000, immutable" if name.startswith("vendor/") else "no-cache"
    resp = web.FileResponse(path, headers={"Cache-Control": cache, "Content-Type": "text/javascript; charset=utf-8"})
    resp.enable_compression()
    return resp


async def health(request: web.Request):
    return web.json_response({"ok": True})


# ---------- API ----------

async def api_me(request: web.Request):
    user = await db.get_user(uid(request))
    objects = []
    for o in await db.list_objects(uid(request)):
        totals = await db.expense_totals(o["id"])
        stages = await db.list_stages(o["id"])
        objects.append({**o, "spent": sum(totals.values()),
                        "stages_total": len(stages), "stages_done": sum(s["done"] for s in stages)})
    return web.json_response({
        "user": {"id": user["id"], "credits": user["credits"], "role": user.get("role")},
        "objects": objects,
        "expense_kinds": EXPENSE_KINDS,
        "calcs": {k: {"title": v[0], "hint": v[1], "min": v[2]} for k, v in CALCS.items()},
    })


async def api_archived(request: web.Request):
    return web.json_response({"objects": await db.list_objects(uid(request), archived=True)})


async def api_create_object(request: web.Request):
    data = await body(request)
    name = str(data.get("name", "")).strip()
    if not name:
        raise ValueError("name required")
    budget = int(data.get("budget") or 0)
    oid = await db.create_object(uid(request), name, str(data.get("address", "")), budget)
    return web.json_response({"id": oid}, status=201)


async def api_object(request: web.Request):
    obj = await object_or_404(request)
    return web.json_response({
        "object": obj,
        "totals": await db.expense_totals(obj["id"]),
        "expenses": await db.list_expenses(obj["id"], limit=200),
        "stages": await db.list_stages(obj["id"]),
    })


async def api_update_object(request: web.Request):
    obj = await object_or_404(request)
    data = await body(request)
    fields = {}
    if "name" in data and str(data["name"]).strip():
        fields["name"] = str(data["name"]).strip()[:100]
    if "address" in data:
        fields["address"] = str(data["address"]).strip()[:200]
    if "budget" in data:
        fields["budget"] = max(0, int(data["budget"] or 0))
    if "archived" in data:
        fields["archived"] = 1 if data["archived"] else 0
    await db.update_object(obj["id"], uid(request), **fields)
    return web.json_response({"ok": True})


async def api_delete_object(request: web.Request):
    obj = await object_or_404(request)
    await db.delete_object(obj["id"], uid(request))
    return web.json_response({"ok": True})


async def api_add_expense(request: web.Request):
    obj = await object_or_404(request)
    data = await body(request)
    eid = await db.add_expense(obj["id"], str(data.get("kind", "other")), clean_amount(data.get("amount")),
                               str(data.get("note", "")))
    return web.json_response({"id": eid}, status=201)


async def api_delete_expense(request: web.Request):
    ok = await db.delete_expense(int(request.match_info["eid"]), uid(request))
    return web.json_response({"ok": ok}, status=200 if ok else 404)


async def api_add_stage(request: web.Request):
    obj = await object_or_404(request)
    data = await body(request)
    name = str(data.get("name", "")).strip()
    if not name:
        raise ValueError("name required")
    sid = await db.add_stage(obj["id"], name, clean_due(data.get("due")))
    return web.json_response({"id": sid}, status=201)


async def api_update_stage(request: web.Request):
    data = await body(request)
    ok = await db.set_stage_done(int(request.match_info["sid"]), uid(request), bool(data.get("done")))
    return web.json_response({"ok": ok}, status=200 if ok else 404)


async def api_delete_stage(request: web.Request):
    ok = await db.delete_stage(int(request.match_info["sid"]), uid(request))
    return web.json_response({"ok": ok}, status=200 if ok else 404)


async def api_calc(request: web.Request):
    data = await body(request)
    key = data.get("key")
    if key not in CALCS:
        raise ValueError("unknown calc")
    _, _, min_n, fn = CALCS[key]
    nums = [float(x) for x in data.get("numbers", [])]
    if len(nums) < min_n or any(n <= 0 for n in nums):
        raise ValueError("numbers")
    res = fn(nums)
    return web.json_response({"title": res.title, "lines": res.lines})


def create_app(bot=None) -> web.Application:
    from .web_tools import BOT, add_routes, credits_middleware
    # фото для дизайна, проверки и фотоотчёта приходят в теле запроса — до 30 МБ за раз
    app = web.Application(middlewares=[auth_middleware, credits_middleware], client_max_size=30 * 1024 * 1024)
    if bot is not None:
        app[BOT] = bot
    app.router.add_get("/", health)
    app.router.add_get("/health", health)
    app.router.add_get("/app/", index)
    app.router.add_get("/app", index)
    app.router.add_get(r"/app/{name:(vendor/)?[\w-]+(\.min)?\.js}", script)
    app.router.add_get("/api/me", api_me)
    app.router.add_get("/api/objects/archived", api_archived)
    app.router.add_post("/api/objects", api_create_object)
    app.router.add_get("/api/objects/{oid:\\d+}", api_object)
    app.router.add_patch("/api/objects/{oid:\\d+}", api_update_object)
    app.router.add_delete("/api/objects/{oid:\\d+}", api_delete_object)
    app.router.add_post("/api/objects/{oid:\\d+}/expenses", api_add_expense)
    app.router.add_delete("/api/expenses/{eid:\\d+}", api_delete_expense)
    app.router.add_post("/api/objects/{oid:\\d+}/stages", api_add_stage)
    app.router.add_patch("/api/stages/{sid:\\d+}", api_update_stage)
    app.router.add_delete("/api/stages/{sid:\\d+}", api_delete_stage)
    app.router.add_post("/api/calc", api_calc)
    add_routes(app)
    from .web_scan import add_routes as add_scan_routes
    add_scan_routes(app)
    from .web_folio import add_routes as add_folio_routes
    add_folio_routes(app)
    return app


async def start_web(bot=None) -> web.AppRunner:
    runner = web.AppRunner(create_app(bot))
    await runner.setup()
    site = web.TCPSite(runner, config.web_host, config.web_port)
    await site.start()
    log.info("Mini App: http://%s:%s/app/ (публично: %s/app/)", config.web_host, config.web_port,
             config.webapp_url)
    return runner
