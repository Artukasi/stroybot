"""ИИ по 3D-скану комнаты: картинка ремонта «как в жизни» и смета по точным размерам.
Общий код для бота (кнопки под сканом), Mini App и приложения СтройСкан."""
import time
from pathlib import Path

from . import kie
from .calc import scan_materials
from .config import config
from .look import FURNITURE, look_en, look_ru
from .prompts import DESIGN_STYLES, ESTIMATE_SYSTEM, SCAN_DESIGN_PROMPT, SCAN_RENDER_PROMPT, SCAN_T2I_PROMPT
from .room import Rect, Room


def photo_dir() -> Path:
    d = Path(config.db_path).resolve().parent / "scan_photos"
    d.mkdir(parents=True, exist_ok=True)
    return d


def photo_path(scan_id: int) -> Path:
    return photo_dir() / f"{scan_id}.jpg"


def _m(v) -> str:
    return f"{v:.2f}".rstrip("0").rstrip(".") if v else "?"


def furniture_ru(scan: dict) -> list[str]:
    out = []
    for o in scan.get("objects") or []:
        name = FURNITURE.get(o.get("kind"), FURNITURE["object"])[0]
        cm = [round(o[k] * 100) for k in ("width", "depth", "height") if o.get(k)]
        out.append(f"{name} {'×'.join(map(str, cm))} см" if cm else name)
    return out


def facts_en(scan: dict) -> str:
    """Размеры, окна, двери и где стоит мебель — для картинки. Модель видит комнату «как есть»."""
    s = scan.get("sizes") or {}
    op = scan.get("openings") or []
    room = Room(scan)
    windows = sum(1 for o in op if o.get("kind") == "window")
    doors = sum(1 for o in op if o.get("kind") == "door")
    parts = [f"{_m(s.get('length'))} m × {_m(s.get('width'))} m floor, ceiling height {_m(s.get('height'))} m",
             f"floor area {_m(s.get('floor_area'))} m2", f"{windows} window(s), {doors} door(s)"]
    placed = []
    for o in room.openings[:8]:
        text = f"{o['kind']} {_m(o['width'])}×{_m(o['height'])} m on {room.side_en(o['wall'])}"
        if o["kind"] == "window" and o["bottom"]:
            text += f", sill at {_m(o['bottom'])} m"
        placed.append(text)
    if placed:
        parts.append("; ".join(placed))
    items = []
    for o in (scan.get("objects") or [])[:15]:
        name = FURNITURE.get(o.get("kind"), FURNITURE["object"])[1]
        cm = "×".join(str(round(o[k] * 100)) for k in ("width", "depth", "height") if o.get(k))
        items.append(" ".join(x for x in (name, f"{cm} cm" if cm else "", room.place_en(Rect.of(o))) if x))
    if items:
        parts.append("furniture: " + ", ".join(items))
    return "; ".join(parts)


def look_text(look: dict | None, scan: dict) -> str:
    desc = look_en(look, scan)
    return (f"The client chose these finishes and furniture, show exactly them: {desc}." if desc
            else "Pick finishes, furniture and lighting that suit the style.")


async def design_image(scan: dict, style: str, look: dict | None = None, photo_url: str | None = None) -> str:
    """URL картинки ремонта. Есть фото комнаты (своё из чата или с iPhone) — ремонт на нём,
    нет — рисуем по размерам. Ремонт, собранный в 3D, тоже учитываем."""
    look = scan.get("look") if look is None else look
    fmt = {"style": DESIGN_STYLES[style][1], "facts": facts_en(scan), "look": look_text(look, scan)}
    photo = photo_path(scan["id"])
    if not photo_url and photo.exists():
        photo_url = await kie.upload_image(photo.read_bytes(), f"scan{scan['id']}_{int(time.time())}.jpg")
    if photo_url:
        urls = await kie.edit_image(photo_url, SCAN_DESIGN_PROMPT.format(**fmt))
    else:
        urls = await kie.generate_image(SCAN_T2I_PROMPT.format(**fmt))
    return urls[0]


async def render_image(scan: dict, image: bytes, style: str, look: dict | None = None) -> str:
    """Снимок 3D-модели ремонта → фото «как в жизни» с той же геометрией и мебелью."""
    look = scan.get("look") if look is None else look
    ext = "png" if image.startswith(b"\x89PNG") else "jpg"
    url = await kie.upload_image(image, f"render{scan['id']}_{int(time.time())}.{ext}")
    urls = await kie.edit_image(url, SCAN_RENDER_PROMPT.format(
        style=DESIGN_STYLES[style][1], facts=facts_en(scan), look=look_text(look, scan)))
    return urls[0]


def estimate_request(scan: dict) -> str:
    """Задание сметчику: точные размеры и объёмы материалов из скана, выбор из 3D."""
    s = scan.get("sizes") or {}
    furniture = furniture_ru(scan)
    chosen = look_ru(scan.get("look"), scan)
    return (
        f"Помещение: {scan.get('room') or 'комната'}. Размеры измерены лидаром iPhone, считай по ним, не выдумывай.\n"
        f"Длина {_m(s.get('length'))} м, ширина {_m(s.get('width'))} м, высота {_m(s.get('height'))} м, "
        f"периметр {_m(s.get('perimeter'))} м, пол {_m(s.get('floor_area'))} м², "
        f"стены без проёмов {_m(s.get('wall_area'))} м², проёмы {_m(s.get('openings_area'))} м².\n"
        + (f"Мебель в комнате: {', '.join(furniture)}.\n" if furniture else "")
        + "Объёмы материалов уже посчитаны:\n" + scan_materials(scan).text()
        + ("\nКлиент собрал ремонт в 3D — считай именно эту отделку и свет, мебель дай отдельным блоком:\n"
           + "\n".join(chosen) if chosen else "")
        + "\nСоставь смету на полный косметический ремонт по этим объёмам."
    )


async def estimate(scan: dict) -> str:
    return await kie.chat(ESTIMATE_SYSTEM, estimate_request(scan))
