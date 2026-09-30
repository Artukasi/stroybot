"""Mini App: портфолио «до/после» — список работ, добавление, пост для соцсетей, видео для Reels в чат.
Картинки отдаём по ссылкам с подписью (тег <img> не умеет слать заголовок с initData)."""
import hashlib
import hmac
import logging

from aiogram.types import BufferedInputFile
from aiohttp import web

from . import db, portfolio
from .config import config
from .web_tools import _bot, _form, _photo, _uid, credits_of, paid, safe_html

log = logging.getLogger(__name__)


def _sign(item_id: int, name: str) -> str:
    msg = f"pf:{item_id}:{name}".encode()
    return hmac.new(config.bot_token.encode(), msg, hashlib.sha256).hexdigest()[:20]


def image_url(item_id: int, name: str) -> str:
    return f"/pf/{item_id}/{name}.jpg?t={_sign(item_id, name)}"


def _view(item: dict) -> dict:
    i = item["id"]
    return {**item, "before": image_url(i, "before"), "after": image_url(i, "after"),
            "collage": image_url(i, "collage"), "ok": portfolio.has_photos(i)}


async def _owned(request: web.Request) -> dict:
    item = await db.get_portfolio(_uid(request), int(request.match_info["pid"]))
    if not item:
        raise web.HTTPNotFound(text='{"error": "portfolio"}', content_type="application/json")
    return item


async def _brand(user_id: int) -> str:
    return ((await db.get_user(user_id)) or {}).get("brand") or ""


async def api_list(request: web.Request):
    user_id = _uid(request)
    items = [_view(x) for x in await db.list_portfolio(user_id)]
    return web.json_response({"items": items, "brand": await _brand(user_id)})


async def api_add(request: web.Request):
    form = await _form(request)
    before, after = _photo(form, "before"), _photo(form, "after")
    title = form.get("title") if isinstance(form.get("title"), str) else ""
    user_id = _uid(request)
    item_id = await db.add_portfolio(user_id, title.strip())
    try:
        portfolio.save_photo(item_id, "before", before)
        portfolio.save_photo(item_id, "after", after)
    except Exception:
        await db.delete_portfolio(user_id, item_id)
        portfolio.delete_photos(item_id)
        raise ValueError("photo")
    return web.json_response(_view(await db.get_portfolio(user_id, item_id)), status=201)


async def api_delete(request: web.Request):
    item = await _owned(request)
    await db.delete_portfolio(_uid(request), item["id"])
    portfolio.delete_photos(item["id"])
    return web.json_response({"ok": True})


async def api_brand(request: web.Request):
    data = await request.json()
    await db.set_brand(_uid(request), str(data.get("brand") or ""))
    return web.json_response({"brand": await _brand(_uid(request))})


async def api_post(request: web.Request):
    item = await _owned(request)
    user_id = _uid(request)
    brand = await _brand(user_id)
    text = await paid(request, "post", lambda: portfolio.post_text(item, brand))
    return web.json_response({"html": safe_html(text), "raw": text, "collage": image_url(item["id"], "collage"),
                              "credits": await credits_of(user_id)})


async def api_reel(request: web.Request):
    """Видео собираем на сервере и присылаем в чат с ботом: оттуда его удобно переслать или сохранить."""
    item = await _owned(request)
    bot = _bot(request)
    if not bot:
        raise web.HTTPServiceUnavailable(text='{"error": "bot"}', content_type="application/json")
    if not portfolio.has_photos(item["id"]):
        raise ValueError("photos missing")
    user_id = _uid(request)
    video = await portfolio.item_reel(item, await _brand(user_id))
    await bot.send_video(user_id, BufferedInputFile(video, f"reels_{item['id']}.mp4"), width=portfolio.W,
                         height=portfolio.H, supports_streaming=True,
                         caption="🎬 Видео для Reels, Shorts и VK Клипов. Музыку добавьте в самом приложении.")
    return web.json_response({"ok": True})


async def api_send_collage(request: web.Request):
    item = await _owned(request)
    bot = _bot(request)
    if not bot:
        raise web.HTTPServiceUnavailable(text='{"error": "bot"}', content_type="application/json")
    data = await request.json() if request.can_read_body else {}
    caption = str(data.get("text") or item["title"] or "")[:1000]
    image = portfolio.item_collage(item, await _brand(_uid(request)))
    await bot.send_photo(_uid(request), BufferedInputFile(image, f"portfolio_{item['id']}.jpg"), caption=caption)
    return web.json_response({"ok": True})


async def image(request: web.Request):
    item_id, name = int(request.match_info["pid"]), request.match_info["name"]
    if name not in ("before", "after", "collage") or \
            not hmac.compare_digest(request.query.get("t", ""), _sign(item_id, name)):
        raise web.HTTPForbidden()
    if not portfolio.has_photos(item_id):
        raise web.HTTPNotFound()
    headers = {"Cache-Control": "private, max-age=86400"}
    if name == "collage":
        # подпись бригады на коллаже берём у владельца работы
        owner = await _owner(item_id)
        item = await db.get_portfolio(owner, item_id) if owner else None
        if not item:
            raise web.HTTPNotFound()
        return web.Response(body=portfolio.item_collage(item, await _brand(owner)), content_type="image/jpeg",
                            headers=headers)
    return web.FileResponse(portfolio.photo_path(item_id, name), headers=headers)


async def _owner(item_id: int) -> int | None:
    import aiosqlite
    async with aiosqlite.connect(config.db_path) as conn:
        row = await (await conn.execute("SELECT user_id FROM portfolio WHERE id=?", (item_id,))).fetchone()
    return row[0] if row else None


def add_routes(app: web.Application) -> None:
    r = app.router
    r.add_get("/api/portfolio", api_list)
    r.add_post("/api/portfolio", api_add)
    r.add_post("/api/portfolio/brand", api_brand)
    r.add_delete("/api/portfolio/{pid:\\d+}", api_delete)
    r.add_post("/api/portfolio/{pid:\\d+}/post", api_post)
    r.add_post("/api/portfolio/{pid:\\d+}/reel", api_reel)
    r.add_post("/api/portfolio/{pid:\\d+}/send", api_send_collage)
    r.add_get("/pf/{pid:\\d+}/{name}.jpg", image)
