"""🏗 Учёт объекта: объекты, расходы на материалы, выплаты, этапы со сроками."""
import html

from aiogram import Bot, F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from .. import db
from ..config import PRICES
from ..db import EXPENSE_KINDS
from ..keyboards import (back_to_list_kb, back_to_object_kb, confirm_delete_kb, expenses_kb, object_kb,
                         objects_kb, stages_kb)
from ..objects import fmt_date, money, parse_amount, parse_expense, parse_stage, summary
from ..prompts import OBJECT_ADVICE_SYSTEM
from ..states import Obj
from .helpers import TEXT_OR_VOICE, read_text, run_text_job

router = Router()



async def show(target: Message, text: str, kb, edit: bool):
    if edit:
        try:
            return await target.edit_text(text, reply_markup=kb)
        except Exception:
            pass
    await target.answer(text, reply_markup=kb)


async def object_card(user_id: int, oid: int) -> tuple[str, object] | None:
    obj = await db.get_object(oid, user_id)
    if not obj:
        return None
    text = summary(obj, await db.expense_totals(oid), await db.list_stages(oid))
    return text, object_kb(obj)


async def show_object(target: Message, user_id: int, oid: int, edit: bool = True):
    card = await object_card(user_id, oid)
    if not card:
        return await target.answer("Объект не найден.")
    await show(target, card[0], card[1], edit)


async def owned(cb: CallbackQuery, oid: int) -> dict | None:
    obj = await db.get_object(oid, cb.from_user.id)
    if not obj:
        await cb.answer("Объект не найден", show_alert=True)
    return obj


def ids(data: str) -> list[int]:
    return [int(x) for x in data.split(":")[2:] if x.isdigit()]


# ---------- список ----------

LIST_TEXT = ("🏗 <b>Мои объекты</b>\n\nВедите расходы на материалы, выплаты бригаде и этапы со сроками — "
             "напомню, когда подходит срок. Бесплатно.")


@router.message(Command("objects"))
async def cmd_objects(message: Message, state: FSMContext):
    await state.set_state(None)
    await db.get_or_create_user(message.from_user.id, message.from_user.username)
    objs = await db.list_objects(message.from_user.id)
    await message.answer(LIST_TEXT, reply_markup=objects_kb(objs))


