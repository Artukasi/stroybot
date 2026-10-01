"""Ремонт по 3D-скану: скан v2 (концы стен, окна на стенах, оценка качества), ремонт из 3D (look),
мебель по размерам со ссылками на магазины, фото «как в жизни» по снимку 3D и файл скана в чате."""
import asyncio
import base64
import copy
import json
import math
import random
import time

import pytest
from aiohttp.test_utils import TestClient, TestServer

from bot import db, furniture, kie, scan_ai
from bot.config import PRICES, config
from bot.look import clean_look, look_en, look_ru
from bot.prompts import SCAN_RENDER_PROMPT
from bot.room import Room
from bot.web import create_app
from bot.web_scan import clean_scan, scan_kb, scan_text, scan_view

from .test_stage2 import TOKEN, fresh_db, sign  # noqa: F401  (fresh_db — фикстура)
from .test_webapp_tools import FakeBot, ai  # noqa: F401  (ai — фикстура)

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 100
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 50

# комната 4×3: окно на верхней стене, дверь на левой, диван у нижней, стол посередине, телевизор на правой
ROOM_V2 = {
    "format": "stroyscan", "version": 2, "room": "Спальня",
    "sizes": {"length": 4, "width": 3, "height": 2.7, "perimeter": 14, "floor_area": 12, "wall_area": 34.1,
              "openings_area": 3.7, "skirting": 13.2, "slopes": 4.4},
    "walls": [{"length": 4, "height": 2.7}, {"length": 3, "height": 2.7},
              {"length": 4, "height": 2.7, "openings_area": 2.1}, {"length": 3, "height": 2.7, "openings_area": 1.6}],
    "wall_lines": [[0, 0, 4, 0], [4, 0, 4, 3], [4, 3, 0, 3], [0, 3, 0, 0]],
    "openings": [{"kind": "window", "width": 1.4, "height": 1.5, "wall": 2, "offset": 2.0, "bottom": 0.9},
                 {"kind": "door", "width": 0.8, "height": 2.0, "wall": 3, "offset": 2.4, "bottom": 0}],
    "plan": [[0, 0], [4, 0], [4, 3], [0, 3]],
    "objects": [{"kind": "sofa", "width": 2.0, "depth": 0.9, "height": 0.85, "x": 2.0, "y": 0.45, "angle": 0},
                {"kind": "table", "width": 1.0, "depth": 0.6, "height": 0.45, "x": 2.0, "y": 1.6, "angle": 0},
                {"kind": "television", "width": 1.22, "depth": 0.1, "height": 0.7, "x": 3.95, "y": 1.5,
                 "angle": 1.5708}],
    "quality": {"score": 82, "issues": ["Доснимите угол за шкафом <справа>"]},
}
ROOM_V1 = {"room": "Кухня", "sizes": {"length": 3.4, "width": 2.9, "height": 2.7, "perimeter": 12.6,
                                      "floor_area": 9.86, "wall_area": 30.1, "openings_area": 3.9},
           "walls": [{"length": 3.4, "height": 2.7}] * 4,
           "openings": [{"kind": "window", "width": 1.4, "height": 1.5}, {"kind": "door", "width": 0.8, "height": 2}],
           "objects": [{"kind": "refrigerator", "width": 0.6, "depth": 0.65, "height": 1.9, "x": 0.3, "y": 0.325,
                        "angle": 0}]}
LOOK = {"style": "loft", "junk": 1,
        "wall": {"finish": "wallpaper", "color": "#D9CBB5", "pattern": "linen", "x": 1},
        "accent": {"wall": 2, "finish": "paint", "color": "#2f4f3a"},
        "floor": {"finish": "parquet", "color": "#b58a5a"},
        "ceiling": {"light": "spots", "color": "#ffffff"}, "curtains": "roman",
        "objects": {"0": {"variant": "corner", "color": "#808080"}, "1": {"hidden": True, "variant": "bogus"},
                    "2": {"hidden": "yes"}, "99": {"hidden": True}, "x": {"hidden": True}},
        "added": [{"kind": "storage", "variant": "dresser", "color": "#5c3a21", "width": 1.2, "depth": 0.45,
                   "height": 0.8, "x": 3.2, "y": 2.75, "angle": 3.14159},
                  {"kind": "spaceship", "width": 1, "depth": 1, "height": 1, "x": 1, "y": 1},
                  {"kind": "sofa", "width": 50, "depth": 0.9, "height": 0.8, "x": 1, "y": 1, "variant": "nope"}]}


def v2(**over) -> dict:
    d = copy.deepcopy(ROOM_V2)
    d.update(over)
    return d


