"""Старт, роли, меню, баланс, оплата Telegram Stars, рефералка, поддержка, админ-команды."""
import html
import logging

from aiogram import Bot, F, Router
from aiogram.filters import Command, CommandObject, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import (CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, LabeledPrice, Message,
                           PreCheckoutQuery)

from .. import db
from ..config import PACKS, PRICES, REFERRAL_BONUS, config
from ..keyboards import ROLES, home_kb, main_menu, packs_kb, roles_kb

log = logging.getLogger(__name__)
router = Router()


def plural(n: int, one: str, few: str, many: str) -> str:
    """plural(3, 'кредит', 'кредита', 'кредитов') → 'кредита'."""
    n = abs(n) % 100
    if 11 <= n <= 19:
        return many
    n %= 10
    return one if n == 1 else few if 2 <= n <= 4 else many


def credits_word(n: int) -> str:
    return f"{n} {plural(n, 'кредит', 'кредита', 'кредитов')}"


WELCOME = (
    "👋 <b>Привет! Я СтройБот — помощник по ремонту и стройке.</b>\n\n"
    "Покажу, как будет выглядеть комната после ремонта, посчитаю материалы, "
    "составлю смету и проверю работу бригады по фото. Понимаю голосовые 🎙.\n\n"
    "🎁 Дарю <b>{credits}</b> на старт. Кто вы?"
)


def menu_text(user: dict) -> str:
    role = ROLES.get(user.get("role") or "", "")
    return (
        f"<b>Главное меню</b> {('· ' + role) if role else ''}\n"
        f"💰 Баланс: <b>{user['credits']}</b> кр.\n\n"
        f"Стоимость: дизайн — {PRICES['design']} кр., проверка/смета/КП/отчёт — 1 кр., "
        f"калькулятор и учёт объектов — бесплатно."
    )


def parse_ref(args: str | None) -> int | None:
    """'ref_123' → 123."""
    if args and args.startswith("ref_") and args[4:].isdigit():
        return int(args[4:])
    return None


@router.message(CommandStart())
async def start(message: Message, command: CommandObject, state: FSMContext):
    await state.clear()
    user = await db.get_or_create_user(
        message.from_user.id, message.from_user.username, referrer_id=parse_ref(command.args)
    )
    if not user.get("role"):
        await message.answer(WELCOME.format(credits=credits_word(user["credits"])), reply_markup=roles_kb())
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
    if role not in ROLES:
        return await cb.answer()
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
    # сохраняем последнее фото и стиль дизайна, сбрасываем только сценарий
    await state.set_state(None)
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
        f"💰 Баланс: <b>{credits_word(user['credits'])}</b>.\n\nПополнить через Telegram Stars:",
        reply_markup=packs_kb(),
    )
    await cb.answer()


# ---------- 🎁 рефералка ----------

@router.callback_query(F.data == "menu:invite")
async def invite(cb: CallbackQuery, bot: Bot):
    me = await bot.me()
    link = f"https://t.me/{me.username}?start=ref_{cb.from_user.id}"
    invited, rewarded = await db.referral_stats(cb.from_user.id)
    await cb.message.edit_text(
        "🎁 <b>Пригласите друга</b>\n\n"
        f"Отправьте ему ссылку. Когда друг впервые воспользуется платной функцией, "
        f"вам начислится <b>+{credits_word(REFERRAL_BONUS)}</b>. "
        f"Друг тоже получит {credits_word(config.welcome_credits)} на старт.\n\n"
        f"Ваша ссылка:\n<code>{link}</code>\n\n"
        f"Приглашено: {invited}, бонусов получено: {rewarded}.",
        reply_markup=home_kb(),
    )
    await cb.answer()


# ---------- ⭐ оплата ----------

