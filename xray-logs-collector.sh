#!/usr/bin/env bash
# xray-logs-collector.sh
# Daily collector of xray access/error logs from Remnawave nodes -> Timeweb S3.
#
# Usage:
#   ./xray-logs-collector.sh                # interactive menu
#   ./xray-logs-collector.sh collect        # one-shot collection (cron)
#   ./xray-logs-collector.sh test <ip>      # diagnostic on a single node
#   ./xray-logs-collector.sh install-cron   # add @daily entry
#   ./xray-logs-collector.sh remove-cron    # remove cron entry
#   ./xray-logs-collector.sh status         # show config + last log tail

set -u

# ---------- paths ----------

if [[ -L "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || readlink "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$SCRIPT_PATH")"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

# ---------- colors ----------

if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    CYAN=$'\e[36m'; GRAY=$'\e[37m'; DIM=$'\e[90m'
    BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; GRAY=""; DIM=""; BOLD=""; RESET=""
fi

# ---------- logging ----------

print_message() {
    local type="$1"; shift
    local color
    case "$type" in
        INFO)    color="$DIM" ;;
        SUCCESS) color="$GREEN" ;;
        WARN)    color="$YELLOW" ;;
        ERROR)   color="$RED" ;;
        STEP)    color="$CYAN" ;;
        *)       color="$RESET" ;;
    esac
    echo -e "${color}[$type]${RESET} $*"
}

log_to_file() {
    [[ -n "${LOG_FILE:-}" && -w "$(dirname "$LOG_FILE")" ]] || return 0
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
}

log() {
    # Write to stderr so callers can capture stdout for structured results
    print_message "$1" "$2" >&2
    log_to_file "$1" "$2"
}

# ---------- config ----------

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_message ERROR "Config not found: $CONFIG_FILE"
        print_message INFO  "Run: cp config.env.example config.env && \$EDITOR config.env"
        exit 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a

    SSH_USER="${SSH_USER:-root}"
    SSH_PORT="${SSH_PORT:-22}"
    SSH_TIMEOUT="${SSH_TIMEOUT:-15}"
    SSH_USER_OVERRIDES="${SSH_USER_OVERRIDES:-}"
    REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-/var/log/remnanode}"
    S3_REGION="${S3_REGION:-ru-1}"
    S3_PREFIX="${S3_PREFIX:-xray-logs/}"
    TMP_DIR="${TMP_DIR:-/var/tmp/xray-logs-collector}"
    LOG_FILE="${LOG_FILE:-/var/log/rw-xray-logs.log}"
    LOCK_FILE="${LOCK_FILE:-/var/run/xray-logs-collector.lock}"
    PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

    local missing=()
    for v in PANEL_URL PANEL_TOKEN SSH_KEY_PATH \
             S3_ENDPOINT_URL S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "Missing required config values: ${missing[*]}"
        exit 1
    fi

    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log ERROR "SSH key not found: $SSH_KEY_PATH"
        exit 1
    fi

    mkdir -p "$TMP_DIR" 2>/dev/null || true
    if [[ -n "$LOG_FILE" ]]; then
        local log_dir; log_dir="$(dirname "$LOG_FILE")"
        [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
    fi
}

require_deps() {
    local missing=()
    local cmd
    for cmd in ssh rsync curl jq aws flock; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "Missing dependencies: ${missing[*]}"
        log INFO  "Install: apt-get install -y openssh-client rsync curl jq awscli util-linux"
        exit 1
    fi
}

# ---------- AWS / S3 helpers ----------

aws_s3() {
    AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
    AWS_DEFAULT_REGION="$S3_REGION" \
    aws --endpoint-url "$S3_ENDPOINT_URL" "$@"
}

s3_object_size() {
    aws_s3 s3api head-object --bucket "$S3_BUCKET" --key "$1" \
        --query 'ContentLength' --output text 2>/dev/null
}

s3_upload() {
    local local_path="$1" key="$2"
    aws_s3 s3 cp --only-show-errors "$local_path" "s3://${S3_BUCKET}/${key}"
}

# ---------- SSH helpers ----------

ssh_user_for() {
    local ip="$1" pair k v
    for pair in $SSH_USER_OVERRIDES; do
        k="${pair%%:*}"; v="${pair#*:}"
        if [[ "$k" == "$ip" ]]; then
            echo "$v"; return
        fi
    done
    echo "$SSH_USER"
}

