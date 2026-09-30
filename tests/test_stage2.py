import asyncio
import hashlib
import hmac
import json
import time
from datetime import date
from urllib.parse import urlencode

import pytest
from aiohttp.test_utils import TestClient, TestServer

from bot import db, kie, objects
from bot.config import config
from bot.handlers.common import credits_word, parse_ref
from bot.report import build_pdf
from bot.storage import SQLiteStorage
from bot.web import create_app, validate_init_data

TOKEN = "123456:TEST"


@pytest.fixture
def fresh_db(tmp_path):
    object.__setattr__(config, "db_path", str(tmp_path / "t.db"))  # config — frozen dataclass
    asyncio.run(db.init_db())
    return config.db_path


# ---------- разбор ввода ----------

def test_parse_expense():
    assert objects.parse_expense("плитка 30x60 12 500 р") == ("material", 12500, "плитка 30x60")
    assert objects.parse_expense("аванс бригаде 50к") == ("payment", 50000, "аванс бригаде")
    assert objects.parse_expense("клей 12 кг 4500") == ("material", 4500, "клей 12 кг")
    assert objects.parse_expense("вывоз мусора 3 000", kind="other") == ("other", 3000, "вывоз мусора")
    assert objects.parse_expense("просто текст") is None
    assert objects.parse_amount("1.2 млн") == 1_200_000
    assert objects.parse_amount("850 000") == 850_000


def test_parse_stage_and_date():
    today = date(2026, 9, 30)
    assert objects.parse_stage("Плитка в ванной до 15.10", today) == ("Плитка в ванной", "2026-10-15")
    assert objects.parse_stage("Демонтаж до 05.09", today) == ("Демонтаж", "2027-09-05")  # прошло → след. год
    assert objects.parse_stage("Электрика 12.10.26", today) == ("Электрика", "2026-10-12")
    assert objects.parse_stage("Покраска", today) == ("Покраска", None)
    assert objects.parse_date("31.02", today) is None


def test_summary_text():
    obj = {"name": "Кв <Ивановых>", "address": "", "budget": 100_000}
    stages = [{"name": "Демонтаж", "due": "2026-09-01", "done": 0},
              {"name": "Плитка", "due": None, "done": 1}]
    text = objects.summary(obj, {"material": 80_000, "payment": 30_000}, stages, date(2026, 9, 30))
    assert "Кв &lt;Ивановых&gt;" in text
    assert "Всего потрачено: 110 000 ₽" in text
    assert "перерасход 10 000 ₽" in text
    assert "🔴 Демонтаж" in text and "✅ Плитка" in text


def test_plural_and_ref():
    assert credits_word(1) == "1 кредит"
    assert credits_word(3) == "3 кредита"
    assert credits_word(11) == "11 кредитов"
    assert credits_word(22) == "22 кредита"
    assert parse_ref("ref_42") == 42
    assert parse_ref("ref_x") is None and parse_ref(None) is None


def test_find_text_stt_formats():
    assert kie.find_text({"resultObject": {"text": "привет"}}) == "привет"
    assert kie.find_text({"resultJson": json.dumps({"text": "смета"})}) == "смета"
    assert kie.find_text({"words": [{"text": ""}], "data": [{"text": "ок"}]}) == "ок"
    assert kie.find_text({}) == ""


# ---------- база ----------

def test_referral_and_refunds(fresh_db):
    async def run():
        await db.get_or_create_user(1, "a")
        u2 = await db.get_or_create_user(2, "b", referrer_id=1)
        assert u2["referrer_id"] == 1
        u3 = await db.get_or_create_user(3, "c", referrer_id=3)      # сам себя — нельзя
        assert u3["referrer_id"] is None
        u4 = await db.get_or_create_user(4, "d", referrer_id=999)    # несуществующий
        assert u4["referrer_id"] is None
        assert await db.reward_referrer(2, 3) == 1
        assert await db.reward_referrer(2, 3) is None                # только один раз
        assert (await db.get_user(1))["credits"] == config.welcome_credits + 3
        assert await db.referral_stats(1) == (1, 1)

        # бесплатный вопрос возвращается
        assert await db.use_free_consult(2, 1)
        assert not await db.use_free_consult(2, 1)
        await db.refund_free_consult(2)
        assert await db.use_free_consult(2, 1)

        # возврат звёзд списывает кредиты, но не ниже нуля и только один раз
        assert await db.record_payment(2, 100, 10, "ch1")
        await db.add_credits(2, -12)
        assert (await db.get_user(2))["credits"] == config.welcome_credits + 10 - 12
        p = await db.mark_refunded("ch1")
        assert p and p["stars"] == 100
        assert (await db.get_user(2))["credits"] == 0
        assert await db.mark_refunded("ch1") is None
        assert (await db.stats())["stars"] == 0
    asyncio.run(run())


