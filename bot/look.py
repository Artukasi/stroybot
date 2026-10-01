"""Ремонт, собранный в 3D («look»): стены, пол, свет, шторы, замена и расстановка мебели.
Одни и те же ключи у приложения СтройСкан, Mini App и бота. Здесь — проверка того, что прислал
телефон, и описание выбора для картинки «как в жизни» (по-английски) и для сметы (по-русски)."""
import colorsys
import json
import math
import re

from .prompts import DESIGN_STYLES
from .room import Rect, Room

# Мебель из RoomPlan: ключ → (по-русски, по-английски для промпта)
FURNITURE = {
    "sofa": ("диван", "sofa"), "bed": ("кровать", "bed"), "chair": ("стул", "chair"),
    "table": ("стол", "table"), "storage": ("шкаф", "cabinet"), "refrigerator": ("холодильник", "refrigerator"),
    "stove": ("плита", "stove"), "oven": ("духовка", "oven"), "sink": ("раковина", "sink"),
    "toilet": ("унитаз", "toilet"), "bathtub": ("ванна", "bathtub"),
    "washerDryer": ("стиральная машина", "washing machine"), "television": ("телевизор", "TV"),
    "dishwasher": ("посудомойка", "dishwasher"), "fireplace": ("камин", "fireplace"),
    "stairs": ("лестница", "stairs"), "object": ("предмет", "furniture item"),
}

# Варианты мебели: вид → вариант → (как искать в магазине, по-английски для промпта)
VARIANTS = {
    "sofa": {"straight": ("прямой диван", "straight sofa"), "corner": ("угловой диван", "L-shaped corner sofa"),
             "chesterfield": ("диван честерфилд", "chesterfield sofa"), "modular": ("модульный диван", "modular sofa")},
    "bed": {"platform": ("кровать-подиум", "low platform bed"),
            "upholstered": ("мягкая кровать", "upholstered bed with a soft headboard"),
            "classic": ("классическая кровать", "classic wooden bed")},
    "chair": {"dining": ("обеденный стул", "dining chair"), "armchair": ("кресло", "armchair"),
              "stool": ("табурет", "stool")},
    "table": {"dining_rect": ("прямоугольный обеденный стол", "rectangular dining table"),
              "dining_round": ("круглый обеденный стол", "round dining table"),
              "coffee": ("журнальный столик", "coffee table"), "desk": ("письменный стол", "desk")},
    "storage": {"wardrobe": ("шкаф", "wardrobe"), "dresser": ("комод", "chest of drawers"),
                "shelving": ("стеллаж", "open shelving unit"), "tv_stand": ("тумба под ТВ", "TV stand")},
}

WALL_FINISHES = {
    "paint": ("покраска", "matte paint"), "wallpaper": ("обои", "wallpaper"),
    "plaster": ("декоративная штукатурка", "decorative Venetian plaster"),
    "panels": ("стеновые панели", "wooden wall panels"), "tile": ("плитка", "ceramic tiles"),
    "brick": ("кирпич", "exposed brick"),
}
PATTERNS = {
    "plain": ("однотонные", ""), "stripes": ("в полоску", "with vertical stripes"),
    "geometric": ("с геометрическим узором", "with a geometric pattern"),
    "floral": ("с цветочным узором", "with a floral pattern"),
    "damask": ("с дамасским узором", "with a damask pattern"),
    "linen": ("с фактурой льна", "with linen texture"),
}
FLOORS = {
    "laminate": ("ламинат", "laminate flooring"), "parquet": ("паркет", "parquet flooring"),
    "tile": ("плитка", "large-format floor tiles"), "stone": ("керамогранит под камень", "stone-look porcelain tiles"),
    "carpet": ("ковролин", "wall-to-wall carpet"), "concrete": ("микроцемент", "microcement floor"),
}
LIGHTS = {
    "none": ("без люстры", "no ceiling light"),
    "chandelier_classic": ("классическая люстра", "a classic crystal chandelier"),
    "chandelier_modern": ("современная люстра", "a modern designer chandelier"),
    "pendant": ("подвесные светильники", "pendant lamps"),
    "spots": ("точечные светильники", "recessed ceiling spotlights"),
    "track": ("трековые светильники", "black track lights"), "ring": ("кольцевая люстра", "a ring LED chandelier"),
}
CURTAINS = {
    "none": ("без штор", "bare windows"), "curtains": ("шторы в пол", "floor-length curtains"),
    "blinds": ("жалюзи", "window blinds"), "roman": ("римские шторы", "roman blinds"),
}

MAX_LOOK = 32 * 1024     # байт JSON
MAX_ADDED = 30
MAX_CHANGED = 80
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