def saved(data: dict) -> dict:
    """Скан как его отдаёт база: чистый + id."""
    return {"id": 1, **clean_scan(data), "look": None}


# ---------- скан v2 и v1 ----------

def test_clean_scan_v2_and_v1():
    s = clean_scan(v2())
    assert s["wall_lines"] == ROOM_V2["wall_lines"]
    assert s["openings"][0] == {"kind": "window", "width": 1.4, "height": 1.5, "wall": 2, "offset": 2.0, "bottom": 0.9}
    assert s["openings"][1]["wall"] == 3 and s["openings"][1]["bottom"] == 0.0
    assert s["quality"] == {"score": 82, "issues": ["Доснимите угол за шкафом <справа>"]}
    assert "format" not in s and "version" not in s

    # концы стен: не столько, сколько стен, битое число или за пределами — не берём совсем
    assert clean_scan(v2(wall_lines=ROOM_V2["wall_lines"][:3]))["wall_lines"] == []
    for bad in (float("nan"), float("inf"), 2000, "x", None):
        lines = copy.deepcopy(ROOM_V2["wall_lines"])
        lines[1][2] = bad
        assert clean_scan(v2(wall_lines=lines))["wall_lines"] == [], bad
    assert clean_scan(v2(wall_lines=[[0, 0, 4]] * 4))["wall_lines"] == []
    assert clean_scan(v2(wall_lines="0,0,4,0"))["wall_lines"] == []

    # окна и двери: номер стены в пределах, отступ и высота от пола — разумные числа
    ops = clean_scan(v2(openings=[
        {"kind": "window", "width": 1, "height": 1, "wall": 7, "offset": -5, "bottom": "x"},
        {"kind": "door", "width": 0.8, "height": 2, "wall": True, "offset": -0.001, "bottom": -0.01},
        {"kind": "portal", "width": 1, "height": 2, "wall": 2.0, "offset": 1.5, "bottom": 50},
    ]))["openings"]
    assert (ops[0]["wall"], ops[0]["offset"], ops[0]["bottom"]) == (None, None, None)
    assert (ops[1]["wall"], ops[1]["offset"], ops[1]["bottom"]) == (None, 0.0, 0.0)
    assert (ops[2]["kind"], ops[2]["wall"], ops[2]["offset"], ops[2]["bottom"]) == ("opening", 2, 1.5, None)

    # оценка качества: 0…100, до 10 подсказок по 120 знаков, только строки
    q = clean_scan(v2(quality={"score": 150, "issues": ["  угол \n за  шкафом "] + ["x" * 300] + [5, None, ""]
                               + [f"п{i}" for i in range(20)]}))["quality"]
    assert q["score"] == 100 and len(q["issues"]) == 10
    assert q["issues"][0] == "угол за шкафом" and len(q["issues"][1]) == 120
    assert clean_scan(v2(quality={"score": -3}))["quality"] == {"score": 0, "issues": []}
    assert clean_scan(v2(quality={"score": "abc", "issues": "текст"}))["quality"] == {"score": None, "issues": []}
    assert clean_scan(v2(quality="плохо"))["quality"] is None

    # первая версия приложения по-прежнему принимается
    old = clean_scan(ROOM_V1)
    assert old["wall_lines"] == [] and old["quality"] is None
    assert old["openings"][1] == {"kind": "door", "width": 0.8, "height": 2.0, "wall": None, "offset": None,
                                  "bottom": None}
    with pytest.raises(ValueError):
        clean_scan({"room": "x", "sizes": "нет"})


def test_scan_text_quality_warnings_and_buttons():
    text = scan_text(clean_scan(v2()))
    assert "⚠️ <b>Нужно доснять:</b>" in text and "• Доснимите угол за шкафом &lt;справа&gt;" in text
    assert "<справа>" not in text
    assert "Нужно доснять" not in scan_text(clean_scan(v2(quality={"score": 95, "issues": []})))
    assert "Нужно доснять" not in scan_text(clean_scan(ROOM_V1))

    datas = [b.callback_data for row in scan_kb(5).inline_keyboard for b in row]
    assert datas == ["sd:5", "sf:5", "se:5"]
    old = config.webapp_url
    object.__setattr__(config, "webapp_url", "https://example.ru")
    try:
        apps = [b.web_app.url for row in scan_kb(5).inline_keyboard for b in row if b.web_app]
        assert apps == ["https://example.ru/app/#scan/5"]
    finally:
        object.__setattr__(config, "webapp_url", old)

    # старый скан в Mini App — с пустыми новыми полями, чтобы 3D строилось одинаково
    view = scan_view({"id": 1, **{k: v for k, v in clean_scan(ROOM_V1).items() if k not in ("wall_lines", "quality")}})
    assert view["wall_lines"] == [] and view["quality"] is None and view["look"] == {}
    assert view["openings"][0]["wall"] is None and view["openings"][0]["offset"] is None


