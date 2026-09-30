"""Портфолио «до/после»: картинка для поста и вертикальное видео для Reels / Shorts / Клипов.
Рисуем сами (Pillow + ffmpeg из пакета imageio-ffmpeg), без платных сервисов."""
import io
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

from .config import config

FONTS = Path(__file__).parent / "assets" / "fonts"
SIGNAL = (245, 197, 24)
INK = (20, 32, 46)
PAPER = (246, 248, 250)
W, H, FPS = 720, 1280, 30


def photo_dir() -> Path:
    d = Path(config.db_path).resolve().parent / "portfolio"
    d.mkdir(parents=True, exist_ok=True)
    return d


def photo_path(item_id: int, side: str) -> Path:
    return photo_dir() / f"{item_id}_{side}.jpg"


def save_photo(item_id: int, side: str, data: bytes) -> None:
    """Сохраняем уменьшенную копию (длинная сторона ≤ 1600), с учётом поворота из EXIF."""
    img = ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert("RGB")
    img.thumbnail((1600, 1600))
    img.save(photo_path(item_id, side), "JPEG", quality=88)


def _font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / ("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf")), size)


def _cover(img: Image.Image, w: int, h: int) -> Image.Image:
    return ImageOps.fit(img, (w, h), Image.LANCZOS)


def _tag(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, size: int = 34, dark: bool = False) -> None:
    font = _font(size)
    x, y = xy
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    pad = size // 2
    fill, color = (INK, PAPER) if dark else (SIGNAL, INK)
    draw.rounded_rectangle((x, y, x + r - l + pad * 2, y + b - t + pad * 1.4), radius=size, fill=fill)
    draw.text((x + pad - l, y + pad * 0.7 - t), text, font=font, fill=color)


def collage(before: Path, after: Path, title: str = "", brand: str = "") -> bytes:
    """Квадрат 1080×1080: слева «до», справа «после», подпись снизу. Для поста в Telegram / VK."""
    size, bar = 1080, 120 if (title or brand) else 0
    a, b = Image.open(before).convert("RGB"), Image.open(after).convert("RGB")
    canvas = Image.new("RGB", (size, size), PAPER)
    half = (size - 8) // 2
    canvas.paste(_cover(a, half, size - bar), (0, 0))
    canvas.paste(_cover(b, half, size - bar), (half + 8, 0))
    d = ImageDraw.Draw(canvas)
    _tag(d, (24, 24), "ДО", dark=True)
    _tag(d, (half + 32, 24), "ПОСЛЕ")
    if bar:
        d.rectangle((0, size - bar, size, size), fill=INK)
        d.text((32, size - bar + 26), (title or "")[:48], font=_font(40), fill=PAPER)
        if brand:
            d.text((32, size - bar + 76), brand[:60], font=_font(26, bold=False), fill=SIGNAL)
    out = io.BytesIO()
    canvas.save(out, "JPEG", quality=90)
    return out.getvalue()


