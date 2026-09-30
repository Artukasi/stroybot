from aiogram.types import InlineKeyboardButton as B, InlineKeyboardMarkup as M

from .calc import CALCS
from .config import PACKS
from .prompts import DESIGN_STYLES

ROLES = {
    "private": "🏠 Делаю ремонт себе",
    "foreman": "👷 Прораб / бригада",
    "company": "🏢 Строительная компания",
}


def roles_kb() -> M:
    return M(inline_keyboard=[[B(text=t, callback_data=f"role:{k}")] for k, t in ROLES.items()])


def main_menu(role: str | None) -> M:
    rows = [
        [B(text="🛋 Дизайн по фото", callback_data="menu:design")],
        [B(text="🧮 Калькулятор материалов", callback_data="menu:calc"),
         B(text="📋 Смета", callback_data="menu:estimate")],
        [B(text="🔍 Проверить работу по фото", callback_data="menu:check")],
        [B(text="💬 Консультант", callback_data="menu:consult")],
    ]
    if role in ("foreman", "company"):
        rows.append([B(text="📄 Коммерческое предложение", callback_data="menu:kp")])
    rows.append([B(text="💰 Баланс", callback_data="menu:balance"),
                 B(text="🔄 Сменить роль", callback_data="menu:role")])
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