# ---------- ремонт из 3D ----------

def test_clean_look_and_descriptions():
    scan = saved(v2())
    look = clean_look(LOOK, scan)
    assert set(look) == {"style", "wall", "accent", "floor", "ceiling", "curtains", "objects", "added"}
    assert look["wall"] == {"finish": "wallpaper", "color": "#d9cbb5", "pattern": "linen"}
    assert look["accent"] == {"finish": "paint", "color": "#2f4f3a", "wall": 2}
    assert look["objects"] == {"0": {"variant": "corner", "color": "#808080"}, "1": {"hidden": True}}
    assert [a["kind"] for a in look["added"]] == ["storage", "sofa"]
    assert look["added"][0]["variant"] == "dresser" and abs(abs(look["added"][0]["angle"]) - math.pi) < 1e-3
    assert look["added"][1]["width"] == 6 and "variant" not in look["added"][1]       # зажали и выкинули

    # цвет только #rrggbb, варианты — по виду мебели, номера стен — в пределах скана
    bad = clean_look({"wall": {"color": "red"}, "floor": {"color": "#12345g", "finish": "lava"},
                      "accent": {"wall": 9, "color": "#000000"}, "objects": {"0": {"variant": "wardrobe"}},
                      "curtains": "шторы", "style": "gothic"}, scan)
    assert bad == {"accent": {"color": "#000000", "wall": None}}
    many = clean_look({"added": [{"kind": "chair", "width": 0.5, "depth": 0.5, "height": 0.9, "x": 1, "y": 1}] * 40})
    assert len(many["added"]) == 30
    assert clean_look(None) == {}
    with pytest.raises(ValueError):
        clean_look(["не словарь"])
    with pytest.raises(ValueError):
        clean_look({"style": "loft", "junk": "x" * 40_000})

    scan["look"] = look
    en = look_en(look, scan)
    for part in ("beige (#d9cbb5) wallpaper with linen texture", "accent wall (the window wall)",
                 "natural oak (#b58a5a) parquet flooring", "recessed ceiling spotlights", "roman blinds",
                 "the sofa (against the long wall) becomes a grey (#808080) L-shaped corner sofa",
                 "remove the table (free-standing in the room)", "ceiling: white (#ffffff), recessed",
                 "brown (#5c3a21) chest of drawers 120×45×80 cm"):
        assert part in en, part
    ru = look_ru(look, scan)
    assert ru[0] == "Стиль: Лофт"
    assert "Стены: обои с фактурой льна, цвет бежевый" in ru
    assert "Акцентная стена (стена с окном): покраска, цвет тёмно-зелёный" in ru
    assert "Пол: паркет, натуральный дуб" in ru and "Окна: римские шторы" in ru
    assert "Мебель: диван — угловой диван, серый; стол — убрать" in ru
    assert any(x.startswith("Добавить: комод 120×45×80 см, коричневый") for x in ru)
    assert look_en({}, scan) == "" and look_ru(None, scan) == []

    # смета и картинка учитывают выбор
    req = scan_ai.estimate_request(scan)
    assert "Клиент собрал ремонт в 3D" in req and "римские шторы" in req
    assert "roman blinds" in scan_ai.look_text(look, scan)
    assert "Pick finishes" in scan_ai.look_text({}, scan)


# ---------- мебель по размерам ----------

