# СтройБот — контекст для Claude Code

Telegram-бот-помощник по ремонту и стройке. Владелец проекта — Артём (не программист,
объясняй простым языком, по-русски). Полное ТЗ и план этапов — `docs/TZ.md`.

## Стек
- Python 3.11+, aiogram 3 (long polling), aiosqlite (SQLite), aiohttp
- ИИ через агрегатор **kie.ai** (один ключ `KIE_API_KEY`):
  - картинки: `POST https://api.kie.ai/api/v1/jobs/createTask` (модель `google/nano-banana-edit`),
    статус: `GET /api/v1/jobs/recordInfo?taskId=` → `data.state` (waiting/queuing/generating/success/fail),
    результат в `data.resultJson` → `resultUrls`
  - загрузка фото: `POST https://kieai.redpandaai.co/api/file-base64-upload` → `data.downloadUrl` (живёт ~3 дня)
  - текст: OpenAI-совместимый `POST https://api.kie.ai/gemini-3-5-flash-openai/v1/chat/completions`
    (путь и модель — в `.env`; ответ бывает в формате `choices` или `candidates`, парсим оба)
- Оплата: Telegram Stars (`currency="XTR"`, `provider_token=""`)

## Структура
- `bot/__main__.py` — запуск (`python -m bot`)
- `bot/config.py` — настройки из `.env`, цены функций (`PRICES`), пакеты Stars (`PACKS`)
- `bot/db.py` — пользователи, баланс, атомарное списание `charge()`, возврат `finish_job(ok=False)`, платежи с защитой от дублей
- `bot/kie.py` — клиент kie.ai
- `bot/calc.py` — калькуляторы материалов (чистые функции, покрыты тестами)
- `bot/prompts.py` — все промпты и стили дизайна (главный рычаг качества)
- `bot/handlers/common.py` — старт, роли, меню, баланс, оплата, админ (`/stats`, `/give`)
- `bot/handlers/tools.py` — дизайн по фото, калькулятор, смета, проверка работы, консультант, КП
- `tests/` — `python -m pytest -q`

## Правила
- Любая платная операция: `db.charge()` → вызов ИИ → `db.finish_job(ok)`. При ошибке кредиты возвращаются автоматически.
- Ответы моделей шлём как Telegram HTML; если разметка сломана — `send_long` отправит без неё.
- Тексты для пользователей — на русском, дружелюбно, коротко, с эмодзи в заголовках.
- После изменений запускать тесты.

## Статус
Этап 1 готов (см. `docs/TZ.md`). Ещё не проверено на живых ключах: формат ответа текстовой модели
kie.ai и точное имя модели (`TEXT_MODEL`) — при первом запуске посмотреть логи и поправить.

## Следующие шаги (этап 2)
1. Голосовые сообщения: распознавание (ElevenLabs STT через kie.ai) → в смету/КП/отчёт
2. Фотоотчёт прораба: фото + голос → PDF для заказчика
3. Учёт объекта: объекты, расходы на материалы, выплаты, этапы
4. Mini App (веб-интерфейс внутри Telegram) для смет и учёта
5. Реферальная программа (+кредиты за друга)
6. Перенос на PostgreSQL и webhook, когда пользователей станет много
