"""🛋 Мебель по размерам: сколько места у каждой вещи из скана и что встанет на свободные стены.
Ссылки — обычный поиск на сайтах магазинов с размерами в запросе (бесплатно, без ключей и парсинга)."""
import math
from urllib.parse import quote

from .calc import WET_ROOMS
from .look import FURNITURE, color_name, variants
from .room import TOUCH, Rect, Room, cast, overlaps

PASSAGE = 0.7          # проход перед мебелью
MIN_STRETCH = 0.6      # свободный кусок стены, куда есть смысл что-то советовать
MAX_SUGGEST = 3
SKIP = {"stairs", "fireplace", "object"}                  # это в магазине мебели не купить
FURNITURE_ONLY = {"sofa", "bed", "chair", "table", "storage"}
SHOPS = (
    ("Яндекс Маркет", "https://market.yandex.ru/search?text="),
    ("Ozon", "https://www.ozon.ru/search/?text="),
    ("Wildberries", "https://www.wildberries.ru/catalog/0/search.aspx?search="),
    ("Divan.ru", "https://www.divan.ru/search?ProductSearch%5Bname%5D="),   # только мебель
)
TV_INCHES = (24, 32, 43, 50, 55, 65, 75, 85, 98)
# больше этого (ширина, глубина в метрах) такую вещь не делают, сколько бы места ни было
CAPS = {
    "sofa": (4.0, 2.0), "bed": (2.2, 2.3), "chair": (1.0, 1.0), "table": (3.0, 1.4), "storage": (3.0, 0.7),
    "refrigerator": (1.0, 0.8), "stove": (0.9, 0.7), "oven": (0.9, 0.7), "sink": (1.2, 0.7), "toilet": (0.5, 0.8),
    "bathtub": (2.0, 1.0), "washerDryer": (0.7, 0.7), "television": (2.5, 0.5), "dishwasher": (0.7, 0.7),
}


def links(query: str, kind: str) -> list[dict]:
    q = quote(query, safe="")
    return [{"shop": shop, "url": url + q} for shop, url in SHOPS if shop != "Divan.ru" or kind in FURNITURE_ONLY]


def _m(v: float) -> str:
    return f"{v:.2f}".rstrip("0").rstrip(".").replace(".", ",")


def _cm(v: float) -> int:
    return int(round(v * 100))


def _down(v: float) -> int:
    return int(math.floor(v * 100 + 1e-6))


