"""Калькуляторы строительных материалов. Чистые функции — легко тестировать."""
import math
from dataclasses import dataclass


@dataclass
class CalcResult:
    title: str
    lines: list[str]

    def text(self) -> str:
        return f"<b>{self.title}</b>\n" + "\n".join(f"• {l}" for l in self.lines)


def _fmt(x: float) -> str:
    return f"{x:.1f}".rstrip("0").rstrip(".").replace(".", ",")


def tile(area_m2: float, tile_w_cm: float, tile_h_cm: float, reserve_pct: float = 10,
         pcs_per_box: int = 0) -> CalcResult:
    """Плитка: штуки с запасом на подрезку, клей (~5 кг/м²), затирка (~0,5 кг/м²)."""
    tile_area = tile_w_cm * tile_h_cm / 10_000
    pieces = math.ceil(area_m2 / tile_area * (1 + reserve_pct / 100))
    lines = [f"Плитка {int(tile_w_cm)}×{int(tile_h_cm)} см: {pieces} шт (запас {int(reserve_pct)}%)"]
    if pcs_per_box:
        lines.append(f"Упаковок по {pcs_per_box} шт: {math.ceil(pieces / pcs_per_box)}")
    glue = area_m2 * 5
    lines.append(f"Клей: ~{_fmt(glue)} кг ({math.ceil(glue / 25)} меш. по 25 кг)")
    lines.append(f"Затирка: ~{_fmt(area_m2 * 0.5)} кг")
    return CalcResult(f"Плитка на {_fmt(area_m2)} м²", lines)


def laminate(area_m2: float, pack_m2: float = 2.0, reserve_pct: float = 7) -> CalcResult:
    """Ламинат: упаковки с запасом, подложка, плинтус по периметру квадратной комнаты (оценка)."""
    need = area_m2 * (1 + reserve_pct / 100)
    packs = math.ceil(need / pack_m2)
    perimeter = 4 * math.sqrt(area_m2)
    return CalcResult(
        f"Ламинат на {_fmt(area_m2)} м²",
        [
            f"Упаковок по {_fmt(pack_m2)} м²: {packs} (запас {int(reserve_pct)}%)",
            f"Подложка: {math.ceil(area_m2 * 1.05)} м²",
            f"Плинтус: ~{math.ceil(perimeter / 2.5)} шт по 2,5 м (для комнаты близкой к квадрату)",
        ],
    )


def wallpaper(perimeter_m: float, height_m: float, roll_w_m: float = 1.06, roll_len_m: float = 10.05,
              rapport_m: float = 0) -> CalcResult:
    """Обои: считаем полосами. Проёмы не вычитаем — они покрывают запас."""
    strip_len = height_m + 0.1 + rapport_m
    strips_per_roll = max(1, math.floor(roll_len_m / strip_len))
    strips = math.ceil(perimeter_m / roll_w_m)
    rolls = math.ceil(strips / strips_per_roll)
    return CalcResult(
        f"Обои: периметр {_fmt(perimeter_m)} м, высота {_fmt(height_m)} м",
        [
            f"Полос: {strips}, из рулона выходит {strips_per_roll}",
            f"Рулонов {_fmt(roll_w_m)}×{_fmt(roll_len_m)} м: {rolls}",
            f"Клей: ~{math.ceil(rolls / 6)} пачк. (1 пачка ≈ 6 рулонов)",
        ],
    )


def plaster(area_m2: float, thickness_mm: float, kg_per_m2_per_mm: float = 0.9,
            bag_kg: float = 30) -> CalcResult:
    """Гипсовая штукатурка: ~0,9 кг на м² на 1 мм слоя (типично для Ротбанд-подобных смесей)."""
    kg = area_m2 * thickness_mm * kg_per_m2_per_mm
    return CalcResult(
        f"Штукатурка на {_fmt(area_m2)} м², слой {_fmt(thickness_mm)} мм",
        [f"Смесь: ~{_fmt(kg)} кг", f"Мешков по {int(bag_kg)} кг: {math.ceil(kg / bag_kg)}"],
    )


def paint(area_m2: float, layers: int = 2, l_per_m2: float = 0.12, can_l: float = 9) -> CalcResult:
    """Краска: расход ~0,12 л/м² на слой (зависит от краски — смотрите банку)."""
    liters = area_m2 * layers * l_per_m2
    return CalcResult(
        f"Краска на {_fmt(area_m2)} м², {layers} слоя",
        [f"Краска: ~{_fmt(liters)} л", f"Банок по {_fmt(can_l)} л: {math.ceil(liters / can_l)}",
         f"Грунтовка: ~{_fmt(area_m2 * 0.15)} л"],
    )


WET_ROOMS = ("ванн", "санузел", "туалет", "душ")


