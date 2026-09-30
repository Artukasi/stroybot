"""Проверка настроек на живых ключах: python -m bot.check
Смотрит токен Telegram, ключ kie.ai (баланс и один короткий ответ модели) и адрес Mini App."""
import asyncio
import sys

import aiohttp

from . import kie
from .config import config

OK, BAD = "  [ok] ", "  [!!] "


async def check_telegram() -> bool:
    if not config.bot_token:
        print(BAD + "BOT_TOKEN пустой")
        return False
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"https://api.telegram.org/bot{config.bot_token}/getMe") as r:
                body = await r.json(content_type=None)
    except Exception as e:
        print(BAD + f"Нет связи с Telegram: {e}")
        return False
    if not body.get("ok"):
        print(BAD + f"Telegram не принял токен: {body.get('description')}")
        return False
    print(OK + f"Бот @{body['result']['username']} на связи")
    if not config.admin_ids:
        print(BAD + "ADMIN_IDS пустой: не будет админ-команд")
    return True


async def check_kie() -> bool:
    if not config.kie_api_key:
        print(BAD + "KIE_API_KEY пустой")
        return False
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"{kie.API}/api/v1/chat/credit", headers=kie._headers()) as r:
                body = await r.json(content_type=None)
        if body.get("code") == 200:
            print(OK + f"kie.ai: ключ принят, баланс {body.get('data')} кредитов")
        else:
            print(BAD + f"kie.ai ответил на запрос баланса: {body.get('msg') or body}")
    except Exception as e:  # баланс — не главное, смотрим, отвечает ли модель
        print(BAD + f"Не удалось узнать баланс kie.ai: {e}")
    try:
        answer = await kie.chat("Отвечай одним словом.", "Скажи: готово", max_tokens=200)
        print(OK + f"Текстовая модель {config.text_model} ответила: {answer.strip()[:60]}")
        return True
    except Exception as e:
        print(BAD + f"Текстовая модель не ответила: {e}")
        return False


def check_webapp() -> None:
    if config.webapp_url.startswith("https://"):
        print(OK + f"Mini App будет по адресу {config.webapp_url}/app/")
    else:
        print("  [--] WEBAPP_URL не задан: бот работает, кнопки «Приложение» не будет")


async def main() -> int:
    print("Проверяю настройки СтройБота…")
    tg = await check_telegram()
    ai = await check_kie()
    check_webapp()
    return 0 if tg and ai else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
