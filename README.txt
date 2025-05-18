Заполните example.env, в .env

установите докер, и запустите стартовый скрипт

sudo ./start.sh

дождитесь установки, и запуска приложения


## Настройка алертов в Telegram

1. Создайте Telegram-бот:
   - Найдите "@BotFather" в Telegram, отправьте "/newbot".
   - Задайте имя боту, получите токен.

2. Получите Chat ID:
   - Напишите боту "/start".
   - в консоли curl https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates.
   - Найдите "chat.id".

3. Настройте ".env":
   - Скопируйте "example.env" в ".env".
   - Укажите TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в ".env".

5. Алерты:
   - Уведомления приходят в Telegram, если:
     - Microblog не работает.
     - Nginx возвращает много ошибок 5xx.
   - Настройки в "alerts.yml" и "alertmanager.yml".
