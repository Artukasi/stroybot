# СтройБот 🏗

Telegram-бот: дизайн комнаты по фото, калькулятор материалов, смета, проверка работы бригады,
консультант по ремонту, коммерческие предложения для прорабов. Оплата — Telegram Stars.

## Что нужно заранее
1. **Токен бота** — написать @BotFather → `/newbot` → скопировать токен.
2. **Ключ kie.ai** — зарегистрироваться на kie.ai, пополнить баланс (для тестов хватит ~$5–10),
   взять ключ на странице API Key.
3. **Свой Telegram ID** — написать @userinfobot.
4. **Python 3.11+** на компьютере или сервере.

## Запуск
```bash
cd stroybot
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env               # Windows: copy .env.example .env
# откройте .env и впишите BOT_TOKEN, KIE_API_KEY, ADMIN_IDS
python -m bot
```
Откройте бота в Telegram и нажмите /start.

## Команды админа
- `/stats` — пользователи, звёзды, генерации
- `/give <user_id> <кредиты>` — начислить кредиты (например, себе для тестов)

## Где что менять
- Цены и пакеты — `bot/config.py`
- Промпты, стили дизайна — `bot/prompts.py`
- Тексты кнопок — `bot/keyboards.py`

## Продолжить в Claude Code
Откройте папку `stroybot` в Claude Code — контекст проекта лежит в `CLAUDE.md`, план — в `docs/TZ.md`.
Например: «Сделай этап 2, пункт 1 — голосовые сообщения».

## Сервер (когда будете готовы)
VPS с Ubuntu (Timeweb, Beget, Selectel — от 300 ₽/мес), тот же запуск + systemd или `screen`,
чтобы бот работал постоянно.
