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