_ssh_opts() {
    echo -n "-o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -i $SSH_KEY_PATH -p $SSH_PORT"
}

ssh_run() {
    local ip="$1"; shift
    local user; user="$(ssh_user_for "$ip")"
    # -n redirects stdin from /dev/null so ssh doesn't consume the parent shell's stdin
    # shellcheck disable=SC2046
    ssh -n $(_ssh_opts) "${user}@${ip}" "$@"
}

ssh_pull() {
    local ip="$1" remote="$2" local_path="$3"
    local user; user="$(ssh_user_for "$ip")"
    rsync -a --partial --inplace -e "ssh $(_ssh_opts)" \
        "${user}@${ip}:${remote}" "$local_path"
}

# ---------- Remnawave API ----------

fetch_nodes() {
    local response
    response=$(curl -sf --max-time 30 \
        -H "Authorization: Bearer $PANEL_TOKEN" \
        -H "Content-Type: application/json" \
        "${PANEL_URL%/}/api/nodes") || return 1
    # Output: "ip<TAB>name" per line, only enabled nodes
    echo "$response" | jq -r '.response[] | select(.isDisabled==false) | "\(.address)\t\(.name)"'
}

# ---------- formatting ----------

human_bytes() {
    local b="${1:-0}"
    if (( b < 1024 )); then printf '%d B' "$b"
    elif (( b < 1048576 )); then awk "BEGIN{printf \"%.1f KB\", $b/1024}"
    elif (( b < 1073741824 )); then awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
    else awk "BEGIN{printf \"%.2f GB\", $b/1073741824}"
    fi
}

# ---------- Telegram ----------