def test_objects_crud_and_ownership(fresh_db):
    async def run():
        oid = await db.create_object(1, "Дача", "СНТ Ромашка", 500_000)
        assert await db.get_object(oid, 2) is None                   # чужой не видит
        await db.add_expense(oid, "material", 12_500, "плитка")
        eid = await db.add_expense(oid, "payment", 30_000, "аванс")
        await db.add_expense(oid, "weird", 100, "")                  # неизвестный тип → other
        assert await db.expense_totals(oid) == {"material": 12_500, "payment": 30_000, "other": 100}
        assert not await db.delete_expense(eid, 2)
        assert await db.delete_expense(eid, 1)
        s1 = await db.add_stage(oid, "Демонтаж", "2026-09-29")
        await db.add_stage(oid, "Плитка", "2026-10-20")
        due = await db.due_stages("2026-09-30")
        assert [s["id"] for s in due] == [s1] and due[0]["owner_id"] == 1
        await db.mark_reminded(s1)
        assert await db.due_stages("2026-09-30") == []
        assert not await db.set_stage_done(s1, 2)
        assert await db.set_stage_done(s1, 1)
        assert await db.update_object(oid, 1, archived=1)
        assert await db.list_objects(1) == [] and len(await db.list_objects(1, archived=True)) == 1
        assert not await db.delete_object(oid, 2)
        assert await db.delete_object(oid, 1)
        assert await db.list_expenses(oid) == [] and await db.list_stages(oid) == []
    asyncio.run(run())


