#!/bin/bash
# =============================================================================
# guard_heartbeat.sh
# Embedded Lab - Guard Agent Heartbeat (Nanobot HEARTBEAT.md 대체)
#
# 역할: 30초마다 시리얼/빌드 로그를 감시하여 에러 발생 시 Telegram 알림
# 실행: cron (30초 주기)
#   * * * * * /embedded-lab/scripts/guard_heartbeat.sh
#   * * * * * sleep 30 && /embedded-lab/scripts/guard_heartbeat.sh
# =============================================================================

set -euo pipefail

# ── 환경 변수 로드 ────────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
    # export 없이 선언된 변수도 로드 (주석 및 빈 줄 제외)
    set -a
    # shellcheck disable=SC1090
    source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
    set +a
fi

# ── 설정값 ────────────────────────────────────────────────────────────────────
LOG_FILE="${SERIAL_LOG:-/var/log/serial.log}"
BUILD_LOG="${BUILD_LOG:-/tmp/build.log}"
STATUS_DIR="${STATUS_DIR:-/tmp/guard}"
LOCK_FILE="${STATUS_DIR}/guard.lock"
HASH_FILE="${STATUS_DIR}/last_error.hash"
TIMESTAMP_FILE="${STATUS_DIR}/last_alert.ts"
ALERT_COOLDOWN="${ALERT_COOLDOWN:-300}"   # 같은 에러 재알림 방지 (초)
LOG_TAIL="${LOG_TAIL:-500}"               # 감시할 최근 로그 라인 수

# ── 에러 패턴 (임베디드 공통) ─────────────────────────────────────────────────
ERROR_PATTERN="\[ERROR\]|HardFault_Handler|MemManage_Handler|BusFault_Handler|\
UsageFault_Handler|Stack Overflow|FATAL|PANIC|assert failed|\
abort\(\)|isr_stack_overflow|ESP_ERROR_CHECK|E \(|guru meditation"

# ── 초기화 ────────────────────────────────────────────────────────────────────
mkdir -p "$STATUS_DIR"

# ── 중복 실행 방지 (Lock) ─────────────────────────────────────────────────────
if [ -e "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0   # 이미 실행 중
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ── 함수: Telegram 알림 전송 ──────────────────────────────────────────────────
send_telegram() {
    local message="$1"

    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "[WARN] TELEGRAM_BOT_TOKEN 또는 TELEGRAM_CHAT_ID 미설정 — 알림 스킵" >&2
        return 0
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "parse_mode=Markdown" \
        -o /dev/null
}

# ── 함수: 로그 파일에서 에러 탐지 ────────────────────────────────────────────
detect_errors() {
    local log_file="$1"

    if [ ! -f "$log_file" ]; then
        return 1
    fi

    tail -n "$LOG_TAIL" "$log_file" \
        | grep -E "$ERROR_PATTERN" \
        | head -10 \
        || true
}

# ── 함수: 알림 쿨다운 체크 ───────────────────────────────────────────────────
is_cooldown_active() {
    local current_hash="$1"
    local last_hash
    local last_ts
    local now

    last_hash=$(cat "$HASH_FILE" 2>/dev/null || echo "")
    last_ts=$(cat "$TIMESTAMP_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)

    if [ "$current_hash" = "$last_hash" ] && \
       [ $(( now - last_ts )) -lt "$ALERT_COOLDOWN" ]; then
        return 0   # 쿨다운 중
    fi
    return 1
}

# ── 메인 감시 로직 ────────────────────────────────────────────────────────────
ERRORS=""

# 시리얼 로그 감시
if [ -f "$LOG_FILE" ]; then
    ERRORS=$(detect_errors "$LOG_FILE")
fi

# 빌드 로그 감시 (시리얼 로그 에러 없을 때)
if [ -z "$ERRORS" ] && [ -f "$BUILD_LOG" ]; then
    ERRORS=$(detect_errors "$BUILD_LOG")
fi

# 에러 없으면 종료
if [ -z "$ERRORS" ]; then
    exit 0
fi

# ── 해시 기반 중복 체크 ───────────────────────────────────────────────────────
CURRENT_HASH=$(echo "$ERRORS" | md5sum | cut -d' ' -f1)

if is_cooldown_active "$CURRENT_HASH"; then
    exit 0
fi

# ── 상태 갱신 ─────────────────────────────────────────────────────────────────
echo "$CURRENT_HASH" > "$HASH_FILE"
date +%s > "$TIMESTAMP_FILE"

# ── Telegram 알림 메시지 구성 ─────────────────────────────────────────────────
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
ERROR_PREVIEW=$(echo "$ERRORS" | head -5 | sed 's/[_*`\[]/\\&/g')  # Markdown 이스케이프

MESSAGE="🚨 *[GUARD ALERT]*
⏰ ${TIMESTAMP}
📋 *감지된 에러:*
\`\`\`
${ERROR_PREVIEW}
\`\`\`
📂 로그: ${LOG_FILE}"

send_telegram "$MESSAGE"

exit 0