telegram_send() {
    local text="$1"
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0

    local args=(-s -o /dev/null -w '%{http_code}'
        --max-time 30
        -d chat_id="$TELEGRAM_CHAT_ID"
        -d parse_mode=HTML
        -d disable_web_page_preview=true
        --data-urlencode "text=$text")
    [[ -n "${TELEGRAM_TOPIC_ID:-}" ]] && args+=(-d message_thread_id="$TELEGRAM_TOPIC_ID")

    local code
    code=$(curl "${args[@]}" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")
    if [[ "$code" != "200" ]]; then
        log WARN "Telegram send failed (HTTP $code)"
    fi
}

# ---------- per-node collector ----------

# echoes a single result line: "ip|name|status|files|bytes"
collect_node() {
    local ip="$1" name="$2"
    local files_uploaded=0 bytes_uploaded=0 files_skipped=0 errors=0

    log INFO "[$name] $ip — listing rotated logs"

    # Patterns:
    #   access.log.*.gz / error.log.*.gz   — legacy (numbered)
    #   access.log-*.gz / error.log-*.gz   — new dateext (compressed)
    # Uncompressed dateext (access.log-*) is intentionally skipped — they will
    # become .gz on the next logrotate cycle (delaycompress) and be picked up
    # then. rotate=30 buffer ensures nothing is lost.
    local find_cmd="find $REMOTE_LOG_DIR -maxdepth 1 -type f \\( "
    find_cmd+="-name 'access.log.*.gz' -o -name 'access.log-*.gz' "
    find_cmd+="-o -name 'error.log.*.gz' -o -name 'error.log-*.gz' "
    find_cmd+="\\) -printf '%f\\t%s\\t%T@\\n'"

    local listing
    if ! listing=$(ssh_run "$ip" "$find_cmd" 2>/dev/null); then
        log ERROR "[$name] $ip — SSH failed"
        echo "$ip|$name|FAIL_SSH|0|0"
        return 0
    fi

    if [[ -z "$listing" ]]; then
        log INFO "[$name] $ip — no rotated logs"
        echo "$ip|$name|EMPTY|0|0"
        return 0
    fi

    local fname fsize fmtime
    while IFS=$'\t' read -r fname fsize fmtime; do
        [[ -z "$fname" ]] && continue
        local mtime_int="${fmtime%.*}"

        # Build upload name. Legacy files (access.log.N.gz) get renamed to a
        # mtime-derived unique name so cascading numeric rotations don't make
        # us re-upload the same content under a different number.
        local upload_name="$fname"
        if [[ "$fname" =~ ^(access|error)\.log\.[0-9]+\.gz$ ]]; then
            local base="${BASH_REMATCH[1]}"
            local ts; ts=$(date -u -d "@$mtime_int" +%Y-%m-%d_%H-%M-%S 2>/dev/null) \
                || ts=$(date -u -r "$mtime_int" +%Y-%m-%d_%H-%M-%S 2>/dev/null) \
                || ts="legacy"
            upload_name="${base}.log-legacy-${ts}.gz"
        fi

        local year month
        year=$(date -u -d "@$mtime_int" +%Y 2>/dev/null) || year=$(date -u -r "$mtime_int" +%Y 2>/dev/null) || year="0000"
        month=$(date -u -d "@$mtime_int" +%m 2>/dev/null) || month=$(date -u -r "$mtime_int" +%m 2>/dev/null) || month="00"

        local key="${S3_PREFIX}${ip}/${year}/${month}/${upload_name}"

        # Idempotency: skip if S3 already has same-size object under this key.
        local existing_size
        existing_size=$(s3_object_size "$key" || true)
        if [[ -n "$existing_size" && "$existing_size" == "$fsize" ]]; then
            files_skipped=$((files_skipped + 1))
            continue
        fi

        local local_tmp="$TMP_DIR/$$_${ip}_${upload_name}"
        if ! ssh_pull "$ip" "$REMOTE_LOG_DIR/$fname" "$local_tmp"; then
            log WARN "[$name] $ip — pull failed: $fname"
            errors=$((errors + 1))
            rm -f "$local_tmp"
            continue
        fi

        if s3_upload "$local_tmp" "$key" >/dev/null 2>&1; then
            files_uploaded=$((files_uploaded + 1))
            bytes_uploaded=$((bytes_uploaded + fsize))
        else
            log WARN "[$name] $ip — S3 upload failed: $key"
            errors=$((errors + 1))
        fi
        rm -f "$local_tmp"
    done <<< "$listing"

    local status="OK"
    if (( errors > 0 )); then
        status="PARTIAL"
        log WARN "[$name] $ip — uploaded=$files_uploaded skipped=$files_skipped errors=$errors"
    else
        log SUCCESS "[$name] $ip — uploaded=$files_uploaded skipped=$files_skipped"
    fi
    echo "$ip|$name|$status|$files_uploaded|$bytes_uploaded"
}

# ---------- main collect ----------

cmd_collect() {
    # Lock to prevent overlapping cron runs
    exec 200>"$LOCK_FILE" 2>/dev/null || {
        log WARN "Cannot create lock file at $LOCK_FILE — running without lock"
    }
    if ! flock -n 200; then
        log ERROR "Another collector run is in progress (lock held)"
        exit 1
    fi

    local started ended elapsed
    started=$(date +%s)
    log STEP "=== Collection started ==="

    # Cleanup any stale tmp files at exit
    trap 'rm -rf "$TMP_DIR"/*_$$_* 2>/dev/null || true' EXIT

    local nodes
    if ! nodes=$(fetch_nodes); then
        log ERROR "Failed to fetch nodes from Remnawave API"
        telegram_send "❌ <b>Сбор xray-логов</b>%0AОшибка: не удалось получить список нод из Remnawave API."
        exit 1
    fi

    local total
    total=$(echo "$nodes" | grep -cv '^$')
    log INFO "Nodes fetched from API: $total"

    if (( total == 0 )); then
        log WARN "API returned 0 enabled nodes — nothing to do"
        telegram_send "⚠️ <b>Сбор xray-логов</b>%0AAPI вернул 0 активных нод."
        exit 0
    fi

    # Run collection — parallelised via background jobs + per-node result file
    local result_dir; result_dir="$TMP_DIR/results_$$"
    mkdir -p "$result_dir"

    local active=0 ip name
    while IFS=$'\t' read -r ip name; do
        [[ -z "$ip" ]] && continue
        (
            collect_node "$ip" "$name" > "$result_dir/${ip}.result"
        ) </dev/null &
        active=$((active + 1))
        if (( active >= PARALLEL_JOBS )); then
            wait -n 2>/dev/null || wait
            active=$((active - 1))
        fi
    done <<< "$nodes"
    wait

    # Aggregate
    local ok=0 partial=0 ssh_fail=0 empty=0
    local total_files=0 total_bytes=0
    local report_body=""
    local rfile r_ip r_name r_status r_files r_bytes emoji

    # Sort by name for stable report order
    while IFS= read -r rfile; do
        IFS='|' read -r r_ip r_name r_status r_files r_bytes < "$rfile"
        case "$r_status" in
            OK)       ok=$((ok + 1)) ;;
            PARTIAL)  partial=$((partial + 1)) ;;
            FAIL_SSH) ssh_fail=$((ssh_fail + 1)) ;;
            EMPTY)    empty=$((empty + 1)) ;;
        esac
        total_files=$((total_files + r_files))
        total_bytes=$((total_bytes + r_bytes))

        case "$r_status" in
            OK)       emoji=$([ "$r_files" -gt 0 ] && echo "🟢" || echo "⚪️") ;;
            PARTIAL)  emoji="🟡" ;;
            FAIL_SSH) emoji="🔴" ;;
            EMPTY)    emoji="⚪️" ;;
            *)        emoji="❔" ;;
        esac

        if [[ "$r_status" == "FAIL_SSH" ]]; then
            report_body+="${emoji} <b>${r_name}</b> (${r_ip}): SSH недоступен%0A"
        elif (( r_files == 0 )); then
            report_body+="${emoji} <b>${r_name}</b> (${r_ip}): нечего собирать%0A"
        else
            report_body+="${emoji} <b>${r_name}</b> (${r_ip}): ${r_files} файлов, $(human_bytes "$r_bytes")%0A"
        fi
    done < <(find "$result_dir" -type f -name '*.result' | sort)

    rm -rf "$result_dir"

    ended=$(date +%s)
    elapsed=$((ended - started))

    log SUCCESS "=== Collection finished: ok=$ok partial=$partial fail=$ssh_fail empty=$empty / files=$total_files / size=$(human_bytes $total_bytes) / ${elapsed}s ==="

    # Telegram report
    local date_str; date_str=$(date '+%d.%m.%Y %H:%M %Z')
    local total_hb; total_hb=$(human_bytes "$total_bytes")
    local mins=$((elapsed / 60)) secs=$((elapsed % 60))
    local elapsed_str
    if (( mins > 0 )); then elapsed_str="${mins} мин ${secs} сек"; else elapsed_str="${secs} сек"; fi

    local emoji_summary="✅"
    (( ssh_fail > 0 )) && emoji_summary="⚠️"
    (( ok + partial == 0 )) && emoji_summary="❌"

    local report
    report=$(cat <<EOF
${emoji_summary} <b>Сбор xray-логов</b> — ${date_str}

${report_body}
<b>Итого:</b> ${ok}🟢 / ${partial}🟡 / ${ssh_fail}🔴 / ${empty}⚪️ из ${total}
<b>Файлов:</b> ${total_files}
<b>Объём:</b> ${total_hb}
<b>Время:</b> ${elapsed_str}
EOF
)
    # report contains literal "%0A" tokens for line breaks inside per-node block
    # convert them to real newlines before sending
    report="${report//%0A/$'\n'}"
    telegram_send "$report"
}

