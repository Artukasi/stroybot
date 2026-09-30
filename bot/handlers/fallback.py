"""Сообщения вне сценария: предлагаем, что с ними сделать."""
from aiogram import Bot, F, Router
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from ..keyboards import home_kb, use_text_kb
from ..states import Flow
from . import tools
from .helpers import read_text

router = Router()


@router.message(F.text.startswith("/"))
async def unknown_command(message: Message):
    await message.answer("Не знаю такой команды 🤔 Список команд — /help", reply_markup=home_kb())


@router.message(F.text | F.voice | F.audio)
async def free_text(message: Message, state: FSMContext, bot: Bot):
    text = await read_text(message, bot)
    if not text:
        return
    await state.set_state(None)
    await state.update_data(pending_text=text)
    await message.answer("Что сделать с этим сообщением? 👇", reply_markup=use_text_kb())


@router.callback_query(F.data.startswith("use:"))
async def use_text(cb: CallbackQuery, state: FSMContext, bot: Bot):
    action = cb.data.split(":", 1)[1]
    text = (await state.get_data()).get("pending_text")
    await cb.answer()
    if not text:
        return await cb.message.answer("Сообщение потерялось, пришлите ещё раз.", reply_markup=home_kb())
    await state.update_data(pending_text=None)
    try:
        await cb.message.edit_reply_markup(reply_markup=None)
    except Exception:
        pass
    if action == "consult":
        await state.set_state(Flow.consult)
        await tools.consult_do(cb.message, bot, cb.from_user.id, text)
    elif action == "estimate":
        await state.set_state(Flow.estimate)
        await tools.estimate_do(cb.message, state, bot, cb.from_user.id, text)


@router.message(F.photo)
async def photo_without_mode(message: Message):
    await message.answer("Что сделать с фото? Выберите в меню «Дизайн по фото», «Проверить работу» "
                         "или «Фотоотчёт» → /menu")
