"""SQLite-хранилище: пользователи, баланс, платежи, журнал генераций, объекты, состояния диалогов,
LiDAR-сканы с iPhone."""
import json
import secrets
import time
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
CREATE TABLE IF NOT EXISTS fsm (
    key TEXT PRIMARY KEY,
    state TEXT,
    data TEXT
);
CREATE TABLE IF NOT EXISTS objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    address TEXT,
    budget INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS expenses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    object_id INTEGER NOT NULL,
    kind TEXT NOT NULL,
    amount INTEGER NOT NULL,
    note TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS stages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    object_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    due TEXT,
    done INTEGER NOT NULL DEFAULT 0,
    reminded INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS scan_codes (
    code TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    expires INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS scan_tokens (
    token TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    device TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    room TEXT,
    data TEXT NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_scans_user ON scans(user_id);
CREATE INDEX IF NOT EXISTS idx_objects_owner ON objects(owner_id);
CREATE INDEX IF NOT EXISTS idx_expenses_object ON expenses(object_id);
CREATE INDEX IF NOT EXISTS idx_stages_object ON stages(object_id);
"""

# Колонки, добавленные после первой версии: (таблица, колонка, описание)
MIGRATIONS = [
    ("users", "referrer_id", "INTEGER"),
    ("users", "ref_rewarded", "INTEGER NOT NULL DEFAULT 0"),
    ("payments", "refunded", "INTEGER NOT NULL DEFAULT 0"),
]

EXPENSE_KINDS = {
    "material": "🧱 Материалы",
    "payment": "💵 Выплаты",
    "other": "📦 Прочее",
}


async def init_db(path: str | None = None) -> None:
    async with aiosqlite.connect(path or config.db_path) as db:
        await db.executescript(SCHEMA)
        for table, column, ddl in MIGRATIONS:
            cols = [r[1] for r in await (await db.execute(f"PRAGMA table_info({table})")).fetchall()]
            if column not in cols:
                await db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")
        await db.commit()


def _conn():
    return aiosqlite.connect(config.db_path)


# ---------- пользователи ----------

async def get_or_create_user(user_id: int, username: str | None, referrer_id: int | None = None) -> dict:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM users WHERE id=?", (user_id,))).fetchone()
        if row is None:
            if referrer_id == user_id:
                referrer_id = None
            if referrer_id is not None:
                exists = await (await db.execute("SELECT 1 FROM users WHERE id=?", (referrer_id,))).fetchone()
                if not exists:
                    referrer_id = None
            await db.execute(
                "INSERT INTO users (id, username, credits, referrer_id) VALUES (?, ?, ?, ?)",
                (user_id, username, config.welcome_credits, referrer_id),
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
    """Начисляет (или списывает) кредиты; баланс не уходит ниже нуля."""
    async with _conn() as db:
        await db.execute(
            "UPDATE users SET credits = MAX(0, credits + ?) WHERE id=?", (amount, user_id)
        )
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


async def refund_free_consult(user_id: int) -> None:
    """Возвращает бесплатный вопрос, если ответ не удался."""
    today = date.today().isoformat()
    async with _conn() as db:
        await db.execute(
            "UPDATE users SET consult_used = MAX(0, consult_used - 1) WHERE id=? AND consult_day=?",
            (user_id, today),
        )
        await db.commit()


# ---------- рефералка ----------

async def reward_referrer(user_id: int, bonus: int) -> int | None:
    """После первой успешной платной задачи приглашённого начисляет бонус пригласившему.
    Возвращает id пригласившего, если бонус начислен сейчас."""
    async with _conn() as db:
        row = await (
            await db.execute("SELECT referrer_id, ref_rewarded FROM users WHERE id=?", (user_id,))
        ).fetchone()
        if not row or not row[0] or row[1]:
            return None
        cur = await db.execute(
            "UPDATE users SET ref_rewarded=1 WHERE id=? AND ref_rewarded=0", (user_id,)
        )
        if cur.rowcount == 0:
            return None
        await db.execute("UPDATE users SET credits = credits + ? WHERE id=?", (bonus, row[0]))
        await db.commit()
        return row[0]


async def referral_stats(user_id: int) -> tuple[int, int]:
    """(сколько пригласил, скольким начислен бонус)."""
    async with _conn() as db:
        row = await (
            await db.execute(
                "SELECT COUNT(*), COALESCE(SUM(ref_rewarded),0) FROM users WHERE referrer_id=?",
                (user_id,),
            )
        ).fetchone()
        return row[0], row[1]


# ---------- платежи ----------

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


async def get_payment(charge_id: str) -> dict | None:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM payments WHERE charge_id=?", (charge_id,))).fetchone()
        return dict(row) if row else None


async def last_payments(user_id: int, limit: int = 5) -> list[dict]:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM payments WHERE user_id=? ORDER BY id DESC LIMIT ?", (user_id, limit)
            )
        ).fetchall()
        return [dict(r) for r in rows]


async def mark_refunded(charge_id: str) -> dict | None:
    """Помечает платёж возвращённым и списывает начисленные кредиты (не ниже нуля).
    None — если платежа нет или он уже возвращён."""
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM payments WHERE charge_id=?", (charge_id,))).fetchone()
        if not row or row["refunded"]:
            return None
        await db.execute("UPDATE payments SET refunded=1 WHERE charge_id=?", (charge_id,))
        await db.execute(
            "UPDATE users SET credits = MAX(0, credits - ?) WHERE id=?", (row["credits"], row["user_id"])
        )
        await db.commit()
        return dict(row)


async def stats() -> dict:
    async with _conn() as db:
        users = (await (await db.execute("SELECT COUNT(*) FROM users")).fetchone())[0]
        stars = (await (await db.execute(
            "SELECT COALESCE(SUM(stars),0) FROM payments WHERE refunded=0")).fetchone())[0]
        jobs = (await (await db.execute("SELECT COUNT(*) FROM jobs WHERE status='done'")).fetchone())[0]
        by_kind = await (
            await db.execute("SELECT kind, COUNT(*) FROM jobs WHERE status='done' GROUP BY kind")
        ).fetchall()
        refs = (await (await db.execute(
            "SELECT COUNT(*) FROM users WHERE referrer_id IS NOT NULL")).fetchone())[0]
        objects = (await (await db.execute("SELECT COUNT(*) FROM objects")).fetchone())[0]
        return {"users": users, "stars": stars, "jobs": jobs, "by_kind": dict(by_kind),
                "referred": refs, "objects": objects}


# ---------- объекты: материалы, выплаты, этапы ----------

async def create_object(owner_id: int, name: str, address: str = "", budget: int = 0) -> int:
    async with _conn() as db:
        cur = await db.execute(
            "INSERT INTO objects (owner_id, name, address, budget) VALUES (?, ?, ?, ?)",
            (owner_id, name.strip()[:100], address.strip()[:200], max(0, budget)),
        )
        await db.commit()
        return cur.lastrowid


async def list_objects(owner_id: int, archived: bool = False) -> list[dict]:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM objects WHERE owner_id=? AND archived=? ORDER BY id DESC",
                (owner_id, int(archived)),
            )
        ).fetchall()
        return [dict(r) for r in rows]


async def get_object(object_id: int, owner_id: int) -> dict | None:
    """Объект только своего владельца (защита от чужих id)."""
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        row = await (
            await db.execute("SELECT * FROM objects WHERE id=? AND owner_id=?", (object_id, owner_id))
        ).fetchone()
        return dict(row) if row else None


async def update_object(object_id: int, owner_id: int, **fields) -> bool:
    allowed = {k: v for k, v in fields.items() if k in ("name", "address", "budget", "archived")}
    if not allowed:
        return False
    sets = ", ".join(f"{k}=?" for k in allowed)
    async with _conn() as db:
        cur = await db.execute(
            f"UPDATE objects SET {sets} WHERE id=? AND owner_id=?",
            (*allowed.values(), object_id, owner_id),
        )
        await db.commit()
        return cur.rowcount > 0


async def delete_object(object_id: int, owner_id: int) -> bool:
    async with _conn() as db:
        cur = await db.execute("DELETE FROM objects WHERE id=? AND owner_id=?", (object_id, owner_id))
        if cur.rowcount:
            await db.execute("DELETE FROM expenses WHERE object_id=?", (object_id,))
            await db.execute("DELETE FROM stages WHERE object_id=?", (object_id,))
        await db.commit()
        return cur.rowcount > 0


async def add_expense(object_id: int, kind: str, amount: int, note: str = "") -> int:
    if kind not in EXPENSE_KINDS:
        kind = "other"
    async with _conn() as db:
        cur = await db.execute(
            "INSERT INTO expenses (object_id, kind, amount, note) VALUES (?, ?, ?, ?)",
            (object_id, kind, amount, note.strip()[:200]),
        )
        await db.commit()
        return cur.lastrowid


async def list_expenses(object_id: int, limit: int = 100) -> list[dict]:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM expenses WHERE object_id=? ORDER BY id DESC LIMIT ?", (object_id, limit)
            )
        ).fetchall()
        return [dict(r) for r in rows]


async def delete_expense(expense_id: int, owner_id: int) -> bool:
    async with _conn() as db:
        cur = await db.execute(
            "DELETE FROM expenses WHERE id=? AND object_id IN (SELECT id FROM objects WHERE owner_id=?)",
            (expense_id, owner_id),
        )
        await db.commit()
        return cur.rowcount > 0


async def expense_totals(object_id: int) -> dict[str, int]:
    async with _conn() as db:
        rows = await (
            await db.execute(
                "SELECT kind, COALESCE(SUM(amount),0) FROM expenses WHERE object_id=? GROUP BY kind",
                (object_id,),
            )
        ).fetchall()
        return {k: v for k, v in rows}


async def add_stage(object_id: int, name: str, due: str | None = None) -> int:
    async with _conn() as db:
        cur = await db.execute(
            "INSERT INTO stages (object_id, name, due) VALUES (?, ?, ?)",
            (object_id, name.strip()[:100], due),
        )
        await db.commit()
        return cur.lastrowid


async def list_stages(object_id: int) -> list[dict]:
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT * FROM stages WHERE object_id=? ORDER BY done, COALESCE(due, '9999'), id",
                (object_id,),
            )
        ).fetchall()
        return [dict(r) for r in rows]


async def set_stage_done(stage_id: int, owner_id: int, done: bool = True) -> bool:
    async with _conn() as db:
        cur = await db.execute(
            "UPDATE stages SET done=? WHERE id=? AND object_id IN (SELECT id FROM objects WHERE owner_id=?)",
            (int(done), stage_id, owner_id),
        )
        await db.commit()
        return cur.rowcount > 0


async def delete_stage(stage_id: int, owner_id: int) -> bool:
    async with _conn() as db:
        cur = await db.execute(
            "DELETE FROM stages WHERE id=? AND object_id IN (SELECT id FROM objects WHERE owner_id=?)",
            (stage_id, owner_id),
        )
        await db.commit()
        return cur.rowcount > 0


async def due_stages(today: str) -> list[dict]:
    """Незакрытые этапы со сроком сегодня или раньше, о которых ещё не напоминали."""
    async with _conn() as db:
        db.row_factory = aiosqlite.Row
        rows = await (
            await db.execute(
                "SELECT s.*, o.owner_id, o.name AS object_name FROM stages s "
                "JOIN objects o ON o.id = s.object_id "
                "WHERE s.done=0 AND s.reminded=0 AND s.due IS NOT NULL AND s.due <= ? AND o.archived=0",
                (today,),
            )
        ).fetchall()
        return [dict(r) for r in rows]


async def mark_reminded(stage_id: int) -> None:
    async with _conn() as db:
        await db.execute("UPDATE stages SET reminded=1 WHERE id=?", (stage_id,))
        await db.commit()


# ---------- LiDAR-сканер на iPhone ----------
# Приложение СтройСкан подключается к аккаунту по одноразовому коду (живёт 10 минут)
# и получает постоянный токен, с которым отправляет сканы комнат.

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


async def create_scan_code(user_id: int, ttl: int = 600) -> str:
    code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(8))
    async with _conn() as db:
        await db.execute("DELETE FROM scan_codes WHERE user_id=? OR expires<?", (user_id, int(time.time())))
        await db.execute("INSERT INTO scan_codes (code, user_id, expires) VALUES (?, ?, ?)",
                         (code, user_id, int(time.time()) + ttl))
        await db.commit()
    return code


async def redeem_scan_code(code: str, device: str = "") -> tuple[int, str] | None:
    """Код → (user_id, токен). Код одноразовый."""
    code = "".join(ch for ch in code.upper() if ch.isalnum())
    async with _conn() as db:
        row = await (await db.execute("SELECT user_id, expires FROM scan_codes WHERE code=?", (code,))).fetchone()
        if not row:
            return None
        await db.execute("DELETE FROM scan_codes WHERE code=?", (code,))
        if row[1] < time.time():
            await db.commit()
            return None
        token = secrets.token_urlsafe(32)
        await db.execute("INSERT INTO scan_tokens (token, user_id, device) VALUES (?, ?, ?)",
                         (token, row[0], device[:60]))
        await db.commit()
        return row[0], token


async def user_by_scan_token(token: str) -> int | None:
    if not token:
        return None
    async with _conn() as db:
        row = await (await db.execute("SELECT user_id FROM scan_tokens WHERE token=?", (token,))).fetchone()
        return row[0] if row else None


async def add_scan(user_id: int, room: str, data: dict) -> int:
    async with _conn() as db:
        cur = await db.execute("INSERT INTO scans (user_id, room, data) VALUES (?, ?, ?)",
                               (user_id, room[:60], json.dumps(data, ensure_ascii=False)))
        await db.commit()
        return cur.lastrowid


async def list_scans(user_id: int, limit: int = 20) -> list[dict]:
    async with _conn() as db:
        rows = await (await db.execute(
            "SELECT id, room, data, created_at FROM scans WHERE user_id=? ORDER BY id DESC LIMIT ?",
            (user_id, limit))).fetchall()
    return [{"id": r[0], "room": r[1], "created_at": r[3], **json.loads(r[2])} for r in rows]