def _ease(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def _frames(before: Path, after: Path, title: str, brand: str):
    """Сценарий 8 секунд: «до» с лёгким наездом → жёлтая шторка открывает «после» →
    «после» → сравнение половинками → финальная карточка с подписью."""
    base_a = _cover(Image.open(before).convert("RGB"), int(W * 1.08), int(H * 1.08))
    base_b = _cover(Image.open(after).convert("RGB"), int(W * 1.08), int(H * 1.08))

    def zoom(img: Image.Image, k: float) -> Image.Image:
        # k от 0 до 1: плавный наезд камеры на 8%
        w, h = int(W * (1.08 - 0.08 * k)), int(H * (1.08 - 0.08 * k))
        x, y = (img.width - w) // 2, (img.height - h) // 2
        return img.crop((x, y, x + w, y + h)).resize((W, H), Image.BILINEAR)

    total = FPS * 8
    for i in range(total):
        t = i / FPS
        if t < 1.8:                                   # до
            frame = zoom(base_a, t / 1.8)
            d = ImageDraw.Draw(frame)
            _tag(d, (40, 80), "ДО", 44, dark=True)
        elif t < 3.6:                                 # шторка слева направо
            k = _ease((t - 1.8) / 1.8)
            frame = zoom(base_a, 1.0)
            x = int(W * k)
            if x > 0:
                frame.paste(zoom(base_b, 0.0).crop((0, 0, x, H)), (0, 0))
            d = ImageDraw.Draw(frame)
            d.rectangle((x - 5, 0, x + 5, H), fill=SIGNAL)
        elif t < 5.4:                                 # после
            frame = zoom(base_b, (t - 3.6) / 1.8)
            d = ImageDraw.Draw(frame)
            _tag(d, (40, 80), "ПОСЛЕ", 44)
        elif t < 6.8:                                 # сравнение: верх до, низ после
            frame = Image.new("RGB", (W, H), INK)
            frame.paste(_cover(base_a, W, H // 2 - 4), (0, 0))
            frame.paste(_cover(base_b, W, H // 2 - 4), (0, H // 2 + 4))
            d = ImageDraw.Draw(frame)
            _tag(d, (32, 32), "ДО", 36, dark=True)
            _tag(d, (32, H // 2 + 36), "ПОСЛЕ", 36)
        else:                                         # финальная карточка
            frame = zoom(base_b, 1.0)
            k = _ease((t - 6.8) / 0.4)
            shade = Image.new("RGB", (W, H), INK)
            frame = Image.blend(frame, shade, 0.55 * k)
            d = ImageDraw.Draw(frame)
            y = H // 2 - 90
            for line in _wrap(title or "Ремонт под ключ", _font(52), W - 96)[:3]:
                d.text((48, y), line, font=_font(52), fill=PAPER)
                y += 66
            if brand:
                d.rectangle((48, y + 20, 48 + 90, y + 28), fill=SIGNAL)
                d.text((48, y + 44), brand[:40], font=_font(34, bold=False), fill=SIGNAL)
        yield frame


def _wrap(text: str, font: ImageFont.FreeTypeFont, width: int) -> list[str]:
    lines, cur = [], ""
    for word in text.split():
        test = f"{cur} {word}".strip()
        if font.getlength(test) <= width or not cur:
            cur = test
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def reel(before: Path, after: Path, title: str = "", brand: str = "") -> bytes:
    """Вертикальное видео 720×1280, 8 секунд, MP4 (H.264) — подходит для Reels, Shorts и VK Клипов."""
    import os
    import tempfile

    import imageio_ffmpeg

    fd, tmp = tempfile.mkstemp(suffix=".mp4")
    os.close(fd)
    try:
        writer = imageio_ffmpeg.write_frames(tmp, (W, H), fps=FPS, codec="libx264", quality=None,
                                             bitrate="3000k", pix_fmt_out="yuv420p",
                                             output_params=["-movflags", "+faststart"], macro_block_size=16)
        writer.send(None)
        for frame in _frames(before, after, title, brand):
            writer.send(frame.tobytes())
        writer.close()
        return Path(tmp).read_bytes()
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


# ---------- общее для бота и Mini App ----------

def has_photos(item_id: int) -> bool:
    return photo_path(item_id, "before").exists() and photo_path(item_id, "after").exists()


def delete_photos(item_id: int) -> None:
    for side in ("before", "after"):
        photo_path(item_id, side).unlink(missing_ok=True)


def item_collage(item: dict, brand: str = "") -> bytes:
    return collage(photo_path(item["id"], "before"), photo_path(item["id"], "after"), item.get("title") or "", brand)


async def post_text(item: dict, brand: str = "") -> str:
    """Текст поста: модель смотрит на коллаж «до/после» и пишет продающий пост."""
    import time

    from . import kie
    from .prompts import PORTFOLIO_POST_SYSTEM
    url = await kie.upload_image(item_collage(item), f"pf{item['id']}_{int(time.time())}.jpg")
    task = f"Работа: {item.get('title') or 'ремонт'}." + (f" Подпись и контакты мастера: {brand}." if brand else "")
    return await kie.chat(PORTFOLIO_POST_SYSTEM, task, image_url=url, max_tokens=1200)


async def item_reel(item: dict, brand: str = "") -> bytes:
    import asyncio
    return await asyncio.to_thread(reel, photo_path(item["id"], "before"), photo_path(item["id"], "after"),
                                   item.get("title") or "", brand)
