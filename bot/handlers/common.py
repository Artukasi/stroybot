"""Старт, роли, меню, баланс, оплата Telegram Stars, админ-команды."""
from aiogram import Bot, F, Router
from aiogram.filters import Command, CommandObject, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, LabeledPrice, Message, PreCheckoutQuery

from .. import db
from ..config import PACKS, PRICES, config
from ..keyboards import ROLES, home_kb, main_menu, packs_kb, roles_kb

router = Router()

WELCOME = (
    "👋 <b>Привет! Я СтройБот — помощник по ремонту и стройке.</b>\n\n"
    "Покажу, как будет выглядеть комната после ремонта, посчитаю материалы, "
    "составлю смету и проверю работу бригады по фото.\n\n"
    "🎁 Дарю <b>{credits} кредита</b> на старт. Кто вы?"
)


def menu_text(user: dict) -> str:
    role = ROLES.get(user.get("role") or "", "")
    return (
        f"<b>Главное меню</b> {('· ' + role) if role else ''}\n"
        f"💰 Баланс: <b>{user['credits']}</b> кр.\n\n"
        f"Стоимость: дизайн — {PRICES['design']} кр., проверка/смета/КП — 1 кр., "
        f"калькулятор — бесплатно."
    )


@router.message(CommandStart())
async def start(message: Message, state: FSMContext):
    await state.clear()
    user = await db.get_or_create_user(message.from_user.id, message.from_user.username)
    if not user.get("role"):
        await message.answer(WELCOME.format(credits=user["credits"]), reply_markup=roles_kb())
    else:
        await message.answer(menu_text(user), reply_markup=main_menu(user["role"]))


@router.message(Command("menu"))
async def cmd_menu(message: Message, state: FSMContext):
    await state.clear()
    user = await db.get_or_create_user(message.from_user.id, message.from_user.username)
    await message.answer(menu_text(user), reply_markup=main_menu(user.get("role")))


@router.callback_query(F.data.startswith("role:"))
async def pick_role(cb: CallbackQuery, state: FSMContext):
    role = cb.data.split(":", 1)[1]
    await db.get_or_create_user(cb.from_user.id, cb.from_user.username)
    await db.set_role(cb.from_user.id, role)
    user = await db.get_user(cb.from_user.id)
    await state.clear()
    await cb.message.edit_text(menu_text(user), reply_markup=main_menu(role))
    await cb.answer()


@router.callback_query(F.data == "menu:role")
async def change_role(cb: CallbackQuery):
    await cb.message.edit_text("Кто вы?", reply_markup=roles_kb())
    await cb.answer()


@router.callback_query(F.data == "menu:home")
async def home(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    user = await db.get_or_create_user(cb.from_user.id, cb.from_user.username)
    try:
        await cb.message.edit_text(menu_text(user), reply_markup=main_menu(user.get("role")))
    except Exception:
        await cb.message.answer(menu_text(user), reply_markup=main_menu(user.get("role")))
    await cb.answer()


@router.callback_query(F.data == "menu:balance")
async def balance(cb: CallbackQuery):
    user = await db.get_or_create_user(cb.from_user.id, cb.from_user.username)
    await cb.message.edit_text(
        f"💰 Баланс: <b>{user['credits']}</b> кредитов.\n\nПополнить через Telegram Stars:",
        reply_markup=packs_kb(),
    )
    await cb.answer()


@router.callback_query(F.data.startswith("buy:"))
async def buy(cb: CallbackQuery):
    pid = cb.data.split(":", 1)[1]
    pack = next((p for p in PACKS if p[0] == pid), None)
    if not pack:
        return await cb.answer("Пакет не найден", show_alert=True)
    _, credits, stars = pack
    await cb.message.answer_invoice(
        title=f"{credits} кредитов СтройБота",
        description="Кредиты на дизайн по фото, сметы, проверку работ и КП.",
        payload=f"pack:{pid}",
        currency="XTR",
        prices=[LabeledPrice(label=f"{credits} кредитов", amount=stars)],
        provider_token="",
    )
    await cb.answer()


@router.pre_checkout_query()
async def pre_checkout(q: PreCheckoutQuery):
    ok = q.invoice_payload.startswith("pack:") and any(
        p[0] == q.invoice_payload[5:] for p in PACKS
    )
    await q.answer(ok=ok, error_message=None if ok else "Пакет не найден")


@router.message(F.successful_payment)
async def paid(message: Message):
    sp = message.successful_payment
    pid = sp.invoice_payload[5:]
    pack = next((p for p in PACKS if p[0] == pid), None)
    if not pack:
        return
    added = await db.record_payment(
        message.from_user.id, sp.total_amount, pack[1], sp.telegram_payment_charge_id
    )
    user = await db.get_user(message.from_user.id)
    if added:
        await message.answer(
            f"✅ Оплата прошла! Начислено <b>{pack[1]}</b> кредитов. Баланс: <b>{user['credits']}</b>.",
            reply_markup=main_menu(user.get("role")),
        )


# ---------- админка ----------

def is_admin(message: Message) -> bool:
    return message.from_user.id in config.admin_ids


@router.message(Command("stats"))
async def cmd_stats(message: Message):
    if not is_admin(message):
        return
    s = await db.stats()
    kinds = "\n".join(f"  {k}: {v}" for k, v in s["by_kind"].items()) or "  —"
    await message.answer(
        f"<b>Статистика</b>\nПользователей: {s['users']}\nЗвёзд получено: {s['stars']}\n"
        f"Успешных задач: {s['jobs']}\n{kinds}"
    )


@router.message(Command("give"))
async def cmd_give(message: Message, command: CommandObject, bot: Bot):
    """/give <user_id> <кредиты> — начислить кредиты (можно отрицательное число)."""
    if not is_admin(message):
        return
    try:
        uid, amount = (int(x) for x in (command.args or "").split())
    except ValueError:
        return await message.answer("Формат: /give user_id количество")
    if not await db.get_user(uid):
        return await message.answer("Пользователь не найден (он должен сначала нажать /start)")
    new = await db.add_credits(uid, amount)
    await message.answer(f"Готово. Баланс {uid}: {new}")
    if amount > 0:
        try:
            await bot.send_message(uid, f"🎁 Вам начислено {amount} кредитов. Баланс: {new}")
        except Exception:
            pass


@router.message(Command("help"))
async def cmd_help(message: Message):
    await message.answer(
        "Команды: /start — начало, /menu — меню.\nВопросы и предложения — пишите администратору.",
        reply_markup=home_kb(),
    )
