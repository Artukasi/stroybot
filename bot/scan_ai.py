"""ИИ по 3D-скану комнаты: картинка готового ремонта и смета по точным размерам.
Общий код для бота (кнопки под сканом), Mini App и приложения СтройСкан."""
import time
from pathlib import Path

from . import kie
from .calc import scan_materials
from .config import config
from .prompts import DESIGN_STYLES, ESTIMATE_SYSTEM

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

SCAN_DESIGN_PROMPT = (
    "Redesign this room photo as a finished interior renovation in {style}. "
    "Keep the exact same room geometry, camera angle, walls, windows and doors positions. "
    "Room facts from a LiDAR scan: {facts}. Keep the furniture in the same places, "
    "restyle it to match. Replace finishes, furniture style and lighting. "
    "Photorealistic interior photography, high detail."
)
SCAN_T2I_PROMPT = (
    "Photorealistic interior photograph of a finished renovation in {style}. "
    "Real room measured with a LiDAR scan: {facts}. Wide-angle view from the doorway, eye level, "
    "natural daylight from the windows, realistic proportions matching the sizes. High detail."
)


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
    s = scan.get("sizes") or {}
    op = scan.get("openings") or []
    windows = sum(1 for o in op if o.get("kind") == "window")
    doors = sum(1 for o in op if o.get("kind") == "door")
    parts = [f"{_m(s.get('length'))} m × {_m(s.get('width'))} m floor, ceiling height {_m(s.get('height'))} m",
             f"floor area {_m(s.get('floor_area'))} m2", f"{windows} window(s), {doors} door(s)"]
    items = [FURNITURE.get(o.get("kind"), FURNITURE["object"])[1] for o in scan.get("objects") or []]
    if items:
        parts.append("furniture: " + ", ".join(items[:15]))
    return "; ".join(parts)


async def design_image(scan: dict, style: str) -> str:
    """URL картинки ремонта. Есть фото с iPhone — перекрашиваем его, нет — рисуем по размерам."""
    prompt_style = DESIGN_STYLES[style][1]
    photo = photo_path(scan["id"])
    if photo.exists():
        url = await kie.upload_image(photo.read_bytes(), f"scan{scan['id']}_{int(time.time())}.jpg")
        urls = await kie.edit_image(url, SCAN_DESIGN_PROMPT.format(style=prompt_style, facts=facts_en(scan)))
    else:
        urls = await kie.generate_image(SCAN_T2I_PROMPT.format(style=prompt_style, facts=facts_en(scan)))
    return urls[0]


def estimate_request(scan: dict) -> str:
    """Задание сметчику: точные размеры и объёмы материалов из скана."""
    s = scan.get("sizes") or {}
    furniture = furniture_ru(scan)
    return (
        f"Помещение: {scan.get('room') or 'комната'}. Размеры измерены лидаром iPhone, считай по ним, не выдумывай.\n"
        f"Длина {_m(s.get('length'))} м, ширина {_m(s.get('width'))} м, высота {_m(s.get('height'))} м, "
        f"периметр {_m(s.get('perimeter'))} м, пол {_m(s.get('floor_area'))} м², "
        f"стены без проёмов {_m(s.get('wall_area'))} м², проёмы {_m(s.get('openings_area'))} м².\n"
        + (f"Мебель в комнате: {', '.join(furniture)}.\n" if furniture else "")
        + "Объёмы материалов уже посчитаны:\n" + scan_materials(scan).text()
        + "\nСоставь смету на полный косметический ремонт по этим объёмам."
    )


async def estimate(scan: dict) -> str:
    return await kie.chat(ESTIMATE_SYSTEM, estimate_request(scan))
