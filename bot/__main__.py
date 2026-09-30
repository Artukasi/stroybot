import asyncio
import html
import logging
from datetime import datetime

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.types import BotCommand, MenuButtonDefault, MenuButtonWebApp, WebAppInfo

from . import db
from .config import config
from .handlers import setup
from .keyboards import back_to_object_kb
from .objects import fmt_date
from .storage import SQLiteStorage

log = logging.getLogger("stroybot")

REMIND_FROM_HOUR = 9  # не будим людей ночью

# Профиль бота в Telegram: ставим сами при запуске, чтобы не заполнять вручную в @BotFather
DESCRIPTION = (
    "Помощник по ремонту. Покажет дизайн комнаты по фото, посчитает смету и материалы, "
    "проверит работу бригады по фото, соберёт фотоотчёт в PDF и поможет вести объекты.\n\n"
    "Можно писать текстом или голосом. Нажмите «Старт»."
)
SHORT_DESCRIPTION = "Ремонт без нервов: дизайн по фото, смета, проверка работы бригады, фотоотчёты."


async def remind_loop(bot: Bot):
    """Раз в полчаса напоминает о этапах, у которых наступил срок."""
    while True:
        try:
            now = datetime.now()
            if now.hour >= REMIND_FROM_HOUR:
                for s in await db.due_stages(now.date().isoformat()):
                    try:
                        await bot.send_message(
                            s["owner_id"],
                            f"⏰ <b>Срок этапа</b>: {html.escape(s['name'])} — до {fmt_date(s['due'])}\n"
                            f"Объект: {html.escape(s['object_name'])}\n\n"
                            "Если этап готов — отметьте его в объекте.",
                            reply_markup=back_to_object_kb(s["object_id"]),
                        )
                    except Exception:
                        log.warning("reminder to %s failed", s["owner_id"])
                    await db.mark_reminded(s["id"])
        except Exception:
            log.exception("remind loop error")
        await asyncio.sleep(1800)


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if not config.bot_token or not config.kie_api_key:
        raise SystemExit("Заполните BOT_TOKEN и KIE_API_KEY в файле .env")
    await db.init_db()
    bot = Bot(config.bot_token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    await bot.set_my_commands([
        BotCommand(command="start", description="Начать"),
        BotCommand(command="menu", description="Главное меню"),
        BotCommand(command="objects", description="Мои объекты"),
        BotCommand(command="report", description="Фотоотчёт в PDF"),
        BotCommand(command="scanner", description="LiDAR-сканер на iPhone"),
        BotCommand(command="paysupport", description="Помощь с оплатой"),
        BotCommand(command="terms", description="Условия"),
    ])

    try:
        await bot.set_my_description(DESCRIPTION)
        await bot.set_my_short_description(SHORT_DESCRIPTION)
    except Exception:
        log.warning("не удалось обновить описание бота", exc_info=True)

    runner = None
    if config.webapp_url.startswith("https://"):
        from .web import start_web
        runner = await start_web(bot)
        await bot.set_chat_menu_button(menu_button=MenuButtonWebApp(
            text="Приложение", web_app=WebAppInfo(url=f"{config.webapp_url}/app/")))
    else:
        await bot.set_chat_menu_button(menu_button=MenuButtonDefault())
        log.info("WEBAPP_URL не задан — Mini App выключен, работает только бот")

    dp = Dispatcher(storage=SQLiteStorage())
    dp.include_router(setup())
    reminders = asyncio.create_task(remind_loop(bot))
    try:
        await dp.start_polling(bot)
    finally:
        reminders.cancel()
        if runner:
            await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
