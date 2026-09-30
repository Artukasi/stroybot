"""Учёт объекта: разбор ввода и текст сводки. Чистые функции — легко тестировать."""
import html
import re
from datetime import date

from .db import EXPENSE_KINDS

# Слова, по которым угадываем тип расхода
_KIND_WORDS = {
    "payment": ("выплат", "зарплат", "аванс", "бригад", "мастер", "работ", "оплата работ", "з/п", "зп"),
    "material": ("материал", "плитк", "клей", "ламинат", "обои", "краск", "штукатур", "цемент",
                 "гипс", "профил", "доставк", "смес", "грунт", "кабел", "труб"),
}


def guess_kind(text: str) -> str:
    low = text.lower()
    for kind, words in _KIND_WORDS.items():
        if any(w in low for w in words):
            return kind
    return "other"


_NUM = re.compile(r"(\d{1,3}(?:[ \u00a0]\d{3})+(?:[.,]\d+)?(?!\d)|\d+(?:[.,]\d+)?)\s*(к(?![а-яё])|тыс\.?|млн)?(?:\s*(?:руб\.?|р\.?|₽))?", re.I)


def _amount_spans(text: str):
    for m in _NUM.finditer(text):
        raw = m.group(1).replace(" ", "").replace("\u00a0", "").replace(",", ".")
        try:
            value = float(raw)
        except ValueError:
            continue
        unit = (m.group(2) or "").lower().rstrip(".")
        mult = {"к": 1_000, "тыс": 1_000, "млн": 1_000_000}.get(unit, 1)
        yield int(round(value * mult)), m.span()


def parse_amount(text: str) -> int | None:
    """Сумма в рублях — самое большое число в тексте: '12 500', '12500р', '3,5к', '1.2 млн'."""
    best = max(_amount_spans(text), default=None)
    return best[0] if best and best[0] > 0 else None


def parse_expense(text: str, kind: str | None = None) -> tuple[str, int, str] | None:
    """'плитка 12 500' → ('material', 12500, 'плитка'). None, если суммы нет."""
    best = max(_amount_spans(text), default=None)
    if not best or best[0] <= 0:
        return None
    amount, (a, b) = best
    note = re.sub(r"\s+", " ", text[:a] + " " + text[b:]).strip(" -—:,.")
    return (kind or guess_kind(text), amount, note)


def parse_date(text: str, today: date | None = None) -> str | None:
    """'15.10', '15.10.2026', '15/10/26' → 'YYYY-MM-DD'. Без года — ближайшая будущая дата."""
    today = today or date.today()
    m = re.search(r"\b(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?\b", text)
    if not m:
        return None
    day, month = int(m.group(1)), int(m.group(2))
    year = m.group(3)
    try:
        if year:
            y = int(year)
            y = y + 2000 if y < 100 else y
            return date(y, month, day).isoformat()
        d = date(today.year, month, day)
        if d < today:
            d = date(today.year + 1, month, day)
        return d.isoformat()
    except ValueError:
        return None


def parse_stage(text: str, today: date | None = None) -> tuple[str, str | None]:
    """'Плитка в ванной до 15.10' → ('Плитка в ванной', '2026-10-15')."""
    due = parse_date(text, today)
    name = re.sub(r"\b(до|к|срок)?\s*\d{1,2}[./]\d{1,2}(?:[./]\d{2,4})?\b", " ", text, flags=re.I)
    name = re.sub(r"\s+", " ", name).strip(" -—:,.")
    return (name or text.strip(), due)


def money(x: int) -> str:
    return f"{x:,}".replace(",", " ") + " ₽"


def fmt_date(iso: str | None) -> str:
    if not iso:
        return ""
    y, m, d = iso.split("-")
    return f"{d}.{m}.{y}"


def summary(obj: dict, totals: dict[str, int], stages: list[dict], today: date | None = None) -> str:
    """Карточка объекта для Telegram (HTML)."""
    today_s = (today or date.today()).isoformat()
    e = html.escape
    lines = [f"🏗 <b>{e(obj['name'])}</b>"]
    if obj.get("address"):
        lines.append(f"📍 {e(obj['address'])}")
    spent = sum(totals.values())
    lines.append("")
    for kind, title in EXPENSE_KINDS.items():
        if totals.get(kind):
            lines.append(f"{title}: {money(totals[kind])}")
    lines.append(f"<b>Всего потрачено: {money(spent)}</b>")
    if obj.get("budget"):
        left = obj["budget"] - spent
        lines.append(f"Бюджет: {money(obj['budget'])} · "
                     + (f"осталось {money(left)}" if left >= 0 else f"⚠️ перерасход {money(-left)}"))
    if stages:
        done = sum(1 for s in stages if s["done"])
        lines += ["", f"<b>Этапы</b> ({done} из {len(stages)}):"]
        for s in stages:
            mark = "✅" if s["done"] else ("🔴" if s.get("due") and s["due"] < today_s else "⬜")
            due = f" — до {fmt_date(s['due'])}" if s.get("due") else ""
            lines.append(f"{mark} {e(s['name'])}{due}")
    return "\n".join(lines)