# ---------- diagnostics ----------

cmd_test() {
    local ip="${1:-}"
    if [[ -z "$ip" ]]; then
        print_message ERROR "Usage: $0 test <ip>"
        exit 1
    fi
    log STEP "Testing node $ip"

    if ! ssh_run "$ip" "echo OK" >/dev/null 2>&1; then
        log ERROR "SSH connection failed (key=$SSH_KEY_PATH user=$(ssh_user_for "$ip"))"
        exit 1
    fi
    log SUCCESS "SSH OK"

    log INFO "Logrotate config on node:"
    ssh_run "$ip" "cat /etc/logrotate.d/remnanode 2>/dev/null || echo '(not found)'" || true
    echo

    log INFO "Files in $REMOTE_LOG_DIR:"
    ssh_run "$ip" "ls -lah $REMOTE_LOG_DIR/ 2>/dev/null" || true
    echo

    log INFO "Files matching collector pattern (compressed only):"
    local find_cmd="find $REMOTE_LOG_DIR -maxdepth 1 -type f \\( "
    find_cmd+="-name 'access.log.*.gz' -o -name 'access.log-*.gz' "
    find_cmd+="-o -name 'error.log.*.gz' -o -name 'error.log-*.gz' "
    find_cmd+="\\) -printf '%f %s bytes (mtime %TY-%Tm-%Td %TH:%TM)\\n' | sort"
    ssh_run "$ip" "$find_cmd" || true
}