def test_furniture_geometry_and_links():
    items = furniture.pick(saved(v2()))
    sofa, table, tv = items[:3]
    # диван у стены: слева мешает место перед дверью, справа — угол; спереди стол в 40 см
    assert sofa["size"] == {"width": 200, "depth": 90, "height": 85} and sofa["max"] == {"width": 309, "depth": 90}
    assert sofa["index"] == 0 and sofa["wall"] == 0 and sofa["query"] == "диван 200×90 см"
    assert "проход спереди всего 40 см" in sofa["note"]
    assert table["max"] == {"width": 248, "depth": 99} and "вокруг оставлен проход 70 см" in table["note"]
    assert tv["query"] == "телевизор 55 дюймов" and tv["max"]["depth"] == 50   # больше 50 см ТВ не бывает
    shops = [link["shop"] for link in sofa["links"]]
    assert shops == ["Яндекс Маркет", "Ozon", "Wildberries", "Divan.ru"]
    assert "Divan.ru" not in [link["shop"] for link in tv["links"]]
    assert sofa["links"][0]["url"] == \
        "https://market.yandex.ru/search?text=%D0%B4%D0%B8%D0%B2%D0%B0%D0%BD%20200%C3%9790%20%D1%81%D0%BC"
    assert sofa["links"][2]["url"].startswith("https://www.wildberries.ru/catalog/0/search.aspx?search=")

    # советы на свободные стены: шкаф у стены с дверью (не закрывая её), комод под окном
    tips = [i for i in items if i["index"] is None]
    assert 1 <= len(tips) <= 3
    wardrobe = next(t for t in tips if t["variant"] == "wardrobe")
    assert wardrobe["wall"] == 3 and wardrobe["query"] == "шкаф шириной до 190 см" and wardrobe["max"]["depth"] == 60
    assert wardrobe["size"] == {"width": None, "depth": None, "height": None}
    dresser = next(t for t in tips if t["variant"] == "dresser")
    assert dresser["wall"] == 2 and dresser["query"] == "комод шириной до 150 см высотой до 90 см"
    assert "под окном" in dresser["note"] and dresser["place"]["width"] == 1.5

    # ремонт из 3D: диван убран, добавлен комод — ищем уже его
    scan = saved(v2())
    look = clean_look({"objects": {"0": {"hidden": True}, "1": {"variant": "desk"}},
                       "added": [{"kind": "storage", "variant": "dresser", "color": "#5c3a21", "width": 1.2,
                                  "depth": 0.45, "height": 0.8, "x": 2, "y": 0.25, "angle": 0}]}, scan)
    items = furniture.pick(scan, look)
    assert all(i["kind"] != "sofa" for i in items)
    assert items[0]["title"] == "Письменный стол" and items[0]["query"].startswith("письменный стол ")
    added = next(i for i in items if i["added"] == 0)
    assert added["title"] == "Комод" and added["query"] == "комод коричневый 120×45 см" and added["index"] is None

    # старый скан без концов стен и плана: комната из длины и ширины, двери не знаем — советов нет
    old = furniture.pick({**clean_scan(ROOM_V1), "plan": []})
    assert len(old) == 1 and old[0]["title"] == "Холодильник"
    assert old[0]["max"] == {"width": 100, "depth": 80} and old[0]["note"].startswith("В углу")


# ---------- API: скан, мебель, ремонт из 3D, фото «как в жизни» ----------

async def _pair(c, user_id: int) -> tuple[dict, dict]:
    h = {"X-Telegram-Init-Data": sign({"id": user_id})}
    code = (await (await c.post("/api/scan-code", headers=h)).json())["code"]
    token = (await (await c.post("/scan/pair", json={"code": code})).json())["token"]
    return h, {"Authorization": f"Bearer {token}"}