def _ten(cm: int) -> int:
    return max(10, cm // 10 * 10)


def _five(cm: int, top: int) -> int:
    """Размер для поиска: до 5 см, но не больше того, что встанет."""
    return max(5, min(int(cm / 5 + 0.5) * 5, top // 5 * 5))


def _free(a: float, b: float, blocked: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Свободные куски [a, b] без занятых интервалов."""
    out, cur = [], a
    for x0, x1 in sorted(blocked):
        if x1 <= cur or x0 >= b:
            continue
        if x0 > cur:
            out.append((cur, x0))
        cur = max(cur, x1)
    if cur < b:
        out.append((cur, b))
    return out


def _obstacles(room: Room, r: Rect, skip: int) -> list:
    segs = list(room.walls) + room.box_segs
    for j, o in enumerate(room.objects):
        # стол со стульями двигаются вместе, телевизор стоит на тумбе — такие друг другу не мешают
        if j == skip or {o.kind, r.kind} == {"chair", "table"} or overlaps(o, r):
            continue
        segs += o.segs()
    for z in room.zones(r.height):
        if not overlaps(z, r):
            segs += z.segs()
    return segs


def _clear(room: Room, r: Rect, segs, a: int, b: int) -> float:
    """Свободное место от стороны прямоугольника: a=±1 — по ширине, b=±1 — по глубине."""
    d = (r.u[0] * a + r.v[0] * b, r.u[1] * a + r.v[1] * b)
    best = 50.0
    for k in (-0.7, 0.0, 0.7):
        x, y = r.point(a or k, b or k)
        p = (x + d[0] * 0.005, y + d[1] * 0.005)
        best = min(best, cast(p, d, segs) if room.is_inside(p) else 0.0)
    return best


def _query(kind: str, variant: str | None, color: str | None, w: int, d: int) -> tuple[str, str]:
    """(название, текст поиска)."""
    noun = variants(kind).get(variant or "", ("", ""))[0] or FURNITURE.get(kind, FURNITURE["object"])[0]
    title = noun[:1].upper() + noun[1:]
    if kind == "television":
        inches = min(TV_INCHES, key=lambda n: abs(n * 2.54 * 0.8716 - w))
        return title, f"телевизор {inches} дюймов"
    words = [noun] + ([color_name(color)[0]] if color else [])
    return title, f"{' '.join(words)} {w}×{d} см"


def _item(room: Room, n: int, kind: str, variant, color) -> dict:
    r = room.objects[n]
    segs = _obstacles(room, r, n)
    right, left = _clear(room, r, segs, 1, 0), _clear(room, r, segs, -1, 0)
    front, back = _clear(room, r, segs, 0, 1), _clear(room, r, segs, 0, -1)
    if front < back:
        front, back = back, front
    against = back < TOUCH
    if against:      # у стены: вдоль стены до угла или соседней мебели, спереди — проход
        max_w = r.w + right + left
        max_d = r.d + max(0.0, front - PASSAGE)
    else:            # посреди комнаты: проход со всех сторон
        max_w = r.w + max(0.0, right - PASSAGE) + max(0.0, left - PASSAGE)
        max_d = r.d + max(0.0, front - PASSAGE) + max(0.0, back - PASSAGE)
    cap_w, cap_d = CAPS.get(kind, (max_w, max_d))
    size = {"width": _cm(r.w), "depth": _cm(r.d), "height": _cm(r.height) or None}
    top = {"width": max(_down(min(max_w, cap_w)), size["width"]),
           "depth": max(_down(min(max_d, cap_d)), size["depth"])}
    title, query = _query(kind, variant, color, _five(size["width"], top["width"]),
                          _five(size["depth"], top["depth"]))
    place = room.place_ru(r)
    if not against:
        note = f"{place}: вокруг оставлен проход 70 см"
    elif front >= PASSAGE:
        note = f"{place}: по ширине свободно {_m(max_w)} м, спереди проход 70 см"
    else:
        note = f"{place}: по ширине свободно {_m(max_w)} м, проход спереди всего {_cm(front)} см — глубже не брать"
    return {"kind": kind, "title": title, "variant": variant, "wall": room.where(r)[1], "size": size, "max": top,
            "note": note[:1].upper() + note[1:], "query": query, "links": links(query, kind)}


def _suggest(room: Room, scan: dict) -> list[dict]:
    """Что поставить на пустые участки стен: шкаф, комод или стеллаж — по свободной глубине."""
    wet = any(w in (scan.get("room") or "").lower() for w in WET_ROOMS)
    zones = room.zones(0)
    segs = list(room.walls) + room.box_segs + [s for r in room.objects + zones for s in r.segs()]
    found = []
    for i in range(len(room.walls)):
        length = room.wall_len(i)
        if length < MIN_STRETCH:
            continue
        x1, y1, _, _ = room.walls[i]
        dx, dy = room.wall_dir(i)
        nx, ny = room.inward(i)
        blocked = []
        for r in room.objects + zones:
            # вдоль стены и вглубь комнаты; что стоит ближе 60 см к стене — занимает её
            along = [(p[0] - x1) * dx + (p[1] - y1) * dy for p in r.corners()]
            inward = [(p[0] - x1) * nx + (p[1] - y1) * ny for p in r.corners()]
            if min(inward) < 0.6 and max(inward) > -0.2:
                blocked.append((min(along) - 0.05, max(along) + 0.05))
        windows = [(o["offset"] - o["width"] / 2 - 0.05, o["offset"] + o["width"] / 2 + 0.05, o["bottom"])
                   for o in room.openings if o["wall"] == i and o["kind"] == "window"]
        for a, b in _free(0.0, length, blocked):
            parts = [(p0, p1, None) for p0, p1 in _free(a, b, [(w0, w1) for w0, w1, _ in windows])]
            parts += [(max(a, w0), min(b, w1), 0.8 if bottom is None else bottom)
                      for w0, w1, bottom in windows if min(b, w1) - max(a, w0) > 0]
            for s0, s1, low in parts:
                if s1 - s0 < MIN_STRETCH:
                    continue
                # свободная глубина: лучи от стены в комнату через каждые ~30 см, минус проход
                steps = max(2, math.ceil((s1 - s0) / 0.3) + 1)
                marks = (s0 + 0.05 + (s1 - s0 - 0.1) * k / (steps - 1) for k in range(steps))
                depth = min(cast((x1 + dx * s + nx * 0.02, y1 + dy * s + ny * 0.02), (nx, ny), segs)
                            for s in marks) - PASSAGE
                if wet:
                    pick = ("wardrobe", "Пенал для ванной", "пенал для ванной", 0.6, 0.35) \
                        if low is None and depth >= 0.25 else None
                elif low is not None:
                    pick = ("dresser", "Комод", "комод", 2.0, 0.45) if depth >= 0.35 and low >= 0.5 else None
                else:
                    pick = (("wardrobe", "Шкаф", "шкаф", 3.0, 0.6) if depth >= 0.55 else
                            ("dresser", "Комод", "комод", 2.0, 0.45) if depth >= 0.35 else
                            ("shelving", "Стеллаж", "стеллаж", 2.0, 0.35) if depth >= 0.25 else None)
                if not pick:
                    continue
                variant, title, noun, cap_w, cap_d = pick
                w_m, d_m = min(s1 - s0, cap_w), min(depth, cap_d)
                width = _ten(_down(w_m))
                query = f"{noun} шириной до {width} см" + (f" высотой до {_ten(_down(low))} см" if low else "")
                note = f"{room.wall_ru(i)}: свободно {_m(s1 - s0)} м, спереди проход 70 см" + (
                    f", под окном — высота до {_down(low)} см" if low else "")
                mid = (s0 + s1) / 2
                place = Rect(x1 + dx * mid + nx * (d_m / 2 + 0.02), y1 + dy * mid + ny * (d_m / 2 + 0.02),
                             width / 100, d_m, math.atan2(dy, dx))
                found.append({"kind": "storage", "title": title, "variant": variant, "wall": i,
                              "size": {"width": None, "depth": None, "height": None},
                              "max": {"width": width, "depth": _down(d_m)},
                              "note": note[:1].upper() + note[1:], "query": query, "links": links(query, "storage"),
                              "place": {"x": round(place.x, 3), "y": round(place.y, 3),
                                        "angle": round(place.angle, 4), "width": width / 100,
                                        "depth": round(d_m, 2)}, "_rect": place})
    chosen = []
    for s in sorted(found, key=lambda s: (-s["max"]["width"], -s["max"]["depth"])):
        if len(chosen) < MAX_SUGGEST and not any(overlaps(s["_rect"], c["_rect"]) for c in chosen):
            chosen.append(s)
    return [{k: v for k, v in s.items() if k != "_rect"} for s in chosen]


def pick(scan: dict, look: dict | None = None) -> list[dict]:
    """Мебель из скана (с учётом ремонта из 3D: убранное и добавленное) + советы на пустые стены.
    Размеры в сантиметрах: size — как сейчас, max — самое большое, что встанет."""
    look = look or {}
    changed = look.get("objects") or {}
    src = []    # (предмет, индекс в скане, индекс в added, вариант, цвет)
    for i, o in enumerate(scan.get("objects") or []):
        ch = changed.get(str(i)) or {}
        if not ch.get("hidden"):
            src.append((o, i, None, ch.get("variant"), ch.get("color")))
    for j, o in enumerate(look.get("added") or []):
        src.append((o, None, j, o.get("variant"), o.get("color")))
    room = Room({**scan, "objects": [s[0] for s in src]})
    out = []
    for n, (o, i, j, variant, color) in enumerate(src):
        kind = o.get("kind") or "object"
        if kind in SKIP or not o.get("width") or not o.get("depth"):
            continue
        out.append({**_item(room, n, kind, variant, color), "index": i, "added": j})
    if room.located:
        out += [{**s, "index": None, "added": None} for s in _suggest(room, scan)]
    return out
