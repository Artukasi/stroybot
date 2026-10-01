"""Сквозные проверки сценариев бота без Telegram и без kie.ai: запросы к Telegram перехватываются."""
import asyncio
import datetime as dt
import itertools

import pytest
from aiogram import Bot, Dispatcher
from aiogram.client.session.base import BaseSession
from aiogram.methods import TelegramMethod
from aiogram.types import (CallbackQuery, Chat, File, Message, PhotoSize, SuccessfulPayment, Update,
                           User, Voice)

from bot import db, kie
from bot.config import config
from bot.handlers import setup
from bot.storage import SQLiteStorage

from .test_stage2 import _png

USER = User(id=100, is_bot=False, first_name="Артём", username="artem")
CHAT = Chat(id=100, type="private")
ids = itertools.count(1)
ROOT = setup()  # роутеры модульные — собираем один раз и переподключаем к новым диспетчерам


class FakeSession(BaseSession):
    """Отвечает на запросы как Telegram и запоминает их."""

    def __init__(self):
        super().__init__()
        self.calls: list[TelegramMethod] = []

    async def close(self):
        pass

    async def make_request(self, bot, method, timeout=None):
        self.calls.append(method)
        ret = method.__returning__
        if ret is Message or getattr(ret, "__args__", None) and Message in ret.__args__:
            return Message(message_id=next(ids), date=dt.datetime.now(), chat=CHAT,
                           text=getattr(method, "text", None)).as_(bot)
        if ret is User:
            return User(id=1, is_bot=True, first_name="Bot", username="stroybot_test")
        if ret is File:
            return File(file_id=method.file_id, file_unique_id="u", file_path="photos/x.jpg")
        return True

    async def stream_content(self, url, headers=None, timeout=30, chunk_size=65536, raise_for_status=True):
        yield _png()

    def texts(self) -> list[str]:
        return [getattr(c, "text", None) or getattr(c, "caption", None) or "" for c in self.calls]


@pytest.fixture
def env(tmp_path, monkeypatch):
    object.__setattr__(config, "db_path", str(tmp_path / "t.db"))
    object.__setattr__(config, "admin_ids", frozenset({100}))
    asyncio.run(db.init_db())

    async def fake_chat(system, text, image_url=None, max_tokens=2000):
        if "FAIL" in text:
            raise kie.KieError("boom")
        return "<b>Ответ</b> ок"

    async def fake_upload(data, filename="x"):
        return "https://files/x.jpg"

    async def fake_edit(url, prompt, aspect_ratio="auto"):
        return ["https://files/result.png"]

    async def fake_transcribe(audio, filename="v.ogg", mime="audio/ogg"):
        return "плитка 12 500"

    monkeypatch.setattr(kie, "chat", fake_chat)
    monkeypatch.setattr(kie, "upload_image", fake_upload)
    monkeypatch.setattr(kie, "edit_image", fake_edit)
    monkeypatch.setattr(kie, "transcribe", fake_transcribe)
    session = FakeSession()
    bot = Bot("42:TEST", session=session)
    dp = Dispatcher(storage=SQLiteStorage())
    ROOT._parent_router = None
    dp.include_router(ROOT)
    return bot, dp, session


def msg(text=None, **kw) -> Update:
    return Update(update_id=next(ids), message=Message(
        message_id=next(ids), date=dt.datetime.now(), chat=CHAT, from_user=USER, text=text, **kw))


def cb(data: str) -> Update:
    m = Message(message_id=next(ids), date=dt.datetime.now(), chat=CHAT, text="menu")
    return Update(update_id=next(ids), callback_query=CallbackQuery(
        id=str(next(ids)), from_user=USER, chat_instance="c", data=data, message=m))


def photo(caption=None) -> Update:
    return msg(photo=[PhotoSize(file_id="p1", file_unique_id="p1", width=10, height=10)], caption=caption)


