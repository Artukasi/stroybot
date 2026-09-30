import os
from dataclasses import dataclass, field

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class Config:
    bot_token: str = os.getenv("BOT_TOKEN", "")
    kie_api_key: str = os.getenv("KIE_API_KEY", "")
    admin_ids: frozenset[int] = field(
        default_factory=lambda: frozenset(
            int(x) for x in os.getenv("ADMIN_IDS", "").replace(" ", "").split(",") if x
        )
    )
    text_model_path: str = os.getenv(
        "TEXT_MODEL_PATH", "/gemini-3-5-flash-openai/v1/chat/completions"
    )
    text_model: str = os.getenv("TEXT_MODEL", "gemini-3-5-flash")
    image_model: str = os.getenv("IMAGE_MODEL", "google/nano-banana-edit")
    db_path: str = os.getenv("DB_PATH", "stroybot.db")
    welcome_credits: int = int(os.getenv("WELCOME_CREDITS", "3"))
    stt_model: str = os.getenv("STT_MODEL", "elevenlabs/speech-to-text")
    # Mini App: публичный HTTPS-адрес, по которому Telegram откроет веб-интерфейс.
    # Пусто — кнопка Mini App не показывается, веб-сервер не запускается.
    webapp_url: str = os.getenv("WEBAPP_URL", "").rstrip("/")
    web_host: str = os.getenv("WEB_HOST", "127.0.0.1")
    web_port: int = int(os.getenv("WEB_PORT", "8080"))
    support_contact: str = os.getenv("SUPPORT_CONTACT", "")


config = Config()

# Стоимость функций в кредитах. 1 кредит ≈ 1 генерация картинки.
PRICES = {
    "design": 2,     # дизайн интерьера по фото
    "check": 1,      # проверка работы бригады по фото
    "estimate": 1,   # смета
    "consult": 1,    # вопрос консультанту
    "kp": 1,         # коммерческое предложение (прораб)
    "report": 1,     # фотоотчёт в PDF (ИИ пишет резюме для заказчика)
    "advice": 1,     # советы прораба по объекту
    "measure": 1,    # замер по скану или скриншоту из приложения-рулетки
}

# Бонус пригласившему, когда приглашённый впервые воспользовался платной функцией
REFERRAL_BONUS = 3

# Голосовые: максимальная длина (сек). Распознавание бесплатное.
VOICE_MAX_SECONDS = 180

# Фотоотчёт: максимум фото в одном отчёте
REPORT_MAX_PHOTOS = 20

# Бесплатные вопросы консультанту в день
FREE_CONSULT_PER_DAY = 3

# Пакеты кредитов за Telegram Stars: (id, кредиты, звёзды)
PACKS = [
    ("s", 10, 100),
    ("m", 30, 250),
    ("l", 100, 700),
]