def variants(kind: str | None) -> dict:
    return VARIANTS.get(kind or "", {"default": ("", "")})


ALL_VARIANTS = {k for vs in VARIANTS.values() for k in vs} | {"default"}


# ---------- цвет словами: модель рисования и сметчик не понимают #rrggbb ----------

def _hsl(color: str) -> tuple[float, float, float]:
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, lum, s = colorsys.rgb_to_hls(r, g, b)
    return h * 360, s, lum


def color_name(color: str) -> tuple[str, str]:
    """'#d9cbb5' → ('бежевый', 'beige')."""
    h, s, lum = _hsl(color)
    if lum > 0.92:
        return "белый", "white"
    if s < 0.12 or lum < 0.1:
        return (("светло-серый", "light grey") if lum > 0.75 else ("серый", "grey") if lum > 0.45
                else ("графитовый", "charcoal") if lum > 0.2 else ("чёрный", "black"))
    if h < 15 or h >= 345:
        return ("розовый", "pink") if lum > 0.75 else ("бордовый", "burgundy") if lum < 0.3 else ("красный", "red")
    if h < 45:
        if lum > 0.75 or s < 0.45 and lum > 0.6:
            return "бежевый", "beige"
        if lum < 0.42 or s < 0.45:
            return "коричневый", "brown"
        return ("терракотовый", "terracotta") if h < 25 else ("оранжевый", "orange")
    if h < 70:
        if lum > 0.8:
            return "кремовый", "cream"
        if s < 0.35:
            return ("песочный", "sand") if lum > 0.55 else ("оливковый", "olive")
        return ("горчичный", "mustard") if lum < 0.45 else ("жёлтый", "yellow")
    if h < 165:
        if lum < 0.3:
            return "тёмно-зелёный", "dark green"
        if s < 0.3:
            return ("шалфейный", "sage green") if lum > 0.45 else ("оливковый", "olive")
        return ("мятный", "mint") if lum > 0.75 else ("зелёный", "green")
    if h < 200:
        return "бирюзовый", "teal"
    if h < 255:
        if lum < 0.3:
            return "тёмно-синий", "navy blue"
        if lum > 0.72:
            return "голубой", "light blue"
        return ("серо-голубой", "grey-blue") if s < 0.3 else ("синий", "blue")
    if h < 290:
        return ("лавандовый", "lavender") if lum > 0.72 else ("фиолетовый", "purple")
    return ("розовый", "pink") if lum > 0.72 else ("сливовый", "plum") if lum < 0.35 else ("пурпурный", "magenta")


def wood_name(color: str) -> tuple[str, str]:
    """Цвет ламината или паркета → порода дерева."""
    h, s, lum = _hsl(color)
    if s >= 0.12 and not 10 <= h < 60:
        return color_name(color)
    if s < 0.12:
        return (("белёный дуб", "whitewashed oak") if lum > 0.8 else ("серый дуб", "grey-washed oak") if lum > 0.35
                else ("тёмное дерево", "dark stained wood"))
    return (("светлый дуб", "light bleached oak") if lum > 0.72 else ("натуральный дуб", "natural oak") if lum > 0.5
            else ("орех", "walnut") if lum > 0.32 else ("венге", "dark wenge wood"))


# ---------- проверка ----------

def _color(v) -> str | None:
    return v.lower() if isinstance(v, str) and HEX.match(v) else None