def voice() -> Update:
    return msg(voice=Voice(file_id="v1", file_unique_id="v1", duration=5))


def run(env, *updates):
    bot, dp, session = env

    async def go():
        for u in updates:
            await dp.feed_update(bot, u)
    asyncio.run(go())
    return session


def test_start_referral_and_menu(env):
    asyncio.run(db.get_or_create_user(555, "friend"))
    s = run(env, msg("/start ref_555"), cb("role:foreman"), cb("menu:invite"))
    assert (asyncio.run(db.get_user(100)))["referrer_id"] == 555
    assert any("start=ref_100" in t for t in s.texts())


def test_consult_free_refund_on_failure(env):
    run(env, msg("/start"), cb("menu:consult"), msg("FAIL please"))
    u = asyncio.run(db.get_user(100))
    assert u["consult_used"] == 0 and u["credits"] == config.welcome_credits


def test_estimate_charges_and_rewards_referrer(env):
    asyncio.run(db.get_or_create_user(555, "friend"))
    s = run(env, msg("/start ref_555"), cb("menu:estimate"), msg("Ванная 4 м2"))
    assert (asyncio.run(db.get_user(100)))["credits"] == config.welcome_credits - 1
    assert (asyncio.run(db.get_user(555)))["credits"] == config.welcome_credits + 3
    assert any("Ответ" in t for t in s.texts())


def test_design_flow_and_stale_style_button(env):
    s = run(env, msg("/start"), cb("style:loft"))           # старая кнопка без фото
    assert any("фото комнаты заново" in t for t in s.texts())
    run(env, photo(), cb("style:loft"))
    assert (asyncio.run(db.get_user(100)))["credits"] == config.welcome_credits - 2


def test_voice_in_estimate_and_free_text(env):
    s = run(env, msg("/start"), cb("menu:estimate"), voice())
    assert any("плитка 12 500" in t for t in s.texts())
    s = run(env, cb("menu:home"), msg("как выровнять стену?"), cb("use:consult"))
    assert any("Ответ" in t for t in s.texts())


def test_objects_flow(env):
    run(env, msg("/start"), cb("obj:new"), msg("Квартира Ивановых, ул. Ленина 5"))
    (obj,) = asyncio.run(db.list_objects(100))
    oid = obj["id"]
    assert obj["address"] == "ул. Ленина 5"
    run(env, cb(f"obj:exp:{oid}:material"), msg("плитка 12 500\nклей 3 000"),
        cb(f"obj:exp:{oid}:payment"), voice(),
        cb(f"obj:stage:{oid}"), msg("Демонтаж до 05.10\nПлитка"),
        cb(f"obj:budget:{oid}"), msg("850 000"))
    assert asyncio.run(db.expense_totals(oid)) == {"material": 15500, "payment": 12500}
    stages = asyncio.run(db.list_stages(oid))
    assert len(stages) == 2
    assert asyncio.run(db.get_object(oid, 100))["budget"] == 850000
    s = run(env, cb(f"obj:tgl:{oid}:{stages[0]['id']}"), cb(f"obj:hist:{oid}"),
            cb(f"obj:open:{oid}"), cb(f"obj:advice:{oid}"), msg("/objects"))
    assert any("Всего потрачено: 28 000 ₽" in t for t in s.texts())
    run(env, cb(f"obj:del!:{oid}"))
    assert asyncio.run(db.list_objects(100)) == []


def test_command_inside_state_is_not_eaten(env):
    s = run(env, msg("/start"), cb("menu:consult"), msg("/objects"))
    assert any("Мои объекты" in t for t in s.texts())
    assert (asyncio.run(db.get_user(100)))["consult_used"] == 0


def test_report_pdf(env):
    s = run(env, msg("/start"), cb("role:foreman"), cb("rep:start"),
            photo("Демонтаж"), photo(), voice(), cb("rep:build"))
    docs = [c for c in s.calls if type(c).__name__ == "SendDocument"]
    assert docs and docs[0].document.filename == "otchet.pdf"
    assert (asyncio.run(db.get_user(100)))["credits"] == config.welcome_credits - 1


