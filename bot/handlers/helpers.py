"""Общие помощники для обработчиков: длинные ответы, голос → текст, платные задачи, рефералка."""
import html
import logging

from aiogram import Bot, F
from aiogram.types import Message

from .. import db, kie
from ..config import PRICES, REFERRAL_BONUS, VOICE_MAX_SECONDS
from ..keyboards import home_kb, packs_kb

log = logging.getLogger(__name__)

ERROR_TEXT = "😔 Не получилось, кредиты вернул на баланс. Попробуйте ещё раз чуть позже."


async def send_long(message: Message, text: str, **kw):
    """Отправляет длинный текст частями; если модель сломала HTML — шлёт без разметки."""
    chunks = [text[i:i + 3900] for i in range(0, len(text), 3900)] or [""]
    for i, chunk in enumerate(chunks):
        extra = kw if i == len(chunks) - 1 else {}
        try:
            await message.answer(chunk, **extra)
        except Exception:
            await message.answer(chunk, parse_mode=None, **extra)


async def not_enough(message: Message, need: int):
    await message.answer(
        f"Не хватает кредитов: нужно {need}. Пополните баланс 👇", reply_markup=packs_kb()
    )


async def photo_url(message: Message, bot: Bot) -> str:
    """Скачивает самое большое фото из сообщения и загружает в kie.ai."""
    buf = await bot.download(message.photo[-1].file_id)
    return await kie.upload_image(buf.read(), f"{message.from_user.id}_{message.message_id}.jpg")


async def read_text(message: Message, bot: Bot, echo: bool = True) -> str | None:
    """Текст сообщения или распознанное голосовое. None — если распознать не удалось."""
    if message.text:
        return message.text
    media = message.voice or message.audio
    if not media:
        return None
    if (media.duration or 0) > VOICE_MAX_SECONDS:
        await message.answer(f"🎙 Слишком длинное голосовое. До {VOICE_MAX_SECONDS // 60} минут, пожалуйста.")
        return None
    wait = await message.answer("🎙 Слушаю…")
    try:
        buf = await bot.download(media.file_id)
        mime = getattr(media, "mime_type", None) or "audio/ogg"
        text = await kie.transcribe(buf.read(), f"{message.from_user.id}_{message.message_id}.ogg", mime)
    except Exception:
        log.exception("transcribe failed")
        await wait.edit_text("😔 Не удалось распознать голосовое. Попробуйте ещё раз или напишите текстом.")
        return None
    if echo:
        await wait.edit_text(f"🎙 <i>{html.escape(text[:1000])}</i>")
    else:
        await wait.delete()
    return text


async def after_paid_success(bot: Bot, user_id: int) -> None:
    """Первая успешная платная задача приглашённого → бонус пригласившему."""
    try:
        referrer = await db.reward_referrer(user_id, REFERRAL_BONUS)
        if referrer:
            await bot.send_message(
                referrer, f"🎁 Ваш друг начал пользоваться ботом — вам +{REFERRAL_BONUS} кредита!"
            )
    except Exception:
        log.exception("referral reward failed")


async def run_text_job(message: Message, user_id: int, kind: str, system: str, text: str,
                       image_url: str | None = None, cost: int | None = None,
                       bot: Bot | None = None) -> bool:
    """Списывает кредиты, вызывает текстовую модель, при ошибке возвращает кредиты.
    Возвращает True, если ответ отправлен."""
    cost = PRICES[kind] if cost is None else cost
    job_id = None
    if cost:
        job_id = await db.charge(user_id, cost, kind)
        if job_id is None:
            await not_enough(message, cost)
            return False
    wait = await message.answer("⏳ Думаю…")
    try:
        answer = await kie.chat(system, text, image_url=image_url)
    except Exception:
        log.exception("text job %s failed", kind)
        if job_id:
            await db.finish_job(job_id, ok=False)
        try:
            await wait.edit_text(ERROR_TEXT, reply_markup=home_kb())
        except Exception:
            await message.answer(ERROR_TEXT, reply_markup=home_kb())
        return False
    if job_id:
        await db.finish_job(job_id, ok=True)
        if bot:
            await after_paid_success(bot, user_id)
    try:
        await wait.delete()
    except Exception:
        pass
    await send_long(message, answer, reply_markup=home_kb())
    return True


# Текст (кроме команд) или голосовое — для шагов, где ждём ввод пользователя
TEXT_OR_VOICE = (F.text & ~F.text.startswith("/")) | F.voice | F.audio
