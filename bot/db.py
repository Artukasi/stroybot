"""SQLite-хранилище: пользователи, баланс, платежи, журнал генераций."""
from datetime import date

import aiosqlite

from .config import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    username TEXT,
    role TEXT,
    credits INTEGER NOT NULL DEFAULT 0,
    consult_day TEXT,
    consult_used INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    stars INTEGER NOT NULL,
    credits INTEGER NOT NULL,
    charge_id TEXT UNIQUE,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    cost INTEGER NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
"""


async def init_db(path: str | None = None) -> None:
    async with aiosqlite.connect(path or config.db_path) as db:
        await db.executescript(SCHEMA)
        await db.commit()


def _conn():
    return aiosqlite.connect(config.db_path)


async def get_or_create_user(user_id: int, username: str | None) -> dict:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM users WHERE id=?", (user_id,))).fetchone()
        if row is None:
            await db.execute(
                "INSERT INTO users (id, username, credits) VALUES (?, ?, ?)",
                (user_id, username, config.welcome_credits),
            )
            await db.commit()
            row = await (await db.execute("SELECT * FROM users WHERE id=?", (user_id,))).fetchone()
        return dict(row)


async def get_user(user_id: int) -> dict | None:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM users WHERE id=?", (user_id,))).fetchone()
        return dict(row) if row else None


async def set_role(user_id: int, role: str) -> None:
    async with _conn() as db:
        await db.execute("UPDATE users SET role=? WHERE id=?", (role, user_id))
        await db.commit()


async def add_credits(user_id: int, amount: int) -> int:
    async with _conn() as db:
        await db.execute("UPDATE users SET credits = credits + ? WHERE id=?", (amount, user_id))
        await db.commit()
        row = await (await db.execute("SELECT credits FROM users WHERE id=?", (user_id,))).fetchone()
        return row[0] if row else 0


async def charge(user_id: int, amount: int, kind: str) -> int | None:
    """Атомарно списывает кредиты. Возвращает id задачи или None, если не хватает."""
    async with _conn() as db:
        cur = await db.execute(
            "UPDATE users SET credits = credits - ? WHERE id=? AND credits >= ?",
            (amount, user_id, amount),
        )
        if cur.rowcount == 0:
            await db.rollback()
            return None
        cur = await db.execute(
            "INSERT INTO jobs (user_id, kind, cost, status) VALUES (?, ?, ?, 'running')",
            (user_id, kind, amount),
        )
        await db.commit()
        return cur.lastrowid


async def finish_job(job_id: int, ok: bool) -> None:
    """Закрывает задачу; при ошибке возвращает кредиты пользователю."""
    async with _conn() as db:
        row = await (
            await db.execute("SELECT user_id, cost, status FROM jobs WHERE id=?", (job_id,))
        ).fetchone()
        if not row or row[2] != "running":
            return
        user_id, cost, _ = row
        await db.execute(
            "UPDATE jobs SET status=? WHERE id=?", ("done" if ok else "refunded", job_id)
        )
        if not ok:
            await db.execute("UPDATE users SET credits = credits + ? WHERE id=?", (cost, user_id))
        await db.commit()


async def use_free_consult(user_id: int, limit: int) -> bool:
    """True, если бесплатный вопрос на сегодня ещё есть (и засчитывает его)."""
    today = date.today().isoformat()
    async with _conn() as db:
        row = await (
            await db.execute("SELECT consult_day, consult_used FROM users WHERE id=?", (user_id,))
        ).fetchone()
        day, used = (row or (None, 0))
        if day != today:
            used = 0
        if used >= limit:
            return False
        await db.execute(
            "UPDATE users SET consult_day=?, consult_used=? WHERE id=?", (today, used + 1, user_id)
        )
        await db.commit()
        return True


async def record_payment(user_id: int, stars: int, credits: int, charge_id: str) -> bool:
    """Записывает платёж и начисляет кредиты. False — если платёж уже учтён."""
    async with _conn() as db:
        try:
            await db.execute(
                "INSERT INTO payments (user_id, stars, credits, charge_id) VALUES (?, ?, ?, ?)",
                (user_id, stars, credits, charge_id),
            )
        except aiosqlite.IntegrityError:
            return False
        await db.execute("UPDATE users SET credits = credits + ? WHERE id=?", (credits, user_id))
        await db.commit()
        return True


async def stats() -> dict:
    async with _conn() as db:
        users = (await (await db.execute("SELECT COUNT(*) FROM users")).fetchone())[0]
        stars = (await (await db.execute("SELECT COALESCE(SUM(stars),0) FROM payments")).fetchone())[0]
        jobs = (await (await db.execute("SELECT COUNT(*) FROM jobs WHERE status='done'")).fetchone())[0]
        by_kind = await (
            await db.execute("SELECT kind, COUNT(*) FROM jobs WHERE status='done' GROUP BY kind")
        ).fetchall()
        return {"users": users, "stars": stars, "jobs": jobs, "by_kind": dict(by_kind)}
