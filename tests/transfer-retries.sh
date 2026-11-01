#!/usr/bin/env bash
# Regression checks without network, S3, Telegram, or production configuration.
set -eu
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/xray-logs-collector.sh" help >/dev/null
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
LOG_FILE="$scratch/collector.log"
TMP_DIR="$scratch"
SSH_USER=root SSH_PORT=22 SSH_TIMEOUT=15 SSH_KEY_PATH=/unused
SSH_HOST_OVERRIDES='' SSH_USER_OVERRIDES=''
REMOTE_LOG_DIR=/var/log/remnanode S3_PREFIX=xray-logs/
REMOTE_RETENTION_DAYS=2
touch "$LOG_FILE"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset_probe() {
    printf '0\n' > "$scratch/calls"
    : > "$scratch/sleeps"
    : > "$LOG_FILE"
    rm -f "$scratch/uploaded" "$scratch/purged"
}
sleep() { printf '%s\n' "$1" >> "$scratch/sleeps"; }
rsync() {
    local n last
    n=$(cat "$scratch/calls"); n=$((n + 1))
    printf '%s\n' "$n" > "$scratch/calls"
    if (( n <= fail_count )); then
        printf 'synthetic connection reset\n' >&2
        return 255
    fi
    for last in "$@"; do :; done
    printf data > "$last"
}

reset_probe; fail_count=0
ssh_pull 192.0.2.1 /logs/access.gz "$scratch/pull" > "$scratch/stdout" 2> "$scratch/stderr"
[[ $(cat "$scratch/calls") == 1 && ! -s "$scratch/sleeps" && ! -s "$scratch/stdout" ]] || fail 'first-attempt success'

reset_probe; fail_count=2
ssh_pull 192.0.2.1 /logs/access.gz "$scratch/pull" > "$scratch/stdout" 2> "$scratch/stderr"
[[ $(cat "$scratch/calls") == 3 && $(wc -l < "$scratch/sleeps" | tr -d ' ') == 2 ]] || fail 'retry count/delay'
grep -q 'attempt 1/3 failed (exit=255)' "$LOG_FILE" || fail 'exit code missing'
grep -q 'synthetic connection reset' "$LOG_FILE" || fail 'rsync stderr missing'
grep -q 'recovered on attempt 3/3' "$LOG_FILE" || fail 'recovery missing'
[[ ! -s "$scratch/stdout" ]] || fail 'diagnostics polluted structured stdout'

reset_probe; fail_count=3
if ssh_pull 192.0.2.1 /logs/access.gz "$scratch/pull" > "$scratch/stdout" 2> "$scratch/stderr"; then
    fail 'exhausted retries reported success'
else
    rc=$?
fi
[[ "$rc" == 255 && $(cat "$scratch/calls") == 3 ]] || fail 'last error code/count'

# Exercise the real per-node collector: failed retries must never permit purge.
ssh_run() {
    if [[ "$2" == *'-delete'* ]]; then
        touch "$scratch/purged"
        printf '1\n'
    else
        printf 'access.log-2026-10-31_00-00-01.gz\t4\t1793404800.0\n'
    fi
}
s3_object_size() { return 1; }
s3_upload() { touch "$scratch/uploaded"; }
reset_probe; fail_count=3
result=$(collect_node 192.0.2.1 Test 2> "$scratch/stderr")
[[ "$result" == '192.0.2.1|Test|PARTIAL|0|0' ]] || fail 'partial result'
[[ ! -e "$scratch/purged" && ! -e "$scratch/uploaded" ]] || fail 'failure allowed upload/purge'
reset_probe; fail_count=1
result=$(collect_node 192.0.2.1 Test 2> "$scratch/stderr")
[[ "$result" == '192.0.2.1|Test|OK|1|4' ]] || fail 'recovered result'
[[ -e "$scratch/uploaded" && -e "$scratch/purged" ]] || fail 'recovery did not complete normal processing'

# Simulate cron redirecting stderr to the same log: every entry must occur once.
: > "$LOG_FILE"
log WARN 'single-log-entry' 2>> "$LOG_FILE"
if [[ -d /proc/self/fd ]]; then
    [[ $(grep -c 'single-log-entry' "$LOG_FILE") == 1 ]] || fail 'duplicate cron log'
else
    printf 'SKIP: same-file stderr identity requires Linux /proc (collector target)\n'
fi

# Execute cmd_collect in a child so its exit/trap cannot affect the harness.
flock() { return 0; }
fetch_nodes() { printf 'stderr-still-open\n' >&2; return 1; }
telegram_send() { :; }
LOCK_FILE="$scratch/lock"
if (cmd_collect) > "$scratch/stdout" 2> "$scratch/stderr"; then
    fail 'API failure must fail'
fi
grep -q 'stderr-still-open' "$scratch/stderr" || fail 'lock opening still swallowed stderr'
LOCK_FILE="$scratch/missing/lock"
if (cmd_collect) > "$scratch/stdout" 2> "$scratch/stderr"; then
    fail 'unwritable lock must fail closed'
fi
grep -q 'Cannot create lock file' "$LOG_FILE" || fail 'lock failure not logged'
printf 'PASS: retry success/exhaustion, error details, purge guard, cron logging, lock stderr and failure\n'
