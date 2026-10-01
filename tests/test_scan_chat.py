"""Скан в чате с ботом: файл .stroyscan.json, мебель по размерам, сканы в «Дизайне по фото»,
своё фото для ремонта по скану, ремонт из 3D в картинке и смете."""
import asyncio
import base64
import json

from aiogram.types import Document

from bot import db, furniture, kie, scan_ai
from bot.config import PRICES, config
from bot.handlers.scans import furniture_groups, furniture_text
from bot.look import clean_look
from bot.web_scan import clean_scan

from .test_bot_flows import cb, env, msg, photo, run  # noqa: F401  (env — фикстура)
from .test_scan3d import JPEG, LOOK, ROOM_V2, v2


def _markups(session) -> list:
    return [c.reply_markup for c in session.calls if getattr(c, "reply_markup", None)]


def _buttons(session) -> list:
    return [b for m in _markups(session) for row in m.inline_keyboard for b in row]


def _file(session, payload: bytes, name: str = "Спальня.stroyscan.json", size: int | None = None):
    async def stream(url, headers=None, timeout=30, chunk_size=65536, raise_for_status=True):
        yield payload
    session.stream_content = stream
    return msg(document=Document(file_id="d1", file_unique_id="d1", file_name=name, mime_type="application/json",
                                 file_size=len(payload) if size is None else size))


def _scan(user_id: int = 100, data: dict | None = None) -> int:
    scan = clean_scan(data or v2())
    return asyncio.run(db.add_scan(user_id, scan["room"], {k: v for k, v in scan.items() if k != "room"}))


def test_scan_file_in_chat(env):
    bot, dp, session = env
    good = json.dumps({**v2(), "photo": base64.b64encode(JPEG).decode()}, ensure_ascii=False).encode()
    run(env, msg("/start"), _file(session, good))
    (scan,) = asyncio.run(db.list_scans(100))
    assert scan["room"] == "Спальня" and scan["has_photo"] and scan["wall_lines"]
    assert scan_ai.photo_path(scan["id"]).read_bytes() == JPEG
    texts = session.texts()
    assert any("Скан с iPhone: Спальня" in t and "Нужно доснять" in t for t in texts)
    assert f"sf:{scan['id']}" in [b.callback_data for b in _buttons(session)]

    # любой .json с format=stroyscan тоже подходит; UTF-8 с BOM — тоже
    run(env, _file(session, b"\xef\xbb\xbf" + json.dumps(v2(room="Кухня")).encode(), name="scan.json"))
    assert asyncio.run(db.list_scans(100))[0]["room"] == "Кухня"

    # плохие файлы — понятный ответ, ничего не сохраняем
    for payload, name, size, answer in (
            (b"{broken", "Спальня.stroyscan.json", None, "Это не файл скана"),
            (json.dumps({"hello": 1}).encode(), "data.json", None, "Это не файл скана"),
            (json.dumps({"format": "stroyscan", "room": "x", "sizes": {}}).encode(), "x.json", None,
             "нет размеров комнаты"),
            (b"{}", "big.stroyscan.json", 11 * 1024 * 1024, "больше 10 МБ")):
        before = len(session.calls)
        run(env, _file(session, payload, name, size))
        assert any(answer in t for t in session.texts()[before:]), answer
    assert len(asyncio.run(db.list_scans(100))) == 2


def test_scan_furniture_button(env):
    bot, dp, session = env
    sid = _scan()
    run(env, msg("/start"), cb(f"sf:{sid}"))
    assert any("Мебель по размерам: Спальня" in t and "встанет до 309×90 см" in t for t in session.texts())
    urls = [b.url for b in _buttons(session) if b.url]
    assert any(u.startswith("https://market.yandex.ru/search?text=%D0%B4%D0%B8%D0%B2%D0%B0%D0%BD") for u in urls)
    assert any(b.text == "1 · Маркет" for b in _buttons(session))
    # чужой скан не показываем
    other = _scan(user_id=555)
    before = len(session.calls)
    run(env, cb(f"sf:{other}"))
    assert any(getattr(c, "text", "") == "Скан не найден" for c in session.calls[before:])


def test_design_flow_offers_scans_and_takes_file(env):
    bot, dp, session = env
    sid = _scan()
    run(env, msg("/start"), cb("menu:design"))
    assert any(".stroyscan.json" in t and "скан с iPhone" in t for t in session.texts())
    assert any(b.callback_data == f"sd:{sid}" and b.text.startswith("📐 Спальня") for b in _buttons(session))

    # файл скана прямо в «Дизайне по фото» → сразу выбор стиля по этому скану
    before = len(session.calls)
    run(env, _file(session, json.dumps(v2(room="Гостиная")).encode()))
    new = asyncio.run(db.list_scans(100))[0]
    assert new["room"] == "Гостиная"
    assert any("Выберите стиль" in t for t in session.texts()[before:])
    assert any(b.callback_data == f"sds:{new['id']}:loft" for b in _buttons(session))


def test_scan_design_with_own_photo_and_look(env, monkeypatch):
    bot, dp, session = env
    sid = _scan()
    asyncio.run(db.set_scan_look(100, sid, clean_look(LOOK, asyncio.run(db.get_scan(100, sid)))))
    prompts = []

    async def edit(url, prompt, aspect_ratio="auto"):
        prompts.append((url, prompt))
        return ["https://files/result.png"]
    monkeypatch.setattr(kie, "edit_image", edit)
    run(env, msg("/start"), cb(f"sd:{sid}"))
    assert any("Учту ваш ремонт из 3D" in t and "своё фото" in t for t in session.texts())
    run(env, photo(), cb(f"sds:{sid}:loft"))
    url, prompt = prompts[-1]
    assert url == "https://files/x.jpg"          # фото из чата, а не рисунок по размерам
    assert "4 m × 3 m" in prompt and "roman blinds" in prompt and "industrial loft" in prompt
    assert asyncio.run(db.get_user(100))["credits"] == config.welcome_credits - PRICES["design"]
    assert any("на вашем фото" in t for t in session.texts())


def test_scan_estimate_uses_look(env, monkeypatch):
    bot, dp, session = env
    sid = _scan()
    asyncio.run(db.set_scan_look(100, sid, {"curtains": "roman", "floor": {"finish": "parquet"}}))
    asked = []

    async def chat(system, text, image_url=None, max_tokens=2000):
        asked.append(text)
        return "<b>Смета</b>"
    monkeypatch.setattr(kie, "chat", chat)
    run(env, msg("/start"), cb(f"se:{sid}"))
    assert "Клиент собрал ремонт в 3D" in asked[-1]
    assert "Окна: римские шторы" in asked[-1] and "Пол: паркет" in asked[-1]


def test_same_furniture_is_grouped():
    """Стулья вокруг стола — одной строкой «×2», а не списком одинаковых."""
    chair = {"kind": "chair", "width": 0.45, "depth": 0.5, "height": 0.9, "y": 1.6, "angle": 0}
    scan = {"id": 1, **clean_scan(v2(objects=ROOM_V2["objects"] + [{**chair, "x": x} for x in (1.2, 2.8)])),
            "look": None}
    groups = furniture_groups(furniture.pick(scan))
    chairs = [(it, n) for it, n in groups if it["kind"] == "chair"]
    assert len(chairs) == 1 and chairs[0][1] == 2
    assert "<b>Стул</b> ×2" in furniture_text(scan, groups)
