"""Платные функции в Mini App: списание и возврат кредитов, дизайн, проверка, замер, фотоотчёт, оплата."""
import asyncio

import aiohttp
import pytest
from aiohttp.test_utils import TestClient, TestServer

from bot import db, kie
from bot.config import FREE_CONSULT_PER_DAY, PRICES, config
from bot.web import create_app
from bot.web_tools import parse_measure, safe_html

from .test_stage2 import TOKEN, _png, fresh_db, sign  # noqa: F401  (fresh_db — фикстура)


class FakeBot:
    def __init__(self):
        self.docs, self.messages, self.invoices = [], [], []

    async def me(self):
        class Me:
            username = "stroybot_test"
        return Me()

    async def send_document(self, chat_id, document, caption=None):
        self.docs.append((chat_id, document.filename, document.data))

    async def send_photo(self, chat_id, photo, caption=None):
        self.messages.append((chat_id, photo))

    async def send_message(self, chat_id, text, **kw):
        self.messages.append((chat_id, text))

    async def create_invoice_link(self, **kw):
        self.invoices.append(kw)
        return "https://t.me/$invoice"


@pytest.fixture
def ai(monkeypatch):
    calls = []

    async def chat(system, text, image_url=None, max_tokens=2000):
        calls.append((system, text, image_url))
        if "FAIL" in text:
            raise kie.KieError("boom")
        if "размеры" in text:
            return 'Вот: ```json\n{"room": "Ванная", "length": "2,5", "width": 1.7, "height": 2.6, ' \
                   '"openings_area": 1.6, "notes": "рулетка iPhone"}\n```'
        return "<b>Ответ</b> <script>x</script>"

    async def upload(data, filename="x"):
        return f"https://files/{len(calls)}.jpg"

    async def edit(url, prompt, aspect_ratio="auto"):
        calls.append(("edit", url, prompt))
        return ["https://files/result.png"]

    async def generate(prompt, aspect_ratio="4:3"):
        calls.append(("t2i", prompt))
        return ["https://files/t2i.png"]

    async def transcribe(audio, filename="v", mime="audio/ogg"):
        return "плитка в ванной 4 метра"
    monkeypatch.setattr(kie, "chat", chat)
    monkeypatch.setattr(kie, "upload_image", upload)
    monkeypatch.setattr(kie, "edit_image", edit)
    monkeypatch.setattr(kie, "transcribe", transcribe)
    monkeypatch.setattr(kie, "generate_image", generate)
    return calls


def photo_form(**fields) -> aiohttp.FormData:
    f = aiohttp.FormData()
    f.add_field("photo", _png(), filename="p.jpg", content_type="image/jpeg")
    for k, v in fields.items():
        f.add_field(k, v)
    return f


def test_safe_html_and_measure_parser():
    assert safe_html("<b>Итог</b> <script>alert(1)</script> 5 < 6") == \
        "<b>Итог</b> &lt;script&gt;alert(1)&lt;/script&gt; 5 &lt; 6"
    m = parse_measure('{"length": "4,2", "width": 3, "height": 2.7, "openings_area": 3.5, "room": "Спальня"}')
    assert m["perimeter"] == 14.4 and m["floor_area"] == 12.6 and m["wall_area"] == 35.38
    with pytest.raises(ValueError):
        parse_measure('{"room": "кухня"}')


