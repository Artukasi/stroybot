"""Хранение состояний диалогов в SQLite, чтобы они переживали перезапуск бота."""
import json
from typing import Any, Mapping

import aiosqlite
from aiogram.fsm.state import State
from aiogram.fsm.storage.base import BaseStorage, DefaultKeyBuilder, StorageKey

from .config import config


class SQLiteStorage(BaseStorage):
    def __init__(self, path: str | None = None):
        self.path = path
        self.key_builder = DefaultKeyBuilder(with_destiny=True)

    def _path(self) -> str:
        return self.path or config.db_path

    def _key(self, key: StorageKey) -> str:
        return self.key_builder.build(key)

    async def set_state(self, key: StorageKey, state: str | State | None = None) -> None:
        value = state.state if isinstance(state, State) else state
        async with aiosqlite.connect(self._path()) as db:
            await db.execute(
                "INSERT INTO fsm (key, state) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET state=excluded.state",
                (self._key(key), value),
            )
            await db.commit()

    async def get_state(self, key: StorageKey) -> str | None:
        async with aiosqlite.connect(self._path()) as db:
            row = await (
                await db.execute("SELECT state FROM fsm WHERE key=?", (self._key(key),))
            ).fetchone()
            return row[0] if row else None

    async def set_data(self, key: StorageKey, data: Mapping[str, Any]) -> None:
        async with aiosqlite.connect(self._path()) as db:
            await db.execute(
                "INSERT INTO fsm (key, data) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET data=excluded.data",
                (self._key(key), json.dumps(dict(data), ensure_ascii=False)),
            )
            await db.commit()

    async def get_data(self, key: StorageKey) -> dict[str, Any]:
        async with aiosqlite.connect(self._path()) as db:
            row = await (
                await db.execute("SELECT data FROM fsm WHERE key=?", (self._key(key),))
            ).fetchone()
            return json.loads(row[0]) if row and row[0] else {}

    async def close(self) -> None:
        pass
