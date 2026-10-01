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
  - голос: `createTask` с моделью `elevenlabs/speech-to-text`, `input.audio_url`; текст ищем в resultJson (`kie.find_text`)
  - текст: OpenAI-совместимый `POST https://api.kie.ai/gemini-3-5-flash-openai/v1/chat/completions`
    (путь и модель — в `.env`; ответ бывает в формате `choices` или `candidates`, парсим оба)
- Оплата: Telegram Stars (`currency="XTR"`, `provider_token=""`), возврат — `refund_star_payment`
- PDF: reportlab + шрифт DejaVu из `bot/assets/fonts` (кириллица)
- Mini App: aiohttp в том же процессе (`bot/web.py`), страница `bot/webapp/index.html`,
  каждый запрос API проверяет подпись Telegram `initData`

## Структура
- `bot/__main__.py` — запуск (`python -m bot`), напоминания о сроках этапов, запуск Mini App
- `bot/config.py` — настройки из `.env`, цены (`PRICES`), пакеты Stars (`PACKS`), бонус за друга, лимиты
- `bot/db.py` — пользователи, баланс, `charge()`/`finish_job()`, платежи и возвраты, рефералка,
  объекты/расходы/этапы; миграции колонок в `init_db()`
- `bot/storage.py` — состояния диалогов в SQLite (переживают перезапуск)
- `bot/kie.py` — клиент kie.ai (картинки, текст, голос)
- `bot/calc.py` — калькуляторы материалов (чистые функции)
- `bot/objects.py` — разбор ввода расходов/этапов и сводка по объекту (чистые функции)
- `bot/report.py` — сборка PDF-фотоотчёта
- `bot/prompts.py` — все промпты и стили дизайна
- `bot/web.py`, `bot/webapp/` — Mini App (API + страница); `bot/web_tools.py` — платные ИИ-функции, замер, фотоотчёт, оплата в Mini App
- Сканы с iPhone (СтройСкан): `bot/web_scan.py` — API приложения и Mini App (скан v2, ремонт из 3D `look`,
  фото «как в жизни» `render`, мебель `furniture`); `bot/scan_ai.py` — картинки и смета по скану;
  `bot/room.py` — геометрия комнаты (стены, двери, лучи); `bot/look.py` — проверка и описание ремонта из 3D;
  `bot/furniture.py` — мебель по размерам и ссылки на поиск в магазинах
- `bot/handlers/` — `common` (старт, роли, оплата, рефералка, /paysupport, админка), `tools` (дизайн,
  калькулятор, смета, проверка, консультант, КП), `objects` (учёт объекта), `report` (фотоотчёт),
  `scans` (кнопки под сканом, файл .stroyscan.json в чате), `fallback` (сообщения вне сценария),
  `helpers` (голос → текст, платные задачи)
- `tests/` — `python -m pytest -q`; `test_bot_flows.py` гоняет сценарии через подменённый Telegram
- `deploy/` — примеры systemd и nginx

## Правила
- Любая платная операция: `db.charge()` → вызов ИИ → `db.finish_job(ok)` → `after_paid_success()` (бонус пригласившему).
  При ошибке кредиты (и бесплатный вопрос консультанту) возвращаются автоматически.
- Шаги, где ждём ввод, принимают и текст, и голосовые: фильтр `TEXT_OR_VOICE` + `read_text()`.
- Всё про объекты и сканы проверяет владельца (`owner_id` / `user_id`) — и в боте, и в Mini App, и в приложении.
- Скан из приложения и файл скана из чата сохраняются одним путём: `web_scan.save_scan()` (с фото и ремонтом
  из 3D `look`, если он есть в файле). `clean_scan()` держит скан в пределах (≤40 точных стен по ≤30 м,
  координаты ±100 м, стены не дальше 1 м от контура пола), а `furniture.pick()` зовём через `asyncio.to_thread`:
  тяжёлая геометрия не должна останавливать бота.
- Фото «как в жизни» по снимку 3D: мебель в промпте описываем такой, как в 3D (`facts_en(scan, look)`),
  а в `look_text(..., edited=True)` — только отделку; «убрать/добавить» словами — только для настоящего фото комнаты.
- Ответы моделей шлём как Telegram HTML; если разметка сломана — `send_long` отправит без неё.
- Тексты для пользователей — на русском, дружелюбно, коротко, с эмодзи в заголовках.
- После изменений запускать тесты.

## Статус
Этапы 1 и 2 готовы в коде и покрыты тестами (60). Ещё не проверено на живых ключах: формат ответа
текстовой модели kie.ai, имя модели (`TEXT_MODEL`) и формат результата распознавания голоса —
при первом запуске посмотреть логи и поправить. Mini App включается, когда задан `WEBAPP_URL` (HTTPS).
Мебель по размерам ищется на Яндекс Маркете, Ozon, Wildberries и Divan.ru (формат поиска Divan.ru проверен);
Hoff и Лемана ПРО не добавлены — их адрес поиска не удалось проверить.

## Следующие шаги
1. ~~Портфолио до/после → посты и Reels~~ — готово: bot/portfolio.py, /portfolio, Mini App
2. Перенос на PostgreSQL и webhook, когда пользователей станет много
3. Этап 3 (B2B): несколько сотрудников на объекте, контроль ТБ по фото, акты, поиск по СП/ГОСТ