def test_webapp_paid_tools(fresh_db, ai):
    object.__setattr__(config, "bot_token", TOKEN)
    bot = FakeBot()

    async def run():
        async with TestClient(TestServer(create_app(bot))) as c:
            h = {"X-Telegram-Init-Data": sign({"id": 7, "first_name": "Иван"})}
            prof = await (await c.get("/api/profile", headers=h)).json()
            start = prof["credits"]
            assert prof["invite"]["link"].endswith("start=ref_7") and prof["styles"]["loft"] == "Лофт"
            assert prof["free_consult_left"] == FREE_CONSULT_PER_DAY

            # консультант: бесплатный вопрос; при ошибке ИИ бесплатный вопрос возвращается
            r = await c.post("/api/ai/text", json={"kind": "consult", "text": "как выровнять стену?"}, headers=h)
            data = await r.json()
            assert r.status == 200 and "&lt;script&gt;" in data["html"] and data["credits"] == start
            assert (await c.post("/api/ai/text", json={"kind": "consult", "text": "FAIL"}, headers=h)).status == 502
            assert (await (await c.get("/api/profile", headers=h)).json())["free_consult_left"] == FREE_CONSULT_PER_DAY - 1

            # смета списывает кредит, ошибка — возвращает
            r = await c.post("/api/ai/text", json={"kind": "estimate", "text": "Ванная 4 м2", "style": "Лофт"}, headers=h)
            assert (await r.json())["credits"] == start - PRICES["estimate"]
            assert "Лофт" in ai[-1][1]
            assert (await c.post("/api/ai/text", json={"kind": "kp", "text": "FAIL please"}, headers=h)).status == 502
            assert (await db.get_user(7))["credits"] == start - PRICES["estimate"]

            # дизайн: фото загружается один раз, второй стиль — без нового фото
            await db.add_credits(7, 10)
            r = await c.post("/api/ai/design", data=photo_form(style="loft", wishes="светлый пол"), headers=h)
            assert (await r.json())["image"] == "https://files/result.png"
            r = await c.post("/api/ai/design", data=aiohttp.FormData({"style": "japandi"}), headers=h)
            assert r.status == 200 and "japandi" in ai[-1][2]
            assert (await c.post("/api/ai/design", data=photo_form(style="nope"), headers=h)).status == 400

            # проверка работы и замер по скриншоту из «Рулетки»
            r = await c.post("/api/ai/check", data=photo_form(note="плитка"), headers=h)
            assert r.status == 200 and ai[-1][2].startswith("https://files/")
            r = await c.post("/api/ai/measure", data=photo_form(), headers=h)
            sizes = (await r.json())["sizes"]
            assert sizes["length"] == 2.5 and sizes["floor_area"] == 4.25 and sizes["room"] == "Ванная"

            # голос → текст
            f = aiohttp.FormData()
            f.add_field("audio", b"OggS...", filename="v.webm", content_type="audio/webm;codecs=opus")
            assert (await (await c.post("/api/ai/voice", data=f, headers=h)).json())["text"].startswith("плитка")

            # советы по объекту: чужой объект — 404
            oid = (await (await c.post("/api/objects", json={"name": "Дача"}, headers=h)).json())["id"]
            h2 = {"X-Telegram-Init-Data": sign({"id": 8})}
            assert (await c.post(f"/api/objects/{oid}/advice", headers=h2)).status == 404
            assert (await c.post(f"/api/objects/{oid}/advice", headers=h)).status == 200

            # фотоотчёт приходит PDF в чат
            f = aiohttp.FormData()
            for cap in ("Демонтаж", "Стяжка"):
                f.add_field("photos", _png(), filename="p.png", content_type="image/png")
                f.add_field("captions", cap)
            f.add_field("oid", str(oid))
            f.add_field("notes", "всё по графику")
            r = await c.post("/api/report", data=f, headers=h)
            assert r.status == 200
            assert bot.docs[0][0] == 7 and bot.docs[0][1] == f"otchet_{oid}.pdf" and bot.docs[0][2].startswith(b"%PDF")

            # отправить ответ себе в чат, пополнение, роль
            assert (await c.post("/api/send", json={"text": "<b>Смета</b>"}, headers=h)).status == 200
            assert bot.messages[-1] == (7, "<b>Смета</b>")
            assert (await c.post("/api/send", json={"photo": "https://files/result.png", "text": "Лофт"},
                                 headers=h)).status == 200
            assert bot.messages[-1] == (7, "https://files/result.png")
            r = await c.post("/api/invoice", json={"pack": "s"}, headers=h)
            assert (await r.json())["link"].startswith("https://t.me/") and bot.invoices[0]["currency"] == "XTR"
            assert (await c.post("/api/profile/role", json={"role": "foreman"}, headers=h)).status == 200
            assert (await db.get_user(7))["role"] == "foreman"

            # кредиты кончились → 402, ничего не списано
            await db.add_credits(7, -1000)
            r = await c.post("/api/ai/text", json={"kind": "estimate", "text": "Кухня 9 м2"}, headers=h)
            assert r.status == 402 and (await r.json())["need"] == PRICES["estimate"]
    asyncio.run(run())


def test_report_needs_bot(fresh_db, ai):
    object.__setattr__(config, "bot_token", TOKEN)

    async def run():
        async with TestClient(TestServer(create_app())) as c:
            h = {"X-Telegram-Init-Data": sign({"id": 9})}
            f = aiohttp.FormData()
            f.add_field("photos", _png(), filename="p.png", content_type="image/png")
            assert (await c.post("/api/report", data=f, headers=h)).status == 503
            assert (await db.get_user(9))["credits"] == config.welcome_credits
    asyncio.run(run())


