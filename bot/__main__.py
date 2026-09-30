import asyncio
import logging

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.types import BotCommand

from . import db
from .config import config
from .handlers import setup


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if not config.bot_token or not config.kie_api_key:
        raise SystemExit("Заполните BOT_TOKEN и KIE_API_KEY в файле .env")
    await db.init_db()
    bot = Bot(config.bot_token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    await bot.set_my_commands([
        BotCommand(command="start", description="Начать"),
        BotCommand(command="menu", description="Главное меню"),
    ])
    dp = Dispatcher()
    dp.include_router(setup())
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
