from aiogram.types import InlineKeyboardButton as B, InlineKeyboardMarkup as M, WebAppInfo

from .calc import CALCS
from .config import PACKS, config
from .db import EXPENSE_KINDS
from .prompts import DESIGN_STYLES

ROLES = {
    "private": "🏠 Делаю ремонт себе",
    "foreman": "👷 Прораб / бригада",
    "company": "🏢 Строительная компания",
}

PRO_ROLES = ("foreman", "company")


def roles_kb() -> M:
    return M(inline_keyboard=[[B(text=t, callback_data=f"role:{k}")] for k, t in ROLES.items()])


def webapp_button(path: str = "") -> B | None:
    if not config.webapp_url.startswith("https://"):
        return None
    return B(text="📱 Открыть приложение", web_app=WebAppInfo(url=f"{config.webapp_url}/app/{path}"))


def main_menu(role: str | None) -> M:
    rows = [
        [B(text="🛋 Дизайн по фото", callback_data="menu:design")],
        [B(text="🧮 Калькулятор материалов", callback_data="menu:calc"),
         B(text="📋 Смета", callback_data="menu:estimate")],
        [B(text="🔍 Проверить работу по фото", callback_data="menu:check")],
        [B(text="💬 Консультант", callback_data="menu:consult")],
        [B(text="🏗 Мои объекты", callback_data="obj:list")],
    ]
    if role in PRO_ROLES:
        rows.append([B(text="📄 Коммерческое предложение", callback_data="menu:kp")])
        rows.append([B(text="📸 Фотоотчёт в PDF", callback_data="rep:start")])
        rows.append([B(text="🖼 Портфолио: посты и Reels", callback_data="pf:list")])
    app = webapp_button()
    if app:
        rows.append([app])
    rows.append([B(text="💰 Баланс", callback_data="menu:balance"),
                 B(text="🎁 Пригласить друга", callback_data="menu:invite")])
    rows.append([B(text="🔄 Сменить роль", callback_data="menu:role")])
    return M(inline_keyboard=rows)


def styles_kb() -> M:
    items = list(DESIGN_STYLES.items())
    rows = [[B(text=items[i][1][0], callback_data=f"style:{items[i][0]}"),
             B(text=items[i + 1][1][0], callback_data=f"style:{items[i + 1][0]}")]
            for i in range(0, len(items) - 1, 2)]
    if len(items) % 2:
        rows.append([B(text=items[-1][1][0], callback_data=f"style:{items[-1][0]}")])
    rows.append([B(text="✖️ Отмена", callback_data="menu:home")])
    return M(inline_keyboard=rows)


def calcs_kb() -> M:
    rows = [[B(text=v[0], callback_data=f"calc:{k}")] for k, v in CALCS.items()]
    rows.append([B(text="⬅️ Меню", callback_data="menu:home")])
    return M(inline_keyboard=rows)


def packs_kb() -> M:
    return M(inline_keyboard=[
        [B(text=f"{credits} кредитов — {stars} ⭐", callback_data=f"buy:{pid}")]
        for pid, credits, stars in PACKS
    ] + [[B(text="⬅️ Меню", callback_data="menu:home")]])


def home_kb() -> M:
    return M(inline_keyboard=[[B(text="⬅️ Меню", callback_data="menu:home")]])


def after_design_kb() -> M:
    return M(inline_keyboard=[
        [B(text="🎨 Другой стиль", callback_data="design:again")],
        [B(text="📋 Смета на такой ремонт", callback_data="menu:estimate")],
        [B(text="⬅️ Меню", callback_data="menu:home")],
    ])


def use_text_kb() -> M:
    """Что сделать с текстом/голосом, отправленным вне сценария."""
    return M(inline_keyboard=[
        [B(text="💬 Спросить консультанта", callback_data="use:consult")],
        [B(text="📋 Составить смету", callback_data="use:estimate")],
        [B(text="⬅️ Меню", callback_data="menu:home")],
    ])


# ---------- объекты ----------