def _part(raw, fields: dict) -> dict:
    """Только известные ключи с правильными значениями. fields: ключ → допустимые значения (None — цвет)."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for k, allowed in fields.items():
        v = raw.get(k)
        v = _color(v) if allowed is None else v if isinstance(v, str) and v in allowed else None
        if v is not None:
            out[k] = v
    return out


def _num(v, lo: float, hi: float) -> float | None:
    if isinstance(v, bool):
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return round(min(hi, max(lo, v)), 3) if math.isfinite(v) else None


def clean_look(raw, scan: dict | None = None) -> dict:
    """Ремонт из 3D → только известные ключи и значения. Неизвестное выбрасываем, числа зажимаем.
    Со сканом проверяем номера стен и мебели и варианты по виду мебели."""
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ValueError("look")
    if len(json.dumps(raw, ensure_ascii=False).encode()) > MAX_LOOK:
        raise ValueError("look too large")
    # стены нумеруем как приложение и Mini App: точные стены, иначе стороны контура пола, иначе 4
    walls = len(Room(scan).walls) if scan else 200
    kinds = [o.get("kind") for o in scan.get("objects") or []] if scan else None
    out: dict = {}
    if raw.get("style") in DESIGN_STYLES:
        out["style"] = raw["style"]
    surface = {"finish": WALL_FINISHES, "color": None, "pattern": PATTERNS}
    if wall := _part(raw.get("wall"), surface):
        out["wall"] = wall
    if accent := _part(raw.get("accent"), surface):
        i = raw["accent"].get("wall")
        accent["wall"] = i if isinstance(i, int) and not isinstance(i, bool) and 0 <= i < walls else None
        out["accent"] = accent
    if floor := _part(raw.get("floor"), {"finish": FLOORS, "color": None}):
        out["floor"] = floor
    if ceiling := _part(raw.get("ceiling"), {"light": LIGHTS, "color": None}):
        out["ceiling"] = ceiling
    if raw.get("curtains") in CURTAINS:
        out["curtains"] = raw["curtains"]

    changed = {}
    items = raw.get("objects") if isinstance(raw.get("objects"), dict) else {}
    for key, v in list(items.items())[:MAX_CHANGED]:
        if not isinstance(v, dict) or not re.fullmatch(r"\d{1,3}", str(key)):
            continue
        i = int(key)
        if kinds is not None and i >= len(kinds):
            continue
        item = _part(v, {"variant": variants(kinds[i]) if kinds is not None else ALL_VARIANTS, "color": None})
        if isinstance(v.get("hidden"), bool):
            item["hidden"] = v["hidden"]
        if item:
            changed[str(i)] = item
    if changed:
        out["objects"] = changed

    added = []
    for a in (raw.get("added") if isinstance(raw.get("added"), list) else [])[:MAX_ADDED]:
        if not isinstance(a, dict) or a.get("kind") not in FURNITURE:
            continue
        item = {"kind": a["kind"], **_part(a, {"variant": variants(a["kind"]), "color": None})}
        nums = {"width": _num(a.get("width"), 0.05, 6), "depth": _num(a.get("depth"), 0.05, 6),
                "height": _num(a.get("height"), 0.05, 4),
                "x": _num(a.get("x"), -1000, 1000), "y": _num(a.get("y"), -1000, 1000)}
        if any(v is None for v in nums.values()):
            continue
        angle = _num(a.get("angle"), -1e6, 1e6) or 0.0
        item.update(nums, angle=round(math.atan2(math.sin(angle), math.cos(angle)), 4))
        added.append(item)
    if added:
        out["added"] = added
    return out


# ---------- описание выбора ----------

def _paint(part: dict, lang: int, wood: bool = False) -> str:
    c = part.get("color")
    if not c:
        return ""
    name = (wood_name if wood else color_name)(c)[lang]
    return f"{name} ({c})" if lang else name


def _surface_en(part: dict, finishes: dict, wood: bool = False) -> str:
    finish = finishes.get(part.get("finish"), ("", ""))[1]
    pattern = PATTERNS.get(part.get("pattern"), ("", ""))[1] if part.get("finish") in (None, "wallpaper") else ""
    return " ".join(x for x in (_paint(part, 1, wood), finish, pattern) if x)


def _surface_ru(part: dict, finishes: dict, wood: bool = False) -> str:
    finish = finishes.get(part.get("finish"), ("", ""))[0]
    pattern = PATTERNS.get(part.get("pattern"), ("", ""))[0] if part.get("finish") in (None, "wallpaper") else ""
    color = _paint(part, 0, wood)
    return ", ".join(x for x in (" ".join(x for x in (finish, pattern) if x),
                                 (color if wood else f"цвет {color}") if color else "") if x)


def _wall_known(room: Room | None, accent: dict) -> bool:
    """Номер стены — как в 3D: точная стена или сторона контура пола у старых сканов."""
    return bool(room and accent.get("wall") is not None and accent["wall"] < len(room.walls))


def _cm(o: dict) -> str:
    return "×".join(str(round(o[k] * 100)) for k in ("width", "depth", "height") if o.get(k))


def item_en(kind: str | None, variant: str | None = None, color: str | None = None) -> str:
    """Вещь по-английски для картинки: 'sofa', 'corner', '#808080' → 'grey (#808080) L-shaped corner sofa'."""
    name = variants(kind).get(variant or "", ("", ""))[1] or FURNITURE.get(kind or "", FURNITURE["object"])[1]
    return " ".join(x for x in (_paint({"color": color}, 1), name) if x)


def edited_objects(scan: dict, look: dict | None) -> list[tuple[dict, dict]]:
    """Мебель, как её собрали в 3D: (вещь, выбор) — без убранного, с добавленным."""
    look = look or {}
    changed = look.get("objects") or {}
    out = [(o, changed.get(str(i)) or {}) for i, o in enumerate(scan.get("objects") or [])]
    return [(o, ch) for o, ch in out if not ch.get("hidden")] + [(o, o) for o in look.get("added") or []]


def look_en(look: dict | None, scan: dict | None = None, edited: bool = False) -> str:
    """Выбор клиента из 3D → короткое описание по-английски для картинки.
    edited — мебель уже описана такой, как в 3D (снимок 3D-модели): здесь только отделка, без «убрать/добавить»."""
    if not look:
        return ""
    room = Room(scan) if scan else None
    parts = []
    if look.get("wall"):
        parts.append("walls: " + _surface_en(look["wall"], WALL_FINISHES))
    a = look.get("accent") or {}
    if a.get("finish") or a.get("color"):
        where = f" ({room.wall_en(a['wall'])})" if _wall_known(room, a) else ""
        parts.append(f"one accent wall{where}: " + _surface_en(a, WALL_FINISHES))
    if look.get("floor"):
        wood = look["floor"].get("finish") in ("laminate", "parquet")
        parts.append("floor: " + _surface_en(look["floor"], FLOORS, wood))
    if c := look.get("ceiling"):
        light = LIGHTS.get(c.get("light"), ("", ""))[1]
        parts.append("ceiling: " + ", ".join(x for x in (_paint(c, 1), light) if x))
    if look.get("curtains"):
        parts.append("windows: " + CURTAINS[look["curtains"]][1])
    if edited:
        return "; ".join(parts)
    objects = (scan or {}).get("objects") or []
    removed, swapped = [], []
    for key, ch in (look.get("objects") or {}).items():
        i = int(key)
        if i >= len(objects):
            continue
        o = objects[i]
        name = FURNITURE.get(o.get("kind"), FURNITURE["object"])[1]
        what = f"the {name} ({room.place_en(Rect.of(o))})" if room else f"the {name}"
        if ch.get("hidden"):
            removed.append(what)
            continue
        swapped.append(f"{what} becomes a {item_en(o.get('kind'), ch.get('variant'), ch.get('color'))}")
    if swapped:
        parts.append("furniture: " + ", ".join(swapped))
    if removed:
        parts.append("remove " + ", ".join(removed))
    added = []
    for o in look.get("added") or []:
        place = room.place_en(Rect.of(o)) if room else ""
        added.append(" ".join(x for x in ("a", item_en(o["kind"], o.get("variant"), o.get("color")),
                                          _cm(o) + " cm", place) if x))
    if added:
        parts.append("add " + ", ".join(added))
    return "; ".join(parts)


def look_ru(look: dict | None, scan: dict | None = None) -> list[str]:
    """Выбор клиента из 3D → строки для сметы."""
    if not look:
        return []
    room = Room(scan) if scan else None
    lines = []
    if look.get("style") in DESIGN_STYLES:
        lines.append(f"Стиль: {DESIGN_STYLES[look['style']][0]}")
    if look.get("wall"):
        lines.append("Стены: " + _surface_ru(look["wall"], WALL_FINISHES))
    a = look.get("accent") or {}
    if a.get("finish") or a.get("color"):
        where = f" ({room.wall_title_ru(a['wall'])})" if _wall_known(room, a) else ""
        lines.append(f"Акцентная стена{where}: " + _surface_ru(a, WALL_FINISHES))
    if look.get("floor"):
        wood = look["floor"].get("finish") in ("laminate", "parquet")
        lines.append("Пол: " + _surface_ru(look["floor"], FLOORS, wood))
    if c := look.get("ceiling"):
        color = _paint(c, 0)
        lines.append("Потолок: " + ", ".join(x for x in (LIGHTS.get(c.get("light"), ("", ""))[0],
                                                          f"цвет {color}" if color else "") if x))
    if look.get("curtains"):
        lines.append("Окна: " + CURTAINS[look["curtains"]][0])
    objects = (scan or {}).get("objects") or []
    changes = []
    for key, ch in (look.get("objects") or {}).items():
        i = int(key)
        if i >= len(objects):
            continue
        o = objects[i]
        name = FURNITURE.get(o.get("kind"), FURNITURE["object"])[0]
        if ch.get("hidden"):
            changes.append(f"{name} — убрать")
            continue
        new = variants(o.get("kind")).get(ch.get("variant"), ("", ""))[0]
        color = _paint(ch, 0)
        what = ", ".join(x for x in (new, color) if x)
        if what:
            changes.append(f"{name} — {what}")
    if changes:
        lines.append("Мебель: " + "; ".join(changes))
    added = []
    for o in look.get("added") or []:
        name = variants(o["kind"]).get(o.get("variant"), ("", ""))[0] or FURNITURE[o["kind"]][0]
        color = _paint(o, 0)
        added.append(f"{name} {_cm(o)} см" + (f", {color}" if color else ""))
    if added:
        lines.append("Добавить: " + "; ".join(added))
    return lines
