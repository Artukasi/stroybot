"""Геометрия комнаты по скану: стены на плане, окна и двери на стенах, мебель и «лучи» до препятствий.
Всё в метрах, в координатах плана скана (x, y; угол — радианы). Чистые функции, без сети и базы."""
import math

DOOR_ZONE = 0.9      # перед дверью место, чтобы она открывалась и можно было пройти
OPENING_ZONE = 0.6   # перед проёмом без двери
WINDOW_ZONE = 0.3    # высокая мебель не должна закрывать окно
TOUCH = 0.35         # ближе этого к стене — мебель стоит «у стены»
RAYS = (0.3, 1.557, 2.813, 4.07, 5.326)   # лучи «внутри ли точка»: пять сторон вразброс, не вдоль стен
# как назвать стену: (по-русски, «у …», по-английски)
WALL_NAMES = {
    "window": ("стена с окном", "у стены с окном", "the window wall"),
    "door": ("стена с дверью", "у стены с дверью", "the wall with the door"),
    "long": ("длинная стена", "у длинной стены", "the long wall"),
    "short": ("короткая стена", "у короткой стены", "the short wall"),
}


def _f(v) -> float | None:
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


class Rect:
    """Прямоугольник на полу: центр, ширина вдоль u, глубина вдоль v, поворот."""

    def __init__(self, x: float, y: float, w: float, d: float, angle: float = 0.0, kind: str = "",
                 height: float = 0.0):
        self.x, self.y, self.w, self.d, self.angle = x, y, max(w, 0.01), max(d, 0.01), angle
        self.kind, self.height = kind, height
        self.u = (math.cos(angle), math.sin(angle))
        self.v = (-math.sin(angle), math.cos(angle))
        # углы и стороны считаем один раз: их спрашивают сотни раз на комнату
        c = [self.point(a, b) for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        self._corners, self._segs = c, [(*c[i], *c[(i + 1) % 4]) for i in range(4)]

    @classmethod
    def of(cls, o: dict) -> "Rect":
        """Мебель из скана или из ремонта в 3D."""
        return cls(_f(o.get("x")) or 0.0, _f(o.get("y")) or 0.0, _f(o.get("width")) or 0.3,
                   _f(o.get("depth")) or 0.3, _f(o.get("angle")) or 0.0, str(o.get("kind") or "object"),
                   _f(o.get("height")) or 0.0)

    def point(self, a: float, b: float) -> tuple[float, float]:
        """Точка в долях полуразмеров: a вдоль ширины, b вдоль глубины (−1…1 — на краях)."""
        a, b = a * self.w / 2, b * self.d / 2
        return self.x + self.u[0] * a + self.v[0] * b, self.y + self.u[1] * a + self.v[1] * b

    def corners(self) -> list[tuple[float, float]]:
        return self._corners

    def segs(self) -> list[tuple[float, float, float, float]]:
        return self._segs


def overlaps(a: Rect, b: Rect, shrink: float = 0.02) -> bool:
    """Пересекаются ли прямоугольники (касание не считаем)."""
    ca, cb = a.corners(), b.corners()
    for axis in (a.u, a.v, b.u, b.v):
        pa = [p[0] * axis[0] + p[1] * axis[1] for p in ca]
        pb = [p[0] * axis[0] + p[1] * axis[1] for p in cb]
        if max(pa) - shrink <= min(pb) or max(pb) - shrink <= min(pa):
            return False
    return True


def cast(p: tuple[float, float], d: tuple[float, float], segs, far: float = 50.0) -> float:
    """Расстояние от точки p по направлению d до ближайшего отрезка."""
    (px, py), (dx, dy), best = p, d, far
    for x1, y1, x2, y2 in segs:
        ex, ey = x2 - x1, y2 - y1
        den = dx * ey - dy * ex
        if -1e-9 < den < 1e-9:
            continue
        wx, wy = x1 - px, y1 - py
        t = (wx * ey - wy * ex) / den
        if 1e-6 < t < best and -1e-9 <= (wx * dy - wy * dx) / den <= 1 + 1e-9:
            best = t
    return best


def crossings(p: tuple[float, float], d: tuple[float, float], segs) -> int:
    """Сколько отрезков пересекает луч из p по направлению d."""
    n = 0
    for x1, y1, x2, y2 in segs:
        ex, ey = x2 - x1, y2 - y1
        den = d[0] * ey - d[1] * ex
        if abs(den) < 1e-9:
            continue
        wx, wy = x1 - p[0], y1 - p[1]
        t = (wx * ey - wy * ex) / den
        s = (wx * d[1] - wy * d[0]) / den
        n += t > 1e-9 and 0 <= s <= 1
    return n


def inside(poly: list[tuple[float, float]], p: tuple[float, float]) -> bool:
    x, y = p
    res = False
    for i in range(len(poly)):
        (x1, y1), (x2, y2) = poly[i], poly[i - 1]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            res = not res
    return res


def seg_dist(p, seg) -> float:
    x1, y1, x2, y2 = seg
    ex, ey = x2 - x1, y2 - y1
    ll = ex * ex + ey * ey
    t = 0.0 if ll < 1e-12 else max(0.0, min(1.0, ((p[0] - x1) * ex + (p[1] - y1) * ey) / ll))
    return math.hypot(p[0] - x1 - ex * t, p[1] - y1 - ey * t)


class Room:
    """Комната из скана. Нет точных стен (старый скан) — берём контур пола,
    нет и его — прямоугольник длина × ширина."""

    def __init__(self, scan: dict):
        sizes = scan.get("sizes") or {}
        self.plan = [(_f(p[0]), _f(p[1])) for p in scan.get("plan") or []
                     if isinstance(p, (list, tuple)) and len(p) == 2 and None not in (_f(p[0]), _f(p[1]))]
        if len(self.plan) < 3:
            self.plan = []
        walls = scan.get("walls") or []
        lines = scan.get("wall_lines") or []
        self.exact = bool(lines) and len(lines) == len(walls)
        if self.exact:
            self.walls = [tuple(float(v) for v in ln) for ln in lines]
        elif self.plan:
            self.walls = [(*self.plan[i], *self.plan[(i + 1) % len(self.plan)]) for i in range(len(self.plan))]
        else:
            length = _f(sizes.get("length")) or math.sqrt(_f(sizes.get("floor_area")) or 9)
            width = _f(sizes.get("width")) or (_f(sizes.get("floor_area")) or length * length) / length
            self.plan = [(0.0, 0.0), (length, 0.0), (length, width), (0.0, width)]
            self.walls = [(*self.plan[i], *self.plan[(i + 1) % 4]) for i in range(4)]
        pts = self.plan + [(w[0], w[1]) for w in self.walls] + [(w[2], w[3]) for w in self.walls]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        self.box = (min(xs) - 0.01, min(ys) - 0.01, max(xs) + 0.01, max(ys) + 0.01)
        x0, y0, x1, y1 = self.box
        self.box_segs = [(x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)]
        self.center = ((x0 + x1) / 2, (y0 + y1) / 2)
        self.longest = max((self.wall_len(i) for i in range(len(self.walls))), default=0)
        self.objects = [Rect.of(o) for o in scan.get("objects") or [] if isinstance(o, dict)]
        # окна и двери, привязанные к стенам (только в сканах с точными стенами)
        self.openings = []
        for o in scan.get("openings") or []:
            i, off = o.get("wall"), _f(o.get("offset"))
            if not self.exact or not isinstance(i, int) or not 0 <= i < len(self.walls) or off is None:
                continue
            self.openings.append({"kind": o.get("kind"), "wall": i, "offset": off,
                                  "width": _f(o.get("width")) or 0.8, "height": _f(o.get("height")) or 0.0,
                                  "bottom": _f(o.get("bottom"))})
        # все окна и двери известно где — можно советовать мебель на свободные стены, не закрывая их
        # (у старых сканов без точных стен — только если окон и дверей нет вовсе)
        self.located = len(self.openings) == len(scan.get("openings") or [])
        self._inward: dict[int, tuple[float, float]] = {}

    # ---------- стены ----------

    def wall_len(self, i: int) -> float:
        x1, y1, x2, y2 = self.walls[i]
        return math.hypot(x2 - x1, y2 - y1)

    def wall_dir(self, i: int) -> tuple[float, float]:
        x1, y1, x2, y2 = self.walls[i]
        ll = self.wall_len(i) or 1
        return (x2 - x1) / ll, (y2 - y1) / ll

    def enclosed(self, p) -> bool:
        """Внутри ли точка по самим стенам (чёт-нечет). Лучи в пять сторон и большинство голосов:
        один луч может проскочить в щель недоснятого угла."""
        votes = sum(crossings(p, (math.cos(a), math.sin(a)), self.walls) % 2 for a in RAYS)
        return votes * 2 > len(RAYS)

    def inward(self, i: int) -> tuple[float, float]:
        """Нормаль стены внутрь комнаты. Сначала по контуру пола; но на iOS 16 контур — выпуклая оболочка
        концов стен, и у стен «внутреннего угла» (Г-образная комната) обе стороны внутри — тогда по стенам."""
        if i in self._inward:
            return self._inward[i]
        x1, y1, x2, y2 = self.walls[i]
        dx, dy = self.wall_dir(i)
        n = (-dy, dx)
        mid = ((x1 + x2) / 2, (y1 + y2) / 2)
        a, b = (mid[0] + n[0] * 0.1, mid[1] + n[1] * 0.1), (mid[0] - n[0] * 0.1, mid[1] - n[1] * 0.1)
        tests = ([lambda p: inside(self.plan, p)] if self.plan else []) + ([self.enclosed] if self.exact else [])
        for test in tests:
            if (ok := test(a)) != test(b):
                break
        else:       # не поняли — к центру комнаты
            ok = (self.center[0] - mid[0]) * n[0] + (self.center[1] - mid[1]) * n[1] > 0
        self._inward[i] = n if ok else (-n[0], -n[1])
        return self._inward[i]

    def is_inside(self, p) -> bool:
        return inside(self.plan, p) if self.plan else True

    def wall_has(self, i: int, kind: str) -> bool:
        return any(o["wall"] == i and o["kind"] == kind for o in self.openings)

    def zone(self, o: dict, depth: float) -> Rect:
        """Место перед окном или дверью, которое нельзя занимать."""
        i = o["wall"]
        x1, y1, _, _ = self.walls[i]
        dx, dy = self.wall_dir(i)
        n = self.inward(i)
        cx = x1 + dx * o["offset"] + n[0] * depth / 2
        cy = y1 + dy * o["offset"] + n[1] * depth / 2
        return Rect(cx, cy, o["width"], depth, math.atan2(dy, dx), kind=o["kind"])

    def zones(self, height: float = 0.0) -> list[Rect]:
        """Двери и проёмы — всегда; окна — только для мебели выше подоконника."""
        out = []
        for o in self.openings:
            if o["kind"] == "door":
                out.append(self.zone(o, DOOR_ZONE))
            elif o["kind"] == "window":
                if height > (o["bottom"] + 0.05 if o["bottom"] is not None else 0.9):
                    out.append(self.zone(o, WINDOW_ZONE))
            else:
                out.append(self.zone(o, OPENING_ZONE))
        return out

    # ---------- где стоит мебель ----------

    def touching(self, r: Rect) -> list[int]:
        """Стены, к которым прямоугольник стоит вплотную (ближе TOUCH)."""
        out = []
        for i, seg in enumerate(self.walls):
            if min(seg_dist(p, seg) for p in r.corners()) < TOUCH:
                out.append(i)
        return out

    def where(self, r: Rect) -> tuple[str, int | None]:
        """('corner' | 'wall' | 'middle', индекс стены)."""
        near = self.touching(r)
        if not near:
            return "middle", None
        best = min(near, key=lambda i: min(seg_dist(p, self.walls[i]) for p in r.corners()))
        for i in near:
            a, b = self.wall_dir(best), self.wall_dir(i)
            if abs(a[0] * b[0] + a[1] * b[1]) < 0.5:
                return "corner", best
        return "wall", best

    def side(self, i: int) -> str:
        return "long" if self.wall_len(i) >= 0.8 * self.longest else "short"

    def wall_kind(self, i: int) -> str:
        return "window" if self.wall_has(i, "window") else "door" if self.wall_has(i, "door") else self.side(i)

    def wall_title_ru(self, i: int) -> str:
        return WALL_NAMES[self.wall_kind(i)][0]

    def wall_ru(self, i: int) -> str:
        return WALL_NAMES[self.wall_kind(i)][1]

    def wall_en(self, i: int) -> str:
        return WALL_NAMES[self.wall_kind(i)][2]

    def side_en(self, i: int) -> str:
        return WALL_NAMES[self.side(i)][2]

    def place_ru(self, r: Rect) -> str:
        how, i = self.where(r)
        return {"corner": "в углу", "middle": "в центре комнаты"}.get(how) or self.wall_ru(i)

    def place_en(self, r: Rect) -> str:
        how, i = self.where(r)
        if how == "middle":
            return "free-standing in the room"
        return ("in the corner by " if how == "corner" else "against ") + self.wall_en(i)