@router.callback_query(F.data.startswith("buy:"))
async def buy(cb: CallbackQuery):
    pid = cb.data.split(":", 1)[1]
    pack = next((p for p in PACKS if p[0] == pid), None)
    if not pack:
        return await cb.answer("Пакет не найден", show_alert=True)
    _, credits, stars = pack
    await cb.message.answer_invoice(
        title=f"{credits} кредитов СтройБота",
        description="Кредиты на дизайн по фото, сметы, проверку работ, КП и фотоотчёты.",
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
        log.error("payment for unknown pack %s, charge %s", pid, sp.telegram_payment_charge_id)
        return
    added = await db.record_payment(
        message.from_user.id, sp.total_amount, pack[1], sp.telegram_payment_charge_id
    )
    user = await db.get_user(message.from_user.id)
    if added:
        await message.answer(
            f"✅ Оплата прошла! Начислено <b>{credits_word(pack[1])}</b>. Баланс: <b>{user['credits']}</b>.",
            reply_markup=main_menu(user.get("role")),
        )


@router.message(Command("paysupport"))
async def cmd_paysupport(message: Message, command: CommandObject, bot: Bot):
    """Обязательная по правилам Telegram команда поддержки платежей.
    /paysupport текст — пересылает обращение администраторам."""
    if command.args:
        u = message.from_user
        sent = 0
        for admin in config.admin_ids:
            try:
                await bot.send_message(
                    admin,
                    f"🛟 Обращение по оплате от {html.escape(u.full_name)} "
                    f"(@{html.escape(u.username or '—')}, id <code>{u.id}</code>):\n\n"
                    f"{html.escape(command.args)}\n\nОтветить: <code>/reply {u.id} текст</code>",
                )
                sent += 1
            except Exception:
                log.exception("paysupport forward failed")
        return await message.answer(
            "✅ Передал ваше сообщение. Ответим здесь, в боте." if sent
            else "😔 Не получилось передать сообщение, попробуйте позже.",
            reply_markup=home_kb(),
        )
    payments = await db.last_payments(message.from_user.id)
    contact = (f"Напишите нам: {html.escape(config.support_contact)}\nили отправьте "
               if config.support_contact else "Отправьте ")
    lines = [
        "🛟 <b>Поддержка по оплате</b>\n",
        f"{contact}команду <code>/paysupport ваш вопрос</code> — я передам его администратору. "
        "Укажите, что случилось, и код платежа.",
        "Возврат звёзд возможен, если кредиты из покупки ещё не потрачены.",
    ]
    if payments:
        lines.append("\n<b>Ваши последние платежи:</b>")
        for p in payments:
            mark = " (возвращён)" if p.get("refunded") else ""
            lines.append(f"• {p['created_at'][:10]} — {p['stars']} ⭐ → {p['credits']} кр.{mark}\n"
                         f"  <code>{html.escape(p['charge_id'])}</code>")
    await message.answer("\n".join(lines), reply_markup=home_kb())


@router.message(Command("terms"))
async def cmd_terms(message: Message):
    await message.answer(
        "📜 <b>Условия</b>\n\n"
        "• Кредиты покупаются за Telegram Stars и тратятся на функции бота. Цены указаны в меню.\n"
        "• Если функция не сработала, кредиты возвращаются автоматически.\n"
        "• Сметы, КП, проверки и советы — ориентировочные и не заменяют специалиста на объекте.\n"
        "• Картинки дизайна — визуализация идеи, а не проект.\n"
        "• Вопросы по оплате — /paysupport.",
        reply_markup=home_kb(),
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
        f"<b>Статистика</b>\nПользователей: {s['users']} (по приглашению: {s['referred']})\n"
        f"Звёзд получено: {s['stars']}\nОбъектов: {s['objects']}\n"
        f"Успешных задач: {s['jobs']}\n{kinds}"
    )


@router.message(Command("give"))
async def cmd_give(message: Message, command: CommandObject, bot: Bot):
    """/give <user_id> <кредиты> — начислить кредиты (можно отрицательное число).
    /give <кредиты> — начислить себе."""
    if not is_admin(message):
        return
    parts = (command.args or "").split()
    try:
        if len(parts) == 1:
            uid, amount = message.from_user.id, int(parts[0])
        else:
            uid, amount = (int(x) for x in parts)
    except ValueError:
        return await message.answer("Формат: /give количество (себе) или /give user_id количество")
    if not await db.get_user(uid):
        return await message.answer("Пользователь не найден (он должен сначала нажать /start)")
    new = await db.add_credits(uid, amount)
    await message.answer(f"Готово. Баланс {uid}: {new}")
    if amount > 0:
        try:
            await bot.send_message(uid, f"🎁 Вам начислено {credits_word(amount)}. Баланс: {new}")
        except Exception:
            pass


@router.message(Command("refund"))
async def cmd_refund(message: Message, command: CommandObject, bot: Bot):
    """/refund <код платежа> — вернуть звёзды и списать кредиты из этой покупки."""
    if not is_admin(message):
        return
    charge_id = (command.args or "").strip()
    if not charge_id:
        return await message.answer("Формат: /refund код_платежа (пользователь видит его в /paysupport)")
    payment = await db.get_payment(charge_id)
    if not payment:
        return await message.answer("Платёж не найден")
    if payment.get("refunded"):
        return await message.answer("Этот платёж уже возвращён")
    try:
        await bot.refund_star_payment(user_id=payment["user_id"], telegram_payment_charge_id=charge_id)
    except Exception as e:
        return await message.answer(f"Telegram не принял возврат: {html.escape(str(e))}")
    await db.mark_refunded(charge_id)
    await message.answer(f"✅ Вернул {payment['stars']} ⭐ пользователю {payment['user_id']}, "
                         f"списал {payment['credits']} кр.")
    try:
        await bot.send_message(payment["user_id"], f"↩️ Возврат {payment['stars']} ⭐ оформлен.")
    except Exception:
        pass


@router.message(Command("reply"))
async def cmd_reply(message: Message, command: CommandObject, bot: Bot):
    """/reply <user_id> <текст> — ответить пользователю от имени бота."""
    if not is_admin(message):
        return
    parts = (command.args or "").split(maxsplit=1)
    if len(parts) < 2 or not parts[0].isdigit():
        return await message.answer("Формат: /reply user_id текст ответа")
    try:
        await bot.send_message(int(parts[0]), f"💬 <b>Ответ поддержки:</b>\n{html.escape(parts[1])}")
    except Exception as e:
        return await message.answer(f"Не доставлено: {html.escape(str(e))}")
    await message.answer("✅ Отправлено")


@router.message(Command("scanner"))
async def cmd_scanner(message: Message):
    """Подключить приложение СтройСкан (LiDAR на iPhone Pro) к аккаунту."""
    code = await db.create_scan_code(message.from_user.id)
    text = ("📐 <b>СтройСкан: замер комнаты лидаром iPhone</b>\n\n"
            "1. Установите приложение СтройСкан на iPhone Pro (инструкция в папке ios проекта).\n"
            f"2. Откройте его и введите код <code>{code}</code>"
            + (f" и адрес <code>{config.webapp_url}</code>" if config.webapp_url else "") + ".\n"
            "Код действует 10 минут. После подключения сканы комнат будут приходить сюда.")
    kb = None
    if config.webapp_url.startswith("https://"):
        kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(
            text="📲 Подключить iPhone", url=f"{config.webapp_url}/scan/link?c={code}")]])
    await message.answer(text, reply_markup=kb)


@router.message(Command("help"))
async def cmd_help(message: Message):
    await message.answer(
        "Команды: /start — начало, /menu — меню, /objects — мои объекты, "
        "/report — фотоотчёт, /scanner — LiDAR-сканер на iPhone, /paysupport — помощь с оплатой, /terms — условия.\n"
        "Можно отправлять голосовые 🎙 — я их распознаю.",
        reply_markup=home_kb(),
    )
