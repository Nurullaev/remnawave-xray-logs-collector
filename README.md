# remnawave-xray-logs-collector

[ENG | [RU](README-RU.md)]

Daily collector of xray `access`/`error` logs from [Remnawave](https://remna.st) nodes to S3-compatible storage.

Auto-discovers nodes from the panel API, pulls rotated `.gz` files via SSH+rsync, uploads to S3, and posts a Telegram summary. Idempotent — re-runs only upload missing files.

## Features

- 🔄 **Auto-discovery** of nodes via Remnawave panel API (`GET /api/nodes`) — no static inventory to maintain
- 📦 **Idempotent uploads** — checks S3 before each transfer, skips files already present
- ⚡ **Parallel collection** — configurable worker pool
- 🧱 **Lock file** — overlapping cron runs are blocked via `flock`
- 📨 **Telegram report** — per-node status with file counts and sizes
- 🗂 **Stable S3 layout** — `s3://<bucket>/<prefix><node-ip>/<YYYY>/<MM>/<filename>` (IP-based, survives node renames in panel)
- 🧬 **Legacy file handling** — pre-`dateext` files (`access.log.1.gz`, `.2.gz`, ...) are renamed by mtime in S3 to avoid name collisions when logrotate cascades them
- 🐧 **Tested on Ubuntu 22.04 / 24.04** with Timeweb Cloud S3, but works with any S3-compatible storage (AWS, MinIO, Backblaze, Cloudflare R2, etc.)

## How it works

```
                     1. GET /api/nodes
   +-----------+ <----------------------+ Remnawave  +
   | Collector |                        |   panel    |
   |  server   |                        +------------+
   +-----+-----+
         |
         | 2. SSH + rsync (parallel)
         v
   +--------+   +--------+        +--------+
   | Node 1 |   | Node 2 |  ...   | Node N |
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

## Requirements

### Collector server (one)

- Linux (tested on Ubuntu 22.04 / 24.04)
- `bash`, `ssh`, `rsync`, `curl`, `jq`, `awscli` v2, `flock` (`util-linux`)
- A dedicated SSH key with access to all Remnawave nodes
- Remnawave API token with read access to `/api/nodes`
- (Optional) Telegram bot for notifications

### Each Remnawave node

- `rsync` installed (collector pulls files via rsync over SSH)
- Logrotate configured with `dateext` (see [`logrotate-remnanode.conf`](logrotate-remnanode.conf))
- Collector's public key in `/root/.ssh/authorized_keys`

## Installation

### 1. Set up the collector server

```bash
# --- Dependencies ---
apt-get update
apt-get install -y openssh-client rsync curl jq util-linux unzip cron

# AWS CLI v2 (Ubuntu 24.04 dropped awscli from apt)
curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# --- Dedicated SSH key ---
ssh-keygen -t ed25519 -f /root/.ssh/xray_logs_collector -N "" -C "xray-logs-collector"
cat /root/.ssh/xray_logs_collector.pub  # save this — you'll deploy it to nodes

# --- Code ---
git clone https://github.com/Nurullaev/remnawave-xray-logs-collector.git /opt/xray-logs-collector
cd /opt/xray-logs-collector
cp config.env.example config.env
chmod 600 config.env
$EDITOR config.env
```

### 2. Prepare each Remnawave node

On every node listed in your Remnawave panel, run:

```bash
# Install rsync (required for log pull)
apt-get install -y rsync

# Add the collector's public key to root's authorized_keys
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qF "xray-logs-collector" /root/.ssh/authorized_keys || \
  echo 'ssh-ed25519 AAAA... xray-logs-collector' >> /root/.ssh/authorized_keys
#                ^^^^ paste the .pub from step 1

# Install logrotate config (one-time)
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

### 3. Test and schedule

```bash
cd /opt/xray-logs-collector

# Diagnose SSH and listing on a single node
./xray-logs-collector.sh test 1.2.3.4

# One real collection run (foreground)
./xray-logs-collector.sh collect

# Install cron entry (daily at 04:00 server time)
./xray-logs-collector.sh install-cron
```

## Configuration

See [`config.env.example`](config.env.example) for the full list. Required:

| Variable | What it is |
|---|---|
| `PANEL_URL` | Remnawave panel base URL, e.g. `https://panel.example.com` |
| `PANEL_TOKEN` | Bearer token with read access to `/api/nodes` |
| `SSH_KEY_PATH` | Path to private key, e.g. `/root/.ssh/xray_logs_collector` |
| `S3_ENDPOINT_URL` | S3 endpoint, e.g. `https://s3.twcstorage.ru` (Timeweb) |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | S3 credentials |
| `S3_BUCKET` / `S3_REGION` | Bucket name and region |

Optional:

| Variable | Default | Notes |
|---|---|---|
| `S3_PREFIX` | `xray-logs/` | Key prefix inside the bucket |
| `SSH_USER` | `root` | Default SSH user |
| `SSH_USER_OVERRIDES` | empty | Per-IP override, e.g. `"1.2.3.4:ubuntu 5.6.7.8:admin"` |
| `SSH_PORT` | `22` | |
| `PARALLEL_JOBS` | `4` | Number of nodes processed concurrently |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `TELEGRAM_TOPIC_ID` | empty | Leave empty to disable Telegram |
| `LOG_FILE` | `/var/log/rw-xray-logs.log` | |
| `LOCK_FILE` | `/var/run/xray-logs-collector.lock` | |
| `TMP_DIR` | `/var/tmp/xray-logs-collector` | |

## Commands

```bash
./xray-logs-collector.sh collect       # one-shot collection (cron entrypoint)
./xray-logs-collector.sh test <ip>     # diagnose SSH + listing on a single node
./xray-logs-collector.sh install-cron  # add @daily 04:00 cron entry
./xray-logs-collector.sh remove-cron   # remove cron entry
./xray-logs-collector.sh status        # show config + cron + recent log
./xray-logs-collector.sh menu          # interactive menu (default)
./xray-logs-collector.sh help          # usage help
```

## Logrotate notes

- **Why `dateext`?** Without it, rotated files are named `access.log.1.gz`, `.2.gz`, ... and cascade on each rotation (`.1` → `.2` → `.3` → ...). Same name = different content tomorrow, breaking idempotency. With `dateext` each rotated file has a unique date-time suffix that never repeats.
- **Why `rotate 30`?** Buffer of 30 days. Even if the collector misses several days in a row, no data is lost.
- **Why skip uncompressed files?** With `delaycompress`, the most recently rotated file is uncompressed (`.log` without `.gz`) for one cycle before being compressed. The collector intentionally skips these — they'll become `.gz` on the next logrotate run and be picked up then.
- **Logrotate runs once per day** by default (`logrotate.timer` with `OnCalendar=daily`). With `size 50M` the file rotates only if it exceeds 50 MB at the moment of the daily run, so on busy nodes the rotated file may be much larger than 50 MB.

## Troubleshooting

**"SSH connection failed"** for a node — verify the key is in `authorized_keys` and matches `SSH_USER` (root by default). Use `./xray-logs-collector.sh test <ip>` to debug.

**"rsync: command not found"** at the remote end — install rsync on the node: `apt-get install -y rsync`.

**S3 upload errors** — check `aws --endpoint-url ... s3 ls s3://bucket/` works manually with the same creds.

**Telegram not sending** — verify `TELEGRAM_BOT_TOKEN` and that the bot is a member of `TELEGRAM_CHAT_ID` (and the topic for forum chats).

**Files keep re-uploading** — the idempotency check compares S3 `ContentLength` with the remote file size. If they don't match (e.g., file was truncated between runs), the collector overwrites. To force re-collection, delete the S3 object.

## License

MIT — see [LICENSE](LICENSE).