def test_scan_view_furniture_and_look_endpoints(fresh_db):
    object.__setattr__(config, "bot_token", TOKEN)
    bot = FakeBot()

    async def run():
        async with TestClient(TestServer(create_app(bot))) as c:
            h, auth = await _pair(c, 41)
            h2, auth2 = await _pair(c, 42)
            sid = (await (await c.post("/scan/rooms", json=v2(), headers=auth)).json())["id"]
            assert "Нужно доснять" in bot.messages[-1][1]
            old = (await (await c.post("/scan/rooms", json=ROOM_V1, headers=auth)).json())["id"]
            withlook = (await (await c.post("/scan/rooms", json=v2(look=LOOK), headers=auth)).json())["id"]
            assert (await db.get_scan(41, withlook))["look"]["curtains"] == "roman"
            assert "ремонт из 3D сохранён" in bot.messages[-1][1]

            x = await (await c.get(f"/api/scans/{sid}", headers=h)).json()
            assert x["wall_lines"] == ROOM_V2["wall_lines"] and x["openings"][0]["offset"] == 2.0
            assert x["quality"]["score"] == 82 and x["look"] == {} and x["materials"]
            y = await (await c.get(f"/api/scans/{old}", headers=h)).json()
            assert y["wall_lines"] == [] and y["openings"][0]["wall"] is None and y["quality"] is None
            assert (await c.get(f"/api/scans/{sid}", headers=h2)).status == 404

            # мебель по размерам: Mini App и приложение, чужой скан — 404
            r = await c.get(f"/api/scans/{sid}/furniture", headers=h)
            items = (await r.json())["items"]
            assert r.status == 200 and items[0]["title"] == "Диван" and items[0]["links"]
            assert (await c.get(f"/api/scans/{sid}/furniture", headers=h2)).status == 404
            r = await c.post("/scan/furniture", json={"scan_id": sid}, headers=auth)
            assert r.status == 200 and (await r.json())["items"] == items
            assert (await c.post("/scan/furniture", json={"scan_id": sid}, headers=auth2)).status == 404
            r = await c.post("/scan/furniture", json={"scan_id": sid}, headers={"Authorization": "Bearer x"})
            assert r.status == 401
            assert (await c.post("/scan/furniture", json=[1], headers=auth)).status == 400

            # ремонт из 3D: сохранить, прочитать, чужой не трогает, мусор выкидываем
            assert await (await c.get(f"/api/scans/{sid}/look", headers=h)).json() == {"look": {}}
            r = await c.put(f"/api/scans/{sid}/look", json={"look": LOOK}, headers=h)
            look = (await r.json())["look"]
            assert r.status == 200 and look == clean_look(LOOK, (await db.get_scan(41, sid)))
            assert "junk" not in look and look["objects"]["1"] == {"hidden": True}
            assert (await (await c.get(f"/api/scans/{sid}/look", headers=h)).json())["look"] == look
            assert (await c.put(f"/api/scans/{sid}/look", json={"look": LOOK}, headers=h2)).status == 404
            assert (await c.get(f"/api/scans/{sid}/look", headers=h2)).status == 404
            r = await c.put(f"/api/scans/{sid}/look", json={"look": {"junk": "x" * 40_000}}, headers=h)
            assert r.status == 400
            scans = (await (await c.get("/api/scans", headers=h)).json())["scans"]
            assert next(s for s in scans if s["id"] == sid)["look"] == look

            # приложение: те же данные по токену
            r = await c.get(f"/scan/look?scan_id={sid}", headers=auth)
            assert (await r.json())["look"] == look
            r = await c.put("/scan/look", json={"scan_id": sid, "look": {"curtains": "blinds", "bad": 1}}, headers=auth)
            assert (await r.json())["look"] == {"curtains": "blinds"}
            assert (await db.get_scan(41, sid))["look"] == {"curtains": "blinds"}
            assert (await c.put("/scan/look", json={"scan_id": sid, "look": {}}, headers=auth2)).status == 404
            assert (await c.get(f"/scan/look?scan_id={sid}", headers=auth2)).status == 404
            assert (await c.get("/scan/look?scan_id=abc", headers=auth)).status == 404
            r = await c.put("/scan/look", json={"scan_id": sid, "look": None}, headers=auth)   # стереть
            assert (await r.json())["look"] == {} and (await db.get_scan(41, sid))["look"] is None

            # мебель учитывает ремонт из 3D
            await c.put(f"/api/scans/{sid}/look", json={"objects": {"0": {"hidden": True}}}, headers=h)
            items = (await (await c.get(f"/api/scans/{sid}/furniture", headers=h)).json())["items"]
            assert all(i["kind"] != "sofa" for i in items)
    asyncio.run(run())


