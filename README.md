# Postfix Admin Utility

Интерактивный bash-скрипт для администрирования Postfix и SpamAssassin без установки дополнительных пакетов. Предназначен для среды CentOS 7 с Postfix 2.10.1 и SpamAssassin 3.4.0.

## Установка

```bash
cd /opt
git clone https://github.com/geramanic/postfix_menu.git
cd mail_admin
chmod +x start.sh
```

## Структура

```
mail_admin/
├── start.sh               # основной скрипт
├── spam_emls/             # сюда класть .eml для анализа
├── backup/                # резервные копии local.cf
├── rules_generated/       # автогенерированные правила (SpamAssassin)
├── log/                   # логи запуска и действий
└── tmp/                   # временные файлы
```

## Запуск

```bash
./start.sh
```

При старте скрипт предлагает выбрать режим:

* **Симуляция** – команды выполняются в режиме dry‑run, в логах помечается `[SIMULATION]`.
* **Реальная работа** – выполняются реальные команды Postfix/SpamAssassin.

## Возможности

1. **Очередь Postfix** – просмотр очереди, очистка по доменам, ID, диапазону дат и т. д., просмотр письма по QueueID.
2. **SpamAssassin** – добавление сигнатур, анализ `.eml` из `spam_emls/` с генерацией правил `PAYMENT_SPAM_XX`, откат `local.cf` из `backup/`, тест правил через `spamassassin -D`.
3. **Логи Postfix** – последние ошибки, поиск bounce/blocked, поиск по зонам (`.ru`, `.cn`, `.site`), произвольный поиск, топ‑10 правил SpamAssassin.
4. **Диагностика** – размер очереди, deferred, последние ошибки из `maillog`, дата обновления `local.cf`, проверка DNSBL/SPF.

## Логирование

Каждый запуск создаёт файл `log/start_YYYYMMDD_HHMM.log`.
Все действия фиксируются: режим, команды, результат, удалённые письма (ID + From + To).

## Ограничения

Скрипт рассчитан на работу только на CentOS 7 (Core) c Postfix 2.10.1 и SpamAssassin 3.4.0. Установка сторонних пакетов не требуется.

