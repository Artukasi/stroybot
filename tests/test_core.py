import asyncio

import pytest

from bot import calc, db
from bot.config import config


def test_parse_numbers():
    assert calc.parse_numbers("12 30x60") == [12, 30, 60]
    assert calc.parse_numbers("3,5 х 4 м") == [3.5, 4]


def test_tile():
    r = calc.tile(12, 30, 60)  # 12 / 0.18 * 1.1 = 73.3 -> 74
    assert "74 шт" in r.lines[0]
    assert "3 меш" in r.text()  # 60 кг клея


def test_laminate():
    r = calc.laminate(18, 2.13)  # 18*1.07/2.13 = 9.04 -> 10
    assert "10 (запас" in r.lines[0]


def test_wallpaper():
    r = calc.wallpaper(14, 2.7)  # 14/1.06 = 13.2 -> 14 полос, 3 из рулона -> 5 рулонов
    assert "Полос: 14, из рулона выходит 3" in r.lines[0]
    assert r.lines[1].endswith(": 5")


def test_plaster_paint():
    assert calc.plaster(40, 10).lines[1].endswith(": 12")   # 360 кг / 30
    assert calc.paint(35, 2).lines[1].endswith(": 1")       # 8.4 л


def test_calcs_registry():
    for key, (_, _, min_n, fn) in calc.CALCS.items():
        res = fn([10.0] * max(min_n, 3))
        assert res.lines, key


def test_db_flow(tmp_path):
    object.__setattr__(config, "db_path", str(tmp_path / "t.db"))  # config — frozen dataclass

    async def run():
        await db.init_db()
        u = await db.get_or_create_user(1, "x")
        assert u["credits"] == config.welcome_credits
        job = await db.charge(1, 2, "design")
        assert job and (await db.get_user(1))["credits"] == config.welcome_credits - 2
        assert await db.charge(1, 100, "design") is None
        await db.finish_job(job, ok=False)       # возврат
        await db.finish_job(job, ok=False)       # повторно не возвращает
        assert (await db.get_user(1))["credits"] == config.welcome_credits
        assert await db.record_payment(1, 100, 10, "c1")
        assert not await db.record_payment(1, 100, 10, "c1")  # дубль
        assert (await db.get_user(1))["credits"] == config.welcome_credits + 10
        assert await db.use_free_consult(1, 1)
        assert not await db.use_free_consult(1, 1)

    asyncio.run(run())