@router.callback_query(F.data == "obj:list")
async def obj_list(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    objs = await db.list_objects(cb.from_user.id)
    await show(cb.message, LIST_TEXT, objects_kb(objs), edit=True)
    await cb.answer()


@router.callback_query(F.data == "obj:archive")
async def obj_archive(cb: CallbackQuery):
    objs = await db.list_objects(cb.from_user.id, archived=True)
    text = "🗄 <b>Архив объектов</b>" if objs else "🗄 В архиве пока пусто."
    await show(cb.message, text, objects_kb(objs), edit=True)
    await cb.answer()


# ---------- новый объект ----------

@router.callback_query(F.data == "obj:new")
async def obj_new(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Obj.new_name)
    await cb.message.edit_text(
        "➕ Как назовём объект? Можно сразу адрес через запятую.\n"
        "Например: <code>Квартира Ивановых, ул. Ленина 5-12</code>",
        reply_markup=back_to_list_kb(),
    )
    await cb.answer()


@router.message(Obj.new_name, TEXT_OR_VOICE)
async def obj_new_name(message: Message, state: FSMContext, bot: Bot):
    text = await read_text(message, bot)
    if not text:
        return
    name, _, address = text.strip().partition(",")
    if not name.strip():
        return await message.answer("Напишите название объекта.")
    oid = await db.create_object(message.from_user.id, name, address)
    await state.set_state(None)
    await message.answer("✅ Объект создан.")
    await show_object(message, message.from_user.id, oid, edit=False)


# ---------- карточка ----------

@router.callback_query(F.data.startswith("obj:open:"))
async def obj_open(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    (oid,) = ids(cb.data)
    if await owned(cb, oid):
        await show_object(cb.message, cb.from_user.id, oid)
        await cb.answer()


# ---------- расходы ----------

@router.callback_query(F.data.startswith("obj:exp:"))
async def obj_expense(cb: CallbackQuery, state: FSMContext):
    parts = cb.data.split(":")
    oid, kind = int(parts[2]), parts[3]
    if not await owned(cb, oid):
        return
    await state.set_state(Obj.expense)
    await state.update_data(oid=oid, kind=kind)
    await cb.message.edit_text(
        f"{EXPENSE_KINDS.get(kind, '📦 Прочее')}: напишите или надиктуйте сумму и за что.\n"
        "Например: <code>12 500 плитка в ванную</code> или <code>аванс Сергею 30к</code>\n"
        "Можно несколько строк — каждая станет отдельной записью.",
        reply_markup=back_to_object_kb(oid),
    )
    await cb.answer()


@router.message(Obj.expense, TEXT_OR_VOICE)
async def obj_expense_input(message: Message, state: FSMContext, bot: Bot):
    data = await state.get_data()
    oid, kind = data.get("oid"), data.get("kind")
    if not oid or not await db.get_object(oid, message.from_user.id):
        await state.set_state(None)
        return await message.answer("Объект не найден. /objects")
    text = await read_text(message, bot)
    if not text:
        return
    added = []
    for line in [l for l in text.splitlines() if l.strip()]:
        parsed = parse_expense(line, kind)
        if parsed:
            _, amount, note = parsed
            await db.add_expense(oid, kind, amount, note)
            added.append(f"• {money(amount)} {html.escape(note)}")
    if not added:
        return await message.answer("Не нашёл сумму 🤔 Напишите, например: <code>12 500 плитка</code>")
    await state.set_state(None)
    await message.answer("✅ Записал:\n" + "\n".join(added))
    await show_object(message, message.from_user.id, oid, edit=False)


async def render_history(target: Message, oid: int):
    items = await db.list_expenses(oid, limit=30)
    if not items:
        return await show(target, "🧾 Расходов пока нет.", back_to_object_kb(oid), edit=True)
    lines = ["🧾 <b>Последние расходы</b>\n"]
    for e in items:
        lines.append(f"{e['created_at'][8:10]}.{e['created_at'][5:7]} "
                     f"{EXPENSE_KINDS.get(e['kind'], '')[:1]} {money(e['amount'])} {html.escape(e['note'] or '')}")
    lines.append("\nЧтобы удалить ошибочную запись — нажмите на неё ниже.")
    await show(target, "\n".join(lines), expenses_kb(oid, items), edit=True)


@router.callback_query(F.data.startswith("obj:hist:"))
async def obj_history(cb: CallbackQuery):
    (oid,) = ids(cb.data)
    if not await owned(cb, oid):
        return
    await render_history(cb.message, oid)
    await cb.answer()


@router.callback_query(F.data.startswith("obj:rmexp:"))
async def obj_rm_expense(cb: CallbackQuery):
    oid, eid = ids(cb.data)
    if not await owned(cb, oid):
        return
    await db.delete_expense(eid, cb.from_user.id)
    await cb.answer("Удалено")
    await render_history(cb.message, oid)


# ---------- бюджет ----------

@router.callback_query(F.data.startswith("obj:budget:"))
async def obj_budget(cb: CallbackQuery, state: FSMContext):
    (oid,) = ids(cb.data)
    if not await owned(cb, oid):
        return
    await state.set_state(Obj.budget)
    await state.update_data(oid=oid)
    await cb.message.edit_text("💰 Какой бюджет у объекта? Например: <code>850 000</code> или <code>1.2 млн</code>",
                               reply_markup=back_to_object_kb(oid))
    await cb.answer()


@router.message(Obj.budget, TEXT_OR_VOICE)
async def obj_budget_input(message: Message, state: FSMContext, bot: Bot):
    oid = (await state.get_data()).get("oid")
    if not oid or not await db.get_object(oid, message.from_user.id):
        await state.set_state(None)
        return await message.answer("Объект не найден. /objects")
    text = await read_text(message, bot)
    if not text:
        return
    amount = parse_amount(text)
    if amount is None:
        return await message.answer("Не понял сумму 🤔 Например: <code>850 000</code>")
    await db.update_object(oid, message.from_user.id, budget=amount)
    await state.set_state(None)
    await show_object(message, message.from_user.id, oid, edit=False)


# ---------- этапы ----------

@router.callback_query(F.data.startswith("obj:stage:"))
async def obj_stage(cb: CallbackQuery, state: FSMContext):
    (oid,) = ids(cb.data)
    if not await owned(cb, oid):
        return
    await state.set_state(Obj.stage)
    await state.update_data(oid=oid)
    await cb.message.edit_text(
        "➕ Этап и срок. Можно несколько строк:\n"
        "<code>Демонтаж до 05.10\nЭлектрика до 12.10\nПлитка в ванной до 25.10</code>\n\n"
        "В день срока пришлю напоминание.",
        reply_markup=back_to_object_kb(oid),
    )
    await cb.answer()


@router.message(Obj.stage, TEXT_OR_VOICE)
async def obj_stage_input(message: Message, state: FSMContext, bot: Bot):
    oid = (await state.get_data()).get("oid")
    if not oid or not await db.get_object(oid, message.from_user.id):
        await state.set_state(None)
        return await message.answer("Объект не найден. /objects")
    text = await read_text(message, bot)
    if not text:
        return
    added = []
    for line in [l for l in text.splitlines() if l.strip()]:
        name, due = parse_stage(line)
        await db.add_stage(oid, name, due)
        added.append(f"• {html.escape(name)}" + (f" — до {fmt_date(due)}" if due else ""))
    await state.set_state(None)
    await message.answer("✅ Добавил этапы:\n" + "\n".join(added))
    await show_object(message, message.from_user.id, oid, edit=False)


async def render_stages(target: Message, oid: int):
    stages = await db.list_stages(oid)
    text = "Нажмите на этап, чтобы отметить выполненным (или снять отметку)." if stages \
        else "Этапов пока нет — добавьте кнопкой «➕ Этап»."
    await show(target, text, stages_kb(oid, stages), edit=True)


@router.callback_query(F.data.startswith("obj:stages:"))
async def obj_stages(cb: CallbackQuery):
    (oid,) = ids(cb.data)
    if not await owned(cb, oid):
        return
    await render_stages(cb.message, oid)
    await cb.answer()


@router.callback_query(F.data.startswith("obj:tgl:"))
async def obj_toggle_stage(cb: CallbackQuery):
    oid, sid = ids(cb.data)
    if not await owned(cb, oid):
        return
    stage = next((s for s in await db.list_stages(oid) if s["id"] == sid), None)
    if stage:
        await db.set_stage_done(sid, cb.from_user.id, not stage["done"])
    await render_stages(cb.message, oid)
    await cb.answer("✅ Готово" if stage and not stage["done"] else "Отметка снята")


# ---------- советы, архив, удаление ----------

@router.callback_query(F.data.startswith("obj:advice:"))
async def obj_advice(cb: CallbackQuery, bot: Bot):
    (oid,) = ids(cb.data)
    obj = await owned(cb, oid)
    if not obj:
        return
    await cb.answer()
    card = summary(obj, await db.expense_totals(oid), await db.list_stages(oid))
    expenses = await db.list_expenses(oid, limit=30)
    detail = "\n".join(f"{e['kind']}: {e['amount']} ₽ {e['note'] or ''}" for e in expenses)
    await cb.message.answer(f"🧠 Советы прораба по объекту — {PRICES['advice']} кр.")
    await run_text_job(cb.message, cb.from_user.id, "advice", OBJECT_ADVICE_SYSTEM,
                       f"{card}\n\nПоследние расходы:\n{detail or 'нет'}", bot=bot)


@router.callback_query(F.data.startswith("obj:arch:"))
async def obj_arch(cb: CallbackQuery):
    (oid,) = ids(cb.data)
    obj = await owned(cb, oid)
    if not obj:
        return
    await db.update_object(oid, cb.from_user.id, archived=0 if obj["archived"] else 1)
    await cb.answer("Вернул из архива" if obj["archived"] else "Убрал в архив")
    await show_object(cb.message, cb.from_user.id, oid)


@router.callback_query(F.data.startswith("obj:del:"))
async def obj_del(cb: CallbackQuery):
    (oid,) = ids(cb.data)
    obj = await owned(cb, oid)
    if not obj:
        return
    await cb.message.edit_text(
        f"Удалить объект «{html.escape(obj['name'])}» со всеми расходами и этапами? Это не отменить.",
        reply_markup=confirm_delete_kb(oid),
    )
    await cb.answer()


@router.callback_query(F.data.startswith("obj:del!:"))
async def obj_del_confirm(cb: CallbackQuery, state: FSMContext):
    oid = int(cb.data.split(":")[2])
    await db.delete_object(oid, cb.from_user.id)
    await state.set_state(None)
    await show(cb.message, LIST_TEXT, objects_kb(await db.list_objects(cb.from_user.id)), edit=True)
    await cb.answer("Удалено")