def test_migration_from_old_schema(tmp_path):
    """Старая база первой версии получает новые колонки без потери данных."""
    import sqlite3
    path = str(tmp_path / "old.db")
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, role TEXT,
            credits INTEGER NOT NULL DEFAULT 0, consult_day TEXT,
            consult_used INTEGER NOT NULL DEFAULT 0, created_at TEXT);
        CREATE TABLE payments (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
            stars INTEGER NOT NULL, credits INTEGER NOT NULL, charge_id TEXT UNIQUE, created_at TEXT);
        INSERT INTO users (id, credits) VALUES (7, 42);
    """)
    con.close()
    object.__setattr__(config, "db_path", path)

    async def run():
        await db.init_db()
        await db.init_db()  # повторно — без ошибок
        u = await db.get_user(7)
        assert u["credits"] == 42 and u["ref_rewarded"] == 0
    asyncio.run(run())


def test_sqlite_fsm_storage(fresh_db):
    from aiogram.fsm.storage.base import StorageKey
    from bot.states import Flow

    async def run():
        st = SQLiteStorage()
        key = StorageKey(bot_id=1, chat_id=5, user_id=5)
        assert await st.get_state(key) is None and await st.get_data(key) == {}
        await st.set_state(key, Flow.consult)
        await st.set_data(key, {"photo_url": "u", "n": 1})
        # «перезапуск»: новый объект хранилища видит то же самое
        st2 = SQLiteStorage()
        assert await st2.get_state(key) == Flow.consult.state
        assert await st2.get_data(key) == {"photo_url": "u", "n": 1}
        await st2.set_state(key, None)
        assert await st2.get_state(key) is None
        assert await st2.get_data(key) == {"photo_url": "u", "n": 1}
    asyncio.run(run())


# ---------- PDF ----------

def _png() -> bytes:
    # минимальная картинка 2×1 без внешних библиотек
    import struct
    import zlib

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"\x00\xff\x00\x00\x00\x00\xff"
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def test_pdf_report_cyrillic():
    pdf = build_pdf("Фотоотчёт: Дача", [(_png(), "Демонтаж <плитки> завершён"), (_png(), "")],
                    summary="Работы идут по графику.", author="Иван")
    assert pdf.startswith(b"%PDF") and len(pdf) > 1000
    assert b"DejaVu" in pdf


# ---------- Mini App ----------

def sign(user: dict, token: str = TOKEN, auth_date: int | None = None) -> str:
    fields = {"auth_date": str(auth_date or int(time.time())), "query_id": "q1",
              "user": json.dumps(user, separators=(",", ":"), ensure_ascii=False)}
    check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
    fields["hash"] = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    return urlencode(fields)


def test_validate_init_data():
    good = sign({"id": 5, "first_name": "Артём"})
    assert validate_init_data(good, TOKEN)["id"] == 5
    assert validate_init_data(good, "other:token") is None
    assert validate_init_data(good.replace("q1", "q2"), TOKEN) is None
    assert validate_init_data(sign({"id": 5}, auth_date=int(time.time()) - 90_000), TOKEN) is None
    assert validate_init_data("", TOKEN) is None
    assert validate_init_data("garbage", TOKEN) is None


def test_webapp_api(fresh_db):
    object.__setattr__(config, "bot_token", TOKEN)

    async def run():
        async with TestClient(TestServer(create_app())) as c:
            h1 = {"X-Telegram-Init-Data": sign({"id": 1, "username": "a"})}
            h2 = {"X-Telegram-Init-Data": sign({"id": 2})}
            assert (await c.get("/api/me")).status == 401
            assert (await c.get("/app/")).status == 200

            r = await c.post("/api/objects", json={"name": "Кухня", "budget": 100000}, headers=h1)
            assert r.status == 201
            oid = (await r.json())["id"]
            assert (await c.get(f"/api/objects/{oid}", headers=h2)).status == 404   # чужой объект
            assert (await c.post(f"/api/objects/{oid}/expenses", json={"kind": "material", "amount": 1},
                                 headers=h2)).status == 404
            r = await c.post(f"/api/objects/{oid}/expenses",
                             json={"kind": "material", "amount": 12500.4, "note": "плитка"}, headers=h1)
            assert r.status == 201
            assert (await c.post(f"/api/objects/{oid}/expenses", json={"amount": -5}, headers=h1)).status == 400
            r = await c.post(f"/api/objects/{oid}/stages", json={"name": "Плитка", "due": "2026-10-15"},
                             headers=h1)
            sid = (await r.json())["id"]
            assert (await c.patch(f"/api/stages/{sid}", json={"done": True}, headers=h2)).status == 404
            assert (await c.patch(f"/api/stages/{sid}", json={"done": True}, headers=h1)).status == 200

            data = await (await c.get(f"/api/objects/{oid}", headers=h1)).json()
            assert data["totals"] == {"material": 12500}
            assert data["stages"][0]["done"] == 1
            me = await (await c.get("/api/me", headers=h1)).json()
            assert me["objects"][0]["spent"] == 12500 and me["objects"][0]["stages_done"] == 1
            assert "tile" in me["calcs"]

            r = await c.post("/api/calc", json={"key": "tile", "numbers": [12, 30, 60]}, headers=h1)
            assert "74 шт" in (await r.json())["lines"][0]
            assert (await c.post("/api/calc", json={"key": "tile", "numbers": [1]}, headers=h1)).status == 400
            assert (await c.post("/api/objects", data="not json", headers=h1)).status == 400

            assert (await c.patch(f"/api/objects/{oid}", json={"archived": True}, headers=h1)).status == 200
            assert (await (await c.get("/api/me", headers=h1)).json())["objects"] == []
            assert (await c.delete(f"/api/objects/{oid}", headers=h2)).status == 404
            assert (await c.delete(f"/api/objects/{oid}", headers=h1)).status == 200
    asyncio.run(run())