def test_payment_paysupport_and_refund(env):
    sp = SuccessfulPayment(currency="XTR", total_amount=100, invoice_payload="pack:s",
                           telegram_payment_charge_id="ch-1", provider_payment_charge_id="")
    s = run(env, msg("/start"), msg(successful_payment=sp), msg(successful_payment=sp),
            msg("/paysupport"), msg("/paysupport не пришли кредиты"), msg("/refund ch-1"))
    assert (asyncio.run(db.get_user(100)))["credits"] == config.welcome_credits  # +10, потом −10
    assert any("ch-1" in t for t in s.texts())
    assert any(type(c).__name__ == "RefundStarPayment" for c in s.calls)


def test_unknown_command_and_photo_without_mode(env):
    s = run(env, msg("/start"), msg("/whatever"), photo())
    assert any("Не знаю такой команды" in t for t in s.texts())
    assert any("Что сделать с фото" in t for t in s.texts())


def test_every_button_has_a_handler(env):
    """Каждая кнопка бота кем-то обрабатывается: нет «вечных часиков» на нажатии."""
    from aiogram.dispatcher.event.bases import UNHANDLED

    from bot import keyboards as kb
    from bot.handlers import folio
    from bot.handlers.scans import scan_styles_kb
    from bot.web_scan import scan_kb
    bot, dp, session = env
    run(env, msg("/start"), cb("role:foreman"), cb("obj:new"), msg("Дача"))
    (obj,) = asyncio.run(db.list_objects(100))
    oid = obj["id"]
    run(env, cb(f"obj:stage:{oid}"), msg("Демонтаж"), cb(f"obj:exp:{oid}:material"), msg("плитка 500"))
    stage = asyncio.run(db.list_stages(oid))[0]
    exp = asyncio.run(db.list_expenses(oid))[0]
    boards = [kb.roles_kb(), kb.main_menu("foreman"), kb.main_menu("private"), kb.styles_kb(), kb.calcs_kb(),
              kb.packs_kb(), kb.home_kb(), kb.after_design_kb(), kb.use_text_kb(), kb.objects_kb([obj]),
              kb.object_kb(obj), kb.stages_kb(oid, [stage]), kb.expenses_kb(oid, [exp]),
              kb.back_to_list_kb(), kb.back_to_object_kb(oid), kb.report_kb(1), kb.report_objects_kb([obj]),
              kb.confirm_delete_kb(oid), scan_kb(1), scan_styles_kb(1),
              kb.design_kb([{"id": 1, "room": "Кухня", "created_at": "2026-09-30 10:00:00"}]),
              folio.list_kb([{"id": 1, "title": "x"}]), folio.item_kb(1), folio.skip_kb()]
    datas = []
    for board in boards:
        for row in board.inline_keyboard:
            datas += [b.callback_data for b in row if b.callback_data]
    assert len(datas) > 30
    unhandled = []

    async def go():
        for d in dict.fromkeys(datas):
            if "del!" in d:
                continue      # удаление проверяем отдельно, иначе объект пропадёт раньше времени
            if await dp.feed_update(bot, cb(d)) is UNHANDLED:
                unhandled.append(d)
    asyncio.run(go())
    assert unhandled == []


def test_all_commands_answer(env):
    cmds = ["/start", "/menu", "/objects", "/report", "/scanner", "/paysupport", "/terms", "/help", "/stats"]
    bot, dp, session = env
    for c in cmds:
        before = len(session.calls)
        run(env, msg(c))
        assert len(session.calls) > before, f"{c} ничего не ответил"
    assert any("СтройСкан" in t and "<code>" in t for t in session.texts())
    assert any("/scanner" in t for t in session.texts())