# ---------- cron ----------

cmd_install_cron() {
    local entry="0 4 * * * $SCRIPT_PATH collect >> ${LOG_FILE} 2>&1"
    local existing
    existing=$(crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true)
    { [[ -n "$existing" ]] && echo "$existing"; echo "$entry"; } | crontab -
    log SUCCESS "Cron installed: daily at 04:00 server time"
    log INFO    "Entry: $entry"
}

cmd_remove_cron() {
    local existing
    existing=$(crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true)
    if [[ -n "$existing" ]]; then
        echo "$existing" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
    log SUCCESS "Cron entry removed"
}

# ---------- status ----------

cmd_status() {
    print_message STEP "Config: $CONFIG_FILE"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  PANEL_URL:        ${PANEL_URL:-<not set>}"
        echo "  SSH_KEY_PATH:     ${SSH_KEY_PATH:-<not set>}"
        echo "  S3_ENDPOINT_URL:  ${S3_ENDPOINT_URL:-<not set>}"
        echo "  S3_BUCKET:        ${S3_BUCKET:-<not set>}"
        echo "  S3_PREFIX:        ${S3_PREFIX:-<not set>}"
        echo "  TELEGRAM:         $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo "enabled (chat=$TELEGRAM_CHAT_ID)" || echo "disabled")"
        echo "  PARALLEL_JOBS:    ${PARALLEL_JOBS:-1}"
        echo "  LOG_FILE:         ${LOG_FILE:-<not set>}"
    else
        print_message WARN "Config not found"
    fi
    echo
    print_message STEP "Cron entries for this script:"
    crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" || echo "  (none)"
    echo
    print_message STEP "Last 20 log lines:"
    if [[ -f "${LOG_FILE:-}" ]]; then
        tail -20 "$LOG_FILE"
    else
        echo "  (log file not found)"
    fi
}

# ---------- menu ----------

show_menu() {
    while true; do
        echo
        echo -e "${BOLD}xray-logs-collector${RESET} ${DIM}— $SCRIPT_PATH${RESET}"
        echo "  ${CYAN}1${RESET}) Collect now (foreground)"
        echo "  ${CYAN}2${RESET}) Test single node (SSH + listing)"
        echo "  ${CYAN}3${RESET}) Show status (config + cron + log)"
        echo "  ${CYAN}4${RESET}) Install cron (daily 04:00)"
        echo "  ${CYAN}5${RESET}) Remove cron"
        echo "  ${CYAN}q${RESET}) Quit"
        printf '> '
        local choice; read -r choice
        case "$choice" in
            1) cmd_collect ;;
            2) printf 'Node IP: '; read -r ip; cmd_test "$ip" ;;
            3) cmd_status ;;
            4) cmd_install_cron ;;
            5) cmd_remove_cron ;;
            q|Q|"") break ;;
            *) print_message WARN "Unknown choice: $choice" ;;
        esac
    done
}

# ---------- entrypoint ----------

cmd="${1:-menu}"
case "$cmd" in
    collect)
        load_config
        require_deps
        cmd_collect
        ;;
    test)
        load_config
        require_deps
        cmd_test "${2:-}"
        ;;
    install-cron)
        load_config
        cmd_install_cron
        ;;
    remove-cron)
        cmd_remove_cron
        ;;
    status)
        # Try to load config but don't fail if missing
        [[ -f "$CONFIG_FILE" ]] && { set -a; source "$CONFIG_FILE"; set +a; }
        cmd_status
        ;;
    menu|"")
        load_config
        require_deps
        show_menu
        ;;
    -h|--help|help)
        cat <<EOF
xray-logs-collector — daily collector of xray logs from Remnawave nodes

Commands:
  collect          Run a collection (use in cron)
  test <ip>        Diagnose SSH connectivity and list rotated logs on one node
  install-cron     Add @daily 04:00 cron entry
  remove-cron      Remove cron entry
  status           Show config summary + cron + recent log
  menu             Interactive menu (default)
  help             This help

Config: $CONFIG_FILE
EOF
        ;;
    *)
        print_message ERROR "Unknown command: $cmd"
        echo "Run '$0 help' for usage."
        exit 1
        ;;
esac