def test_lidar_scanner_pairing_and_rooms(fresh_db):
    object.__setattr__(config, "bot_token", TOKEN)
    bot = FakeBot()

    async def run():
        async with TestClient(TestServer(create_app(bot))) as c:
            h = {"X-Telegram-Init-Data": sign({"id": 11})}
            r = await (await c.post("/api/scan-code", headers=h)).json()
            code = r["code"]
            assert len(code) == 8 and f"/scan/link?c={code}" in r["link"]
            page = await (await c.get(f"/scan/link?c={code}")).text()
            assert "stroyscan://pair?server=" in page and code in page

            assert (await c.post("/scan/pair", json={"code": "WRONG123"})).status == 403
            r = await c.post("/scan/pair", json={"code": code.lower(), "device": "iPhone 15 Pro"})
            token = (await r.json())["token"]
            assert (await c.post("/scan/pair", json={"code": code})).status == 403   # код одноразовый
            auth = {"Authorization": f"Bearer {token}"}
            assert (await c.get("/scan/me", headers=auth)).status == 200
            assert (await c.post("/scan/rooms", json={}, headers={"Authorization": "Bearer x"})).status == 401

            room = {"room": "Кухня", "sizes": {"length": 3.4, "width": 2.9, "height": 2.7, "perimeter": 12.6,
                                               "floor_area": 9.86, "wall_area": 30.1, "openings_area": 3.9},
                    "walls": [{"length": 3.4, "height": 2.7}] * 4,
                    "openings": [{"kind": "window", "width": 1.4, "height": 1.5}, {"kind": "door", "width": 0.8, "height": 2}],
                    "plan": [[0, 0], [3.4, 0], [3.4, 2.9], [0, 2.9], ["x", 1]]}
            r = await c.post("/scan/rooms", json=room, headers=auth)
            assert r.status == 201
            assert "Кухня" in bot.messages[-1][1] and "Окон: 1, дверей: 1" in bot.messages[-1][1]
            assert (await c.post("/scan/rooms", json={"room": "x", "sizes": {}}, headers=auth)).status == 400

            scans = (await (await c.get("/api/scans", headers=h)).json())["scans"]
            assert scans[0]["room"] == "Кухня" and scans[0]["sizes"]["floor_area"] == 9.86 and len(scans[0]["plan"]) == 4
            other = {"X-Telegram-Init-Data": sign({"id": 12})}
            assert (await (await c.get("/api/scans", headers=other)).json())["scans"] == []
    asyncio.run(run())