def scan_materials(scan: dict) -> CalcResult:
    """Материалы по точному скану: площади стен уже без окон и дверей, обои — полосами по каждой стене,
    плинтус — по периметру минус двери. Для ванной и санузла — плитка вместо обоев и ламината."""
    s = scan.get("sizes") or {}
    floor = s.get("floor_area") or 0
    walls_net = s.get("wall_area") or 0
    height = s.get("height") or 2.7
    perimeter = s.get("perimeter") or 0
    openings = scan.get("openings") or []
    doors = [o for o in openings if o.get("kind") in ("door", "opening") and o.get("width")]
    skirting = s.get("skirting") or max(0.0, perimeter - sum(o["width"] for o in doors))
    slopes = s.get("slopes") or 0
    corners = len(scan.get("plan") or []) or 4
    room = (scan.get("room") or "Комната")
    lines = [f"Пол {_fmt(floor)} м², стены без окон и дверей {_fmt(walls_net)} м², высота {_fmt(height)} м"]

    if any(w in room.lower() for w in WET_ROOMS):
        tile_m2 = (walls_net + floor) * 1.1
        glue = (walls_net + floor) * 5
        lines += [
            f"Плитка на стены: {_fmt(walls_net * 1.1)} м² (с запасом 10%)",
            f"Плитка на пол: {_fmt(floor * 1.1)} м²",
            f"Клей для плитки: {math.ceil(glue / 25)} меш. по 25 кг",
            f"Затирка: ~{_fmt(tile_m2 * 0.5)} кг",
            f"Гидроизоляция пола и стен на 20 см: ~{_fmt((floor + perimeter * 0.2) * 1.5)} кг",
        ]
    else:
        wall_list = [w for w in scan.get("walls") or [] if w.get("length")]
        strips = sum(math.ceil(w["length"] / 1.06) for w in wall_list) if wall_list \
            else math.ceil(perimeter / 1.06)
        strips -= sum(math.floor(o["width"] / 1.06) for o in doors)
        per_roll = max(1, math.floor(10.05 / (height + 0.1)))
        lines += [
            f"Штукатурка (слой 10 мм): {math.ceil(walls_net * 9 / 30)} меш. по 30 кг",
            f"Шпаклёвка финишная: {math.ceil(walls_net * 1.2 / 20)} меш. по 20 кг",
            f"Краска для стен в 2 слоя: ~{_fmt(walls_net * 0.24)} л ({math.ceil(walls_net * 0.24 / 9)} банк. по 9 л)",
            f"или обои 1,06×10,05 м: {math.ceil(max(strips, 0) / per_roll)} рул. ({max(strips, 0)} полос по стенам)",
            f"Ламинат: {math.ceil(floor * 1.07 / 2.13)} уп. по 2,13 м², подложка {math.ceil(floor * 1.05)} м²",
            f"Плинтус: {_fmt(skirting)} м → {math.ceil(skirting * 1.05 / 2.5)} шт по 2,5 м, углов {corners}",
        ]
    lines.append(f"Потолок: покраска {_fmt(floor)} м², краски ~{_fmt(floor * 0.24)} л")
    if slopes:
        lines.append(f"Откосы окон: {_fmt(slopes)} пог. м")
    return CalcResult(f"Материалы по скану: {room}", lines)


def parse_numbers(text: str) -> list[float]:
    """Достаёт числа из строки вида '3,5 x 4' или '20 60 60'."""
    cleaned = text.lower().replace(",", ".")
    for sep in ("x", "х", "*", "×", ";", "/"):
        cleaned = cleaned.replace(sep, " ")
    out = []
    for tok in cleaned.split():
        try:
            out.append(float(tok))
        except ValueError:
            continue
    return out


# Описание калькуляторов для бота: ключ -> (название, подсказка ввода, мин. кол-во чисел, функция)
CALCS = {
    "tile": ("🧱 Плитка", "Введите: <i>площадь м², ширина и высота плитки в см</i>\nНапример: <code>12 30 60</code>", 3,
             lambda n: tile(n[0], n[1], n[2], pcs_per_box=int(n[3]) if len(n) > 3 else 0)),
    "laminate": ("🪵 Ламинат", "Введите: <i>площадь м²</i> и, если знаете, <i>м² в упаковке</i>\nНапример: <code>18 2.13</code>", 1,
                 lambda n: laminate(n[0], n[1] if len(n) > 1 else 2.0)),
    "wallpaper": ("🧻 Обои", "Введите: <i>периметр комнаты м, высота стен м</i>\nНапример: <code>14 2.7</code>", 2,
                  lambda n: wallpaper(n[0], n[1], rapport_m=n[2] if len(n) > 2 else 0)),
    "plaster": ("🪣 Штукатурка", "Введите: <i>площадь м², толщина слоя мм</i>\nНапример: <code>40 10</code>", 2,
                lambda n: plaster(n[0], n[1])),
    "paint": ("🎨 Краска", "Введите: <i>площадь м²</i> и, если нужно, <i>кол-во слоёв</i>\nНапример: <code>35 2</code>", 1,
              lambda n: paint(n[0], int(n[1]) if len(n) > 1 else 2)),
}