def test_mini_app_with_real_bot_object(env, monkeypatch):
    """Mini App вызывает настоящие методы aiogram (счёт, документ, фото, сообщение)."""
    import aiohttp
    from aiohttp.test_utils import TestClient, TestServer

    from bot.web import create_app
    from .test_stage2 import TOKEN, sign
    bot, dp, session = env
    object.__setattr__(config, "bot_token", TOKEN)
    orig = session.make_request

    async def make_request(b, method, timeout=None):
        if type(method).__name__ == "CreateInvoiceLink":
            session.calls.append(method)
            return "https://t.me/$abc"
        return await orig(b, method, timeout)
    monkeypatch.setattr(session, "make_request", make_request)

    async def go():
        async with TestClient(TestServer(create_app(bot))) as c:
            h = {"X-Telegram-Init-Data": sign({"id": 100, "first_name": "Артём"})}
            prof = await (await c.get("/api/profile", headers=h)).json()
            assert prof["invite"]["link"] == "https://t.me/stroybot_test?start=ref_100"
            assert (await (await c.post("/api/invoice", json={"pack": "m"}, headers=h)).json())["link"] == "https://t.me/$abc"
            assert (await c.post("/api/send", json={"text": "<b>Смета</b>"}, headers=h)).status == 200
            assert (await c.post("/api/send", json={"photo": "https://files/x.png", "text": "Лофт"}, headers=h)).status == 200
            f = aiohttp.FormData()
            f.add_field("photos", _png(), filename="p.png", content_type="image/png")
            f.add_field("captions", "Стяжка")
            assert (await c.post("/api/report", data=f, headers=h)).status == 200
    asyncio.run(go())
    names = [type(m).__name__ for m in session.calls]
    for n in ("CreateInvoiceLink", "SendMessage", "SendPhoto", "SendDocument"):
        assert n in names
    inv = next(m for m in session.calls if type(m).__name__ == "CreateInvoiceLink")
    assert inv.currency == "XTR" and inv.prices[0].amount == 250


def test_admin_gives_credits_to_self(env):
    run(env, msg("/start"))
    before = asyncio.run(db.get_user(100))["credits"]
    run(env, msg("/give 1000"))
    assert asyncio.run(db.get_user(100))["credits"] == before + 1000


def test_portfolio_before_after_post_and_reel(env):
    """Портфолио: фото до и после → подпись → картинка, пост за кредит, видео для Reels, удаление."""
    from aiogram.types import PhotoSize

    from bot import portfolio
    bot, dp, session = env
    ph = lambda fid: [PhotoSize(file_id=fid, file_unique_id=fid, width=2, height=1)]  # noqa: E731
    run(env, msg("/start"), cb("role:foreman"), msg("/portfolio"), cb("pf:new"),
        msg(photo=ph("b1")), msg(photo=ph("a1")), msg("Ванная под ключ за 12 дней"))
    (item,) = asyncio.run(db.list_portfolio(100))
    assert item["title"] == "Ванная под ключ за 12 дней" and portfolio.has_photos(item["id"])
    names = [type(c).__name__ for c in session.calls]
    assert "SendPhoto" in names

    credits = asyncio.run(db.get_user(100))["credits"]
    run(env, cb(f"pf:post:{item['id']}"))
    assert asyncio.run(db.get_user(100))["credits"] == credits - 1
    assert any("Ответ" in t for t in session.texts())

    run(env, cb(f"pf:reel:{item['id']}"))
    video = [c for c in session.calls if type(c).__name__ == "SendVideo"]
    assert video and video[0].width == 720 and video[0].height == 1280

    run(env, cb("pf:brand"), msg("Бригада Артура"))
    assert asyncio.run(db.get_user(100))["brand"] == "Бригада Артура"
    run(env, cb(f"pf:del:{item['id']}"))
    assert asyncio.run(db.list_portfolio(100)) == [] and not portfolio.has_photos(item["id"])