def test_scan_furniture_photo_design_and_estimate(fresh_db, ai):
    """Скан с мебелью и фото: точные материалы в чате, ремонт на картинке (iPhone и Mini App), смета."""
    import base64

    from bot import scan_ai
    object.__setattr__(config, "bot_token", TOKEN)
    bot = FakeBot()
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 100

    async def run():
        async with TestClient(TestServer(create_app(bot))) as c:
            h = {"X-Telegram-Init-Data": sign({"id": 21})}
            code = (await (await c.post("/api/scan-code", headers=h)).json())["code"]
            token = (await (await c.post("/scan/pair", json={"code": code})).json())["token"]
            auth = {"Authorization": f"Bearer {token}"}
            room = {"room": "Спальня",
                    "sizes": {"length": 4, "width": 3, "height": 2.7, "perimeter": 14, "floor_area": 12,
                              "wall_area": 34.1, "openings_area": 3.7, "skirting": 13.2, "slopes": 4.4},
                    "walls": [{"length": 4, "height": 2.7, "openings_area": 2.1}, {"length": 3, "height": 2.7}] * 2,
                    "openings": [{"kind": "window", "width": 1.4, "height": 1.5}, {"kind": "door", "width": 0.8, "height": 2}],
                    "plan": [[0, 0], [4, 0], [4, 3], [0, 3]],
                    "objects": [{"kind": "bed", "width": 1.6, "depth": 2.0, "height": 0.5, "x": 2, "y": 1.5, "angle": 0},
                                {"kind": "spaceship", "width": 1, "depth": 1, "height": 1, "x": "bad", "y": 1, "angle": 0}],
                    "photo": base64.b64encode(jpeg).decode()}
            r = await c.post("/scan/rooms", json=room, headers=auth)
            sid = (await r.json())["id"]
            text = bot.messages[-1][1]
            assert "Мебель: кровать 160×200×50 см, предмет" in text and "Материалы по скану" in text
            assert "Откосы окон: 4,4" in text and "Плинтус: 13,2 м" in text
            assert scan_ai.photo_path(sid).read_bytes() == jpeg

            # без фото — картинка по размерам (text-to-image)
            room2 = {k: v for k, v in room.items() if k != "photo"}
            sid2 = (await (await c.post("/scan/rooms", json=room2, headers=auth)).json())["id"]

            await db.add_credits(21, 10)
            r = await c.post("/scan/design", json={"id": sid, "style": "loft"}, headers=auth)
            data = await r.json()
            assert r.status == 200 and data["image"] == "https://files/result.png"
            assert ai[-1][0] == "edit" and "bed" in ai[-1][2] and "4 m × 3 m" in ai[-1][2]
            r = await c.post(f"/api/scans/{sid2}/design", json={"style": "scandi"}, headers=h)
            assert (await r.json())["image"] == "https://files/t2i.png" and ai[-1][0] == "t2i"
            assert (await c.post("/scan/design", json={"id": sid, "style": "nope"}, headers=auth)).status == 400

            # чужой скан не отдаём
            h2 = {"X-Telegram-Init-Data": sign({"id": 22})}
            assert (await c.post(f"/api/scans/{sid}/estimate", headers=h2)).status == 404

            r = await c.post(f"/api/scans/{sid}/estimate", headers=h)
            assert r.status == 200 and "кровать 160×200×50 см" in ai[-1][1] and "Ламинат" in ai[-1][1]

            scans = (await (await c.get("/api/scans", headers=h)).json())["scans"]
            assert scans[-1]["has_photo"] and scans[0]["has_photo"] is False
            assert any("Ламинат" in m for m in scans[0]["materials"]) and scans[0]["furniture"][0].startswith("кровать")

            # кредиты кончились → 402 и для iPhone
            await db.add_credits(21, -1000)
            r = await c.post("/scan/design", json={"id": sid, "style": "loft"}, headers=auth)
            assert r.status == 402 and (await r.json())["error"] == "credits"
    asyncio.run(run())


def test_portfolio_in_mini_app(fresh_db, ai):
    object.__setattr__(config, "bot_token", TOKEN)
    bot = FakeBot()
    bot.videos = []

    async def send_video(chat_id, video, **kw):
        bot.videos.append((chat_id, video.data[:12]))
    bot.send_video = send_video

    async def run():
        async with TestClient(TestServer(create_app(bot))) as c:
            h = {"X-Telegram-Init-Data": sign({"id": 31})}
            f = aiohttp.FormData()
            f.add_field("before", _png(), filename="b.png", content_type="image/png")
            f.add_field("after", _png(), filename="a.png", content_type="image/png")
            f.add_field("title", "Кухня за неделю")
            r = await c.post("/api/portfolio", data=f, headers=h)
            item = await r.json()
            assert r.status == 201 and item["ok"] and item["title"] == "Кухня за неделю"
            # картинки открываются только по подписанной ссылке
            img = await c.get(item["collage"])
            assert img.status == 200 and (await img.read())[:2] == b"\xff\xd8"
            assert (await c.get(item["before"].split("?")[0] + "?t=bad")).status == 403
            # чужую работу не трогаем
            h2 = {"X-Telegram-Init-Data": sign({"id": 32})}
            assert (await c.post(f"/api/portfolio/{item['id']}/post", headers=h2)).status == 404

            await c.post("/api/portfolio/brand", json={"brand": "Бригада Артура"}, headers=h)
            r = await c.post(f"/api/portfolio/{item['id']}/post", headers=h)
            data = await r.json()
            assert r.status == 200 and data["credits"] == config.welcome_credits - 1 and "Бригада Артура" in ai[-1][1]
            assert (await c.post(f"/api/portfolio/{item['id']}/reel", headers=h)).status == 200
            assert bot.videos[0][0] == 31 and b"ftyp" in bot.videos[0][1]
            assert (await c.post(f"/api/portfolio/{item['id']}/send", json={"text": "Пост"}, headers=h)).status == 200
            lst = await (await c.get("/api/portfolio", headers=h)).json()
            assert lst["brand"] == "Бригада Артура" and len(lst["items"]) == 1
            assert (await c.delete(f"/api/portfolio/{item['id']}", headers=h)).status == 200
            assert (await (await c.get("/api/portfolio", headers=h)).json())["items"] == []
    asyncio.run(run())