def objects_kb(objects: list[dict]) -> M:
    rows = [[B(text=f"🏗 {o['name'][:40]}", callback_data=f"obj:open:{o['id']}")] for o in objects[:20]]
    rows.append([B(text="➕ Новый объект", callback_data="obj:new")])
    rows.append([B(text="🗄 Архив", callback_data="obj:archive"),
                 B(text="⬅️ Меню", callback_data="menu:home")])
    return M(inline_keyboard=rows)


def object_kb(obj: dict) -> M:
    oid = obj["id"]
    rows = [
        [B(text="➕ " + EXPENSE_KINDS["material"], callback_data=f"obj:exp:{oid}:material"),
         B(text="➕ " + EXPENSE_KINDS["payment"], callback_data=f"obj:exp:{oid}:payment")],
        [B(text="➕ " + EXPENSE_KINDS["other"], callback_data=f"obj:exp:{oid}:other"),
         B(text="➕ Этап", callback_data=f"obj:stage:{oid}")],
        [B(text="✅ Отметить этап", callback_data=f"obj:stages:{oid}"),
         B(text="🧾 Расходы", callback_data=f"obj:hist:{oid}")],
        [B(text="💰 Бюджет", callback_data=f"obj:budget:{oid}"),
         B(text="🧠 Советы прораба", callback_data=f"obj:advice:{oid}")],
        [B(text="📸 Фотоотчёт", callback_data=f"rep:start:{oid}")],
    ]
    app = webapp_button(f"#obj/{oid}")
    if app:
        rows.append([app])
    rows.append([
        B(text="📂 Вернуть из архива" if obj.get("archived") else "🗄 В архив",
          callback_data=f"obj:arch:{oid}"),
        B(text="🗑 Удалить", callback_data=f"obj:del:{oid}"),
    ])
    rows.append([B(text="⬅️ Объекты", callback_data="obj:list")])
    return M(inline_keyboard=rows)


def stages_kb(oid: int, stages: list[dict]) -> M:
    rows = [[B(text=("✅ " if s["done"] else "⬜ ") + s["name"][:40], callback_data=f"obj:tgl:{oid}:{s['id']}")]
            for s in stages[:30]]
    rows.append([B(text="⬅️ Назад к объекту", callback_data=f"obj:open:{oid}")])
    return M(inline_keyboard=rows)


def expenses_kb(oid: int, expenses: list[dict]) -> M:
    rows = [[B(text=f"🗑 {e['amount']:,} ₽ {e['note'] or ''}".replace(",", " ")[:50],
               callback_data=f"obj:rmexp:{oid}:{e['id']}")] for e in expenses[:10]]
    rows.append([B(text="⬅️ Назад к объекту", callback_data=f"obj:open:{oid}")])
    return M(inline_keyboard=rows)


def confirm_delete_kb(oid: int) -> M:
    return M(inline_keyboard=[
        [B(text="🗑 Да, удалить навсегда", callback_data=f"obj:del!:{oid}")],
        [B(text="⬅️ Нет, назад", callback_data=f"obj:open:{oid}")],
    ])


def back_to_list_kb() -> M:
    return M(inline_keyboard=[[B(text="⬅️ Объекты", callback_data="obj:list")]])


def back_to_object_kb(oid: int) -> M:
    return M(inline_keyboard=[[B(text="⬅️ Назад к объекту", callback_data=f"obj:open:{oid}")]])


# ---------- фотоотчёт ----------

def report_kb(count: int) -> M:
    rows = []
    if count:
        rows.append([B(text=f"📄 Собрать PDF ({count} фото)", callback_data="rep:build")])
    rows.append([B(text="✖️ Отменить отчёт", callback_data="rep:cancel")])
    return M(inline_keyboard=rows)


def report_objects_kb(objects: list[dict]) -> M:
    rows = [[B(text=f"🏗 {o['name'][:40]}", callback_data=f"rep:start:{o['id']}")] for o in objects[:20]]
    rows.append([B(text="Без объекта", callback_data="rep:start:0")])
    rows.append([B(text="⬅️ Меню", callback_data="menu:home")])
    return M(inline_keyboard=rows)