def test_render_endpoints_charge_and_refund(fresh_db, ai, monkeypatch):
    object.__setattr__(config, "bot_token", TOKEN)
    bot = FakeBot()
    orig_edit = kie.edit_image

    async def run():
        async with TestClient(TestServer(create_app(bot))) as c:
            h, auth = await _pair(c, 51)
            h2, _ = await _pair(c, 52)
            sid = (await (await c.post("/scan/rooms", json=v2(), headers=auth)).json())["id"]
            await db.add_credits(51, 10)
            start = (await db.get_user(51))["credits"]
            snap = "data:image/jpeg;base64," + base64.b64encode(JPEG).decode()

            # Mini App: снимок 3D + выбор → фото, списано как за картинку ремонта, выбор сохранён
            r = await c.post(f"/api/scans/{sid}/render", json={"image": snap, "style": "loft", "look": LOOK}, headers=h)
            data = await r.json()
            assert r.status == 200 and data["image"] == "https://files/result.png" and data["style"] == "Лофт"
            assert data["credits"] == start - PRICES["design"]
            kind, url, prompt = ai[-1]
            assert kind == "edit" and url.startswith("https://files/")
            assert "3D model of a real room" in prompt and "industrial loft" in prompt and "roman blinds" in prompt
            assert "4 m × 3 m" in prompt and "no watermarks" in prompt
            # мебель — как на снимке 3D: стол убран, диван заменён, комод добавлен, и всё это уже «на месте»
            assert "grey (#808080) L-shaped corner sofa 200×90×85 cm against the long wall" in prompt
            assert "brown (#5c3a21) chest of drawers 120×45×80 cm" in prompt
            assert "table 100×60×45" not in prompt
            assert "remove the" not in prompt and "add a " not in prompt and "becomes a" not in prompt
            assert (await db.get_scan(51, sid))["look"]["curtains"] == "roman"

            # ошибки проверки — без списания
            for body in ({"image": snap, "style": "gothic"}, {"image": "не картинка", "style": "loft"},
                         {"image": base64.b64encode(b"GIF89a....").decode(), "style": "loft"}):
                assert (await c.post(f"/api/scans/{sid}/render", json=body, headers=h)).status == 400
            assert (await c.post(f"/api/scans/{sid}/render", json={"image": snap, "style": "loft"},
                                 headers=h2)).status == 404
            assert (await db.get_user(51))["credits"] == start - PRICES["design"]

            # приложение: base64 без префикса, PNG тоже подходит; без look — берём сохранённый
            r = await c.post("/scan/render", json={"scan_id": sid, "image": base64.b64encode(PNG).decode(),
                                                   "style": "scandi"}, headers=auth)
            assert r.status == 200 and (await r.json())["image"] == "https://files/result.png"
            assert "roman blinds" in ai[-1][2]
            assert (await db.get_user(51))["credits"] == start - 2 * PRICES["design"]

            # ИИ упал — кредиты вернулись, ответ 502
            async def broken(url, prompt, aspect_ratio="auto"):
                raise kie.KieError("boom")
            monkeypatch.setattr(kie, "edit_image", broken)
            r = await c.post("/scan/render", json={"scan_id": sid, "image": base64.b64encode(JPEG).decode(),
                                                   "style": "loft"}, headers=auth)
            assert r.status == 502 and (await db.get_user(51))["credits"] == start - 2 * PRICES["design"]
            monkeypatch.setattr(kie, "edit_image", orig_edit)

            # старый /scan/design понимает и scan_id
            r = await c.post("/scan/design", json={"scan_id": sid, "style": "modern"}, headers=auth)
            assert r.status == 200 and "roman blinds" in ai[-1][-1]

            # кредиты кончились → 402, ничего не списано
            await db.add_credits(51, -1000)
            r = await c.post(f"/api/scans/{sid}/render", json={"image": snap, "style": "loft"}, headers=h)
            assert r.status == 402 and (await r.json())["need"] == PRICES["design"]
            r = await c.post("/scan/render", json={"scan_id": sid, "image": snap, "style": "loft"}, headers=auth)
            assert r.status == 402 and (await db.get_user(51))["credits"] == 0
    asyncio.run(run())


def test_scan_prompts_are_photoreal():
    from bot import prompts
    for p in (prompts.SCAN_DESIGN_PROMPT, prompts.SCAN_T2I_PROMPT, prompts.SCAN_RENDER_PROMPT):
        assert "{style}" in p and "{facts}" in p and "{look}" in p
        assert "no text" in p and "watermarks" in p and ("not a render" in p or "3D-render look" in p
                                                         or "not a 3D render" in p)
    assert scan_ai.SCAN_RENDER_PROMPT is prompts.SCAN_RENDER_PROMPT
    facts = scan_ai.facts_en(saved(v2()))
    assert "window 1.4×1.5 m on the long wall, sill at 0.9 m" in facts
    assert "bed" not in facts and "table 100×60×45 cm free-standing in the room" in facts
    json.dumps(facts)


