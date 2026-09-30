"""Фотоотчёт для заказчика в PDF (reportlab + шрифт DejaVu с кириллицей)."""
import html
import io
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Image, KeepTogether, Paragraph, SimpleDocTemplate, Spacer

FONTS = Path(__file__).parent / "assets" / "fonts"
_registered = False


def _fonts() -> None:
    global _registered
    if not _registered:
        pdfmetrics.registerFont(TTFont("DejaVu", str(FONTS / "DejaVuSans.ttf")))
        pdfmetrics.registerFont(TTFont("DejaVu-Bold", str(FONTS / "DejaVuSans-Bold.ttf")))
        pdfmetrics.registerFontFamily("DejaVu", normal="DejaVu", bold="DejaVu-Bold")
        _registered = True


def _para(text: str) -> str:
    """Экранирует текст и сохраняет переносы строк для Paragraph."""
    return html.escape(text or "").replace("\n", "<br/>")


def build_pdf(title: str, items: list[tuple[bytes, str]], summary: str = "",
              author: str = "", when: date | None = None) -> bytes:
    """items — список (фото в байтах, подпись). Возвращает PDF в байтах."""
    _fonts()
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=18 * mm, rightMargin=18 * mm,
                            topMargin=16 * mm, bottomMargin=16 * mm, title=title, author=author)
    h1 = ParagraphStyle("h1", fontName="DejaVu-Bold", fontSize=18, leading=23, spaceAfter=4)
    meta = ParagraphStyle("meta", fontName="DejaVu", fontSize=9.5, leading=13, textColor=colors.grey)
    body = ParagraphStyle("body", fontName="DejaVu", fontSize=11, leading=15, alignment=TA_LEFT)
    cap = ParagraphStyle("cap", parent=body, fontSize=10.5, spaceBefore=4)

    story = [Paragraph(_para(title), h1)]
    info = (when or date.today()).strftime("%d.%m.%Y")
    if author:
        info = f"{_para(author)} · {info}"
    story += [Paragraph(info, meta), Spacer(1, 6 * mm)]
    if summary:
        story += [Paragraph(_para(summary), body), Spacer(1, 6 * mm)]

    max_w, max_h = doc.width, 120 * mm
    for i, (photo, caption) in enumerate(items, 1):
        reader = ImageReader(io.BytesIO(photo))
        w, h = reader.getSize()
        scale = min(max_w / w, max_h / h)
        img = Image(io.BytesIO(photo), width=w * scale, height=h * scale)
        block = [img, Paragraph(f"<b>Фото {i}.</b> {_para(caption)}" if caption else f"<b>Фото {i}</b>", cap),
                 Spacer(1, 7 * mm)]
        story.append(KeepTogether(block))
    doc.build(story)
    return buf.getvalue()
