# remnawave-xray-logs-collector

[[ENG](README.md) | RU]

Ежедневный сборщик логов xray (`access.log`/`error.log`) с нод [Remnawave](https://remna.st) в S3-совместимое хранилище.

Получает список нод из API панели, забирает ротированные `.gz` файлы по SSH+rsync, грузит в S3 и присылает отчёт в Telegram. Идемпотентно — повторные запуски заливают только недостающие файлы.

## Возможности

- 🔄 **Авто-обнаружение нод** через API панели Remnawave (`GET /api/nodes`) — никакого статичного списка
- 📦 **Идемпотентность** — перед каждой загрузкой проверяет наличие в S3, пропускает уже загруженные файлы
- ⚡ **Параллельная обработка** — настраиваемое количество воркеров
- 🧱 **Lock-файл** — два cron-запуска не пересекутся (`flock`)
- 📨 **Telegram-отчёт** — статус по каждой ноде, кол-во файлов, размеры, итог
- 🗂 **Стабильная структура S3** — `s3://<bucket>/<prefix><node-ip>/<YYYY>/<MM>/<filename>` (по IP, переживает переименование ноды в панели)
- 🧬 **Поддержка legacy-файлов** — старые ротированные файлы (`access.log.1.gz`, `.2.gz`, ...) переименовываются в S3 по mtime, чтобы каскадирование не приводило к перезаписи
- 🐧 **Тестировано на Ubuntu 22.04 / 24.04** с Timeweb Cloud S3, но работает с любым S3-совместимым (AWS, MinIO, Backblaze, Cloudflare R2 и т.д.)

## Как работает

```
                     1. GET /api/nodes
   +-----------+ <----------------------+ Remnawave  +
   | Сборщик   |                        |   panel    |
   +-----+-----+                        +------------+
         |
         | 2. SSH + rsync (параллельно)
         v
   +--------+   +--------+        +--------+
   | Нода 1 |   | Нода 2 |  ...   | Нода N |
   +--------+   +--------+        +--------+
         |           |                  |
         | 3. aws s3 cp                 |
         v                              v
   +-----------------------------------------+
   |   S3 (Timeweb / AWS / MinIO / R2 / …)   |
   +-----------------------------------------+
                       |
                       | 4. POST /sendMessage
                       v
                 +-----------+
                 |  Telegram |
                 +-----------+
```

## Требования

### Сервер сборщика (один)

- Linux (тестировал на Ubuntu 22.04 / 24.04)
- `bash`, `ssh`, `rsync`, `curl`, `jq`, `awscli` v2, `flock` (`util-linux`)
- Отдельный SSH-ключ с доступом ко всем нодам Remnawave
- API-токен Remnawave с правом чтения `/api/nodes`
- (Опционально) Telegram-бот для уведомлений

### Каждая нода Remnawave

- Установлен `rsync` (сборщик забирает файлы через rsync поверх SSH)
- Настроен logrotate с `dateext` (см. [`logrotate-remnanode.conf`](logrotate-remnanode.conf))
- Публичный ключ сборщика в `/root/.ssh/authorized_keys`

## Установка

### 1. На сервере сборщика

```bash
# --- Зависимости ---
apt-get update
apt-get install -y openssh-client rsync curl jq util-linux unzip cron

# AWS CLI v2 (Ubuntu 24.04 убрал awscli из apt)
curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# --- Отдельный SSH-ключ ---
ssh-keygen -t ed25519 -f /root/.ssh/xray_logs_collector -N "" -C "xray-logs-collector"
cat /root/.ssh/xray_logs_collector.pub  # сохрани — будем раскатывать на ноды

# --- Код ---
git clone https://github.com/Nurullaev/remnawave-xray-logs-collector.git /opt/xray-logs-collector
cd /opt/xray-logs-collector
cp config.env.example config.env
chmod 600 config.env
$EDITOR config.env
```

### 2. На каждой ноде Remnawave

На каждой ноде из панели выполни:

```bash
# Установка rsync (нужен сборщику для забора файлов)
apt-get install -y rsync

# Добавление публичного ключа сборщика
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qF "xray-logs-collector" /root/.ssh/authorized_keys || \
  echo 'ssh-ed25519 AAAA... xray-logs-collector' >> /root/.ssh/authorized_keys
#                ^^^^ вставь .pub из шага 1

# Установка logrotate-конфига (один раз)
cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    su root root
    size 50M
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y-%m-%d_%H-%M-%S
}
EOF
```

### 3. Тест и расписание

```bash
cd /opt/xray-logs-collector

# Диагностика SSH и листинг файлов на одной ноде
./xray-logs-collector.sh test 1.2.3.4

# Один реальный сбор (foreground)
./xray-logs-collector.sh collect

# Установка cron (ежедневно в 04:00 серверного времени)
./xray-logs-collector.sh install-cron
```

## Настройки

См. [`config.env.example`](config.env.example) — полный список. Обязательные:

| Переменная | Описание |
|---|---|
| `PANEL_URL` | URL панели Remnawave, напр. `https://panel.example.com` |
| `PANEL_TOKEN` | Bearer-токен с правом чтения `/api/nodes` |
| `SSH_KEY_PATH` | Путь к приватному ключу, напр. `/root/.ssh/xray_logs_collector` |
| `S3_ENDPOINT_URL` | S3 endpoint, напр. `https://s3.twcstorage.ru` (Timeweb) |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | Креды S3 |
| `S3_BUCKET` / `S3_REGION` | Имя бакета и регион |

Необязательные:

| Переменная | По умолчанию | Описание |
|---|---|---|
| `S3_PREFIX` | `xray-logs/` | Префикс ключа внутри бакета |
| `SSH_USER` | `root` | Пользователь по умолчанию |
| `SSH_USER_OVERRIDES` | пусто | Переопределение для конкретных IP, напр. `"1.2.3.4:ubuntu 5.6.7.8:admin"` |
| `SSH_PORT` | `22` | |
| `PARALLEL_JOBS` | `4` | Сколько нод обрабатывать параллельно |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `TELEGRAM_TOPIC_ID` | пусто | Оставь пустым чтобы выключить Telegram |
| `LOG_FILE` | `/var/log/rw-xray-logs.log` | |
| `LOCK_FILE` | `/var/run/xray-logs-collector.lock` | |
| `TMP_DIR` | `/var/tmp/xray-logs-collector` | |

## Команды

```bash
./xray-logs-collector.sh collect       # один цикл сбора (для cron)
./xray-logs-collector.sh test <ip>     # диагностика SSH + листинг для одной ноды
./xray-logs-collector.sh install-cron  # добавить @daily 04:00 в cron
./xray-logs-collector.sh remove-cron   # убрать запись из cron
./xray-logs-collector.sh status        # показать конфиг + cron + хвост лога
./xray-logs-collector.sh menu          # интерактивное меню (по умолчанию)
./xray-logs-collector.sh help          # справка
```

## Про logrotate

- **Зачем `dateext`?** Без него ротированные файлы называются `access.log.1.gz`, `.2.gz`, ... и каскадируются на каждой ротации (`.1` → `.2` → `.3` → ...). То же имя — другое содержимое завтра, идемпотентность ломается. С `dateext` каждый файл получает уникальный datetime-суффикс, который никогда не повторяется.
- **Зачем `rotate 30`?** 30-дневный буфер. Даже если сборщик пропустит несколько дней подряд — данные не потеряются.
- **Почему пропускаем несжатые файлы?** При `delaycompress` самый свежий ротированный файл лежит без `.gz` один цикл, потом сжимается. Сборщик специально пропускает такие — на следующей ротации они станут `.gz` и попадут в S3.
- **Logrotate стандартно запускается раз в сутки** (`logrotate.timer`, `OnCalendar=daily`). С `size 50M` файл ротируется только если в момент запуска он превысил 50 MB — то есть на нагруженной ноде в 00:00 ротируется один файл, который накопил за сутки куда больше 50 MB.

## Решение проблем

**«SSH connection failed»** для ноды — проверь, что ключ в `authorized_keys` и совпадает с `SSH_USER` (root по умолчанию). Запусти `./xray-logs-collector.sh test <ip>` для диагностики.

**«rsync: command not found»** на удалённой стороне — поставь rsync на ноду: `apt-get install -y rsync`.

**Ошибки загрузки в S3** — проверь, что `aws --endpoint-url ... s3 ls s3://bucket/` работает руками с теми же кредами.

**Telegram не отправляется** — проверь `TELEGRAM_BOT_TOKEN` и что бот добавлен в `TELEGRAM_CHAT_ID` (и в топик для форум-чатов).

**Файлы переливаются повторно** — проверка идемпотентности сравнивает `ContentLength` в S3 с размером удалённого файла. Если не совпадают (например, файл был truncate-ан между запусками) — сборщик перезатрёт. Чтобы форсировать пересбор — удали объект в S3.

## Лицензия

MIT — см. [LICENSE](LICENSE).