def test_old_scans_table_gets_look_column(tmp_path):
    """База, где сканы уже были, получает колонку look; старые сканы читаются без неё."""
    import sqlite3
    path = str(tmp_path / "old.db")
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE scans (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, room TEXT,
            data TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
    """)
    old = {k: v for k, v in clean_scan(ROOM_V1).items() if k not in ("room", "wall_lines", "quality")}
    con.execute("INSERT INTO scans (user_id, room, data) VALUES (7, 'Кухня', ?)", (json.dumps(old),))
    con.commit()
    con.close()
    object.__setattr__(config, "db_path", path)

    async def run():
        await db.init_db()
        (old,) = await db.list_scans(7)
        assert old["room"] == "Кухня" and old["look"] is None and "wall_lines" not in old
        assert await db.set_scan_look(7, old["id"], {"curtains": "blinds"})
        assert not await db.set_scan_look(8, old["id"], {"curtains": "none"})       # чужой
        assert (await db.get_scan(7, old["id"]))["look"] == {"curtains": "blinds"}
        assert furniture.pick(old)[0]["title"] == "Холодильник"
    asyncio.run(run())


# ---------- найдено на ревью ----------

def _maximal() -> dict:
    """Самый тяжёлый скан, который пропускает проверка: 40 стен по 30 м, 200 точек контура,
    80 окон и дверей на стенах, 80 предметов."""
    rnd = random.Random(7)
    side = [-100 + 4 * k for k in range(50)]
    plan = [[x, -100] for x in side] + [[100, y] for y in side] + [[-x, 100] for x in side] + [[-100, -y] for y in side]
    lines = [[-15 + k % 4 * 20, -99 + k * 5, 15 + k % 4 * 20, -99 + k * 5] for k in range(40)]
    return v2(walls=[{"length": 30, "height": 3}] * 40, wall_lines=lines, plan=plan,
              openings=[{"kind": ("door", "window", "opening")[k % 3], "width": 2, "height": 2, "wall": k % 40,
                         "offset": 3 + k // 40 * 12, "bottom": 0.5} for k in range(80)],
              objects=[{"kind": "sofa", "width": 1.5, "depth": 0.8, "height": 0.8, "x": rnd.uniform(-99, 99),
                        "y": rnd.uniform(-99, 99), "angle": rnd.uniform(0, 6)} for _ in range(80)])


def test_crafted_scan_is_bounded_and_fast():
    """Присланный «скан-ловушка» не вешает бота: мебель по размерам считается меньше секунды."""
    # как в отчёте ревью: 80 стен по 2 км, контур ±999 м, 80 диванов — стены и контур не берём
    trap = clean_scan(v2(walls=[{"length": 50, "height": 3}] * 80,
                         wall_lines=[[-999, -999 + k * 25, 999, -999 + k * 25] for k in range(80)],
                         plan=[[-999, -999], [999, -999], [999, 999], [-999, 999]],
                         objects=[{"kind": "sofa", "width": 2, "depth": 0.9, "height": 0.8, "x": -900 + k * 20,
                                   "y": 0, "angle": 0} for k in range(80)]))
    assert trap["wall_lines"] == [] and trap["plan"] == []
    assert {o["x"] for o in trap["objects"][:5]} == {0.0}           # мебель далеко за 100 м — в начало плана
    start = time.perf_counter()
    furniture.pick({"id": 1, **trap})
    assert time.perf_counter() - start < 1

    # самый тяжёлый честный скан + ремонт из 3D с 30 добавленными вещами
    scan = saved(_maximal())
    assert len(scan["wall_lines"]) == 40 and len(scan["plan"]) == 200
    assert all(o["wall"] is not None for o in scan["openings"])
    look = clean_look({"objects": {str(i): {"color": "#123456"} for i in range(80)},
                       "added": [{"kind": "table", "width": 1, "depth": 1, "height": 1, "x": k * 6 - 90, "y": 50,
                                  "angle": 1} for k in range(30)]}, scan)
    assert len(look["added"]) == 30
    start = time.perf_counter()
    items = furniture.pick(scan, look)
    assert time.perf_counter() - start < 1 and len(items) == 110 + 3
    # он же без точных стен и окон: 200 сторон контура пола тоже считаются быстро
    flat = {**scan, "wall_lines": [], "openings": []}
    assert Room(flat).located and len(Room(flat).walls) == 200
    start = time.perf_counter()
    assert len(furniture.pick(flat, look)) > 110 and time.perf_counter() - start < 1

    # точные стены не берём: больше 40, длиннее 30 м, дальше 1 м от контура пола
    lines = ROOM_V2["wall_lines"]
    assert clean_scan(v2(walls=[{"length": 1}] * 41, wall_lines=[[0, 0, 1, 0]] * 41))["wall_lines"] == []
    assert clean_scan(v2(wall_lines=[[0, 0, 31, 0]] + lines[1:], plan=[[0, 0], [31, 0], [31, 3], [0, 3]])
                      )["wall_lines"] == []
    assert clean_scan(v2(wall_lines=[[0, 0, 5.5, 0]] + lines[1:]))["wall_lines"] == []
    assert clean_scan(v2(wall_lines=[[-0.5, 0, 4.5, 0]] + lines[1:]))["wall_lines"][0] == [-0.5, 0, 4.5, 0]
    assert clean_scan(v2(wall_lines=[[0, 0, 5.5, 0]] + lines[1:], plan=[]))["wall_lines"][0] == [0, 0, 5.5, 0]


def test_l_shaped_room_on_hull_plan():
    """iOS 16: контур пола — выпуклая оболочка концов стен. У стены внутреннего угла Г-образной комнаты
    обе стороны «внутри» контура — сторону комнаты определяем по самим стенам, дверь не уходит наружу."""
    lines = [[0, 0, 6, 0], [6, 0, 6, 3], [3, 3, 6, 3], [3, 3, 3, 5], [3, 5, 0, 5], [0, 5, 0, 0]]

    def scan(plan):
        return saved(v2(room="Гостиная", walls=[{"length": math.dist(ln[:2], ln[2:]), "height": 2.7} for ln in lines],
                        wall_lines=lines, plan=plan,
                        openings=[{"kind": "door", "width": 0.9, "height": 2, "wall": 2, "offset": 2.4, "bottom": 0}],
                        objects=[{"kind": "sofa", "width": 2, "depth": 0.9, "height": 0.85, "x": 5.55, "y": 1.05,
                                  "angle": math.pi / 2}]))
    hull = scan([[0, 0], [6, 0], [6, 3], [3, 5], [0, 5]])
    room = Room(hull)
    assert room.inward(2) == pytest.approx((0, -1)) and room.inward(3) == pytest.approx((-1, 0))
    door = room.zones()[0]
    assert room.enclosed((door.x, door.y)) and door.y < 3
    sofa = furniture.pick(hull)[0]
    assert sofa["max"]["width"] == 208                # дальше — дверь, а не 2,98 м до угла ниши
    assert sofa["max"] == furniture.pick(scan([[0, 0], [6, 0], [6, 3], [3, 3], [3, 5], [0, 5]]))[0]["max"]


def test_old_scan_tips_only_when_openings_known():
    """Старый скан: где окна, неизвестно — шкаф во всю стену не советуем, он может закрыть окно."""
    old = {"id": 1, **clean_scan({**ROOM_V1, "room": "Спальня", "objects": [],
                                 "openings": [{"kind": "window", "width": 1.4, "height": 1.5}]}),
           "plan": [[0, 0], [4, 0], [4, 3], [0, 3]]}
    assert not Room(old).located and furniture.pick(old) == []
    tips = furniture.pick({**old, "openings": []})          # ни окон, ни дверей — советы есть
    assert tips and all(t["index"] is None for t in tips)


def test_accent_wall_on_outline_edges():
    """Старый скан без точных стен: Mini App нумерует стены по сторонам контура пола — и мы так же."""
    plan = [[0, 0], [4, 0], [4, 2], [3, 2], [3, 3], [0, 3]]
    old = {"id": 1, **clean_scan({**ROOM_V1, "plan": plan}), "look": None}
    accent = {"wall": 5, "finish": "paint", "color": "#2f4f3a"}
    assert clean_look({"accent": accent}, old)["accent"]["wall"] == 5
    assert clean_look({"accent": {**accent, "wall": 6}}, old)["accent"]["wall"] is None
    assert "one accent wall (the short wall)" in look_en({"accent": accent}, old)
    # без контура — прямоугольник из длины и ширины, 4 стены
    flat = {"id": 1, **clean_scan(ROOM_V1)}
    assert clean_look({"accent": {**accent, "wall": 3}}, flat)["accent"]["wall"] == 3
    assert clean_look({"accent": accent}, flat)["accent"]["wall"] is None


def test_render_prompt_describes_room_as_in_3d(fresh_db, ai):
    """«Как в жизни»: на снимке 3D мебель уже как её собрали — в промпте её не «убираем» и не «добавляем»,
    иначе ИИ вернёт убранный диван или нарисует кресло дважды."""
    scan = saved(v2())
    look = clean_look({"curtains": "roman", "objects": {"0": {"hidden": True}, "1": {"variant": "desk",
                                                                                      "color": "#ffffff"}},
                       "added": [{"kind": "chair", "variant": "armchair", "color": "#2f4f3a", "width": 0.8,
                                  "depth": 0.8, "height": 0.9, "x": 0.5, "y": 0.5, "angle": 0}]}, scan)
    text = SCAN_RENDER_PROMPT.format(style="loft", facts=scan_ai.facts_en(scan, look),
                                     look=scan_ai.look_text(look, scan, edited=True))
    assert "200×90×85" not in text                                  # убранный диван
    assert "remove the" not in text and "add a " not in text and "becomes a" not in text
    assert "white (#ffffff) desk 100×60×45 cm free-standing in the room" in text
    assert "dark green (#2f4f3a) armchair 80×80×90 cm in the corner" in text
    assert "The client chose these finishes, show exactly them: windows: roman blinds." in text
    assert "Pick finishes and lighting" in scan_ai.look_text({"objects": look["objects"]}, scan, edited=True)

    # на фото комнаты «как есть» — по-прежнему словами: что убрать и что добавить
    photo = scan_ai.look_text(look, scan)
    assert "remove the sofa" in photo and "add a dark green (#2f4f3a) armchair" in photo
    assert "sofa 200×90×85 cm against the long wall" in scan_ai.facts_en(scan)

    # без фото рисуем с нуля — сразу комнату из 3D
    assert asyncio.run(scan_ai.design_image(scan, "loft", look)) == "https://files/t2i.png"
    kind, prompt = ai[-1]
    assert kind == "t2i" and "white (#ffffff) desk" in prompt and "remove the" not in prompt
    assert "200×90×85" not in prompt

