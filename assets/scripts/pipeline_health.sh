#!/bin/bash
# =============================================================================
# pipeline_health.sh
# Embedded Lab - 매 4시간 파이프라인 헬스체크
#
# 역할:
#   1. LiteLLM Proxy 상태 확인 (포트 4000)
#   2. Nanobot 상태 확인 (포트 8080)
#   3. MCP 서버 프로세스 확인
#   4. 디스크/메모리/CPU 리소스 확인
#   5. 이상 감지 시 Telegram 알림 + 자동 재시작 시도
#
# cron: 0 4,8,12,16,20 * * * /embedded-lab/scripts/pipeline_health.sh
# =============================================================================

set -euo pipefail

# ── 환경 변수 로드 ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
    set +a
fi

# ── 설정값 ────────────────────────────────────────────────────────────────────
LITELLM_PORT="${LITELLM_PORT:-4000}"
NANOBOT_PORT="${NANOBOT_PORT:-8080}"
HEALTH_LOG="/tmp/pipeline_health.log"
STATUS_CACHE="/tmp/pipeline_status.json"
EMBEDDED_LAB_DIR="${EMBEDDED_LAB_DIR:-/home/ubuntu/embedded-lab}"

# 임계값
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"    # 디스크 사용률 경고 (%)
MEM_WARN_PCT="${MEM_WARN_PCT:-90}"      # 메모리 사용률 경고 (%)
CPU_WARN_PCT="${CPU_WARN_PCT:-95}"      # CPU 사용률 경고 (%)

# ── 함수: Telegram 알림 전송 ──────────────────────────────────────────────────
send_telegram() {
    local message="$1"

    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "[WARN] Telegram 미설정" >&2
        return 0
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "parse_mode=Markdown" \
        -o /dev/null
}

# ── 함수: HTTP 헬스체크 ───────────────────────────────────────────────────────
check_http() {
    local name="$1"
    local url="$2"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "$url" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ] || [ "$http_code" = "404" ]; then
        echo "UP"
    else
        echo "DOWN (HTTP ${http_code})"
    fi
}

# ── 함수: 프로세스 확인 ───────────────────────────────────────────────────────
check_process() {
    local name="$1"
    if pgrep -f "$name" > /dev/null 2>&1; then
        echo "RUNNING"
    else
        echo "STOPPED"
    fi
}

# ── 함수: 자동 재시작 ─────────────────────────────────────────────────────────
restart_service() {
    local service="$1"

    case "$service" in
        litellm)
            nohup litellm --config "${EMBEDDED_LAB_DIR}/litellm_config.yaml" \
                --port "$LITELLM_PORT" >> /tmp/litellm.log 2>&1 &
            sleep 5
            ;;
        nanobot)
            nohup nanobot run "${EMBEDDED_LAB_DIR}/" \
                >> /tmp/nanobot.log 2>&1 &
            sleep 5
            ;;
    esac
}

# ── 헬스체크 실행 ─────────────────────────────────────────────────────────────
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
echo "[${TIMESTAMP}] 파이프라인 헬스체크 시작" | tee -a "$HEALTH_LOG"

ISSUES=()
RESTART_LOG=()

# ── 1. LiteLLM 상태 ───────────────────────────────────────────────────────────
LITELLM_STATUS=$(check_http "LiteLLM" "http://localhost:${LITELLM_PORT}/health")
echo "  LiteLLM  : ${LITELLM_STATUS}" | tee -a "$HEALTH_LOG"

if [[ "$LITELLM_STATUS" != "UP" ]]; then
    ISSUES+=("❌ LiteLLM (포트 ${LITELLM_PORT}): ${LITELLM_STATUS}")
    echo "  → LiteLLM 재시작 시도..." | tee -a "$HEALTH_LOG"
    restart_service "litellm"
    LITELLM_RETRY=$(check_http "LiteLLM" "http://localhost:${LITELLM_PORT}/health")
    if [[ "$LITELLM_RETRY" == "UP" ]]; then
        RESTART_LOG+=("✅ LiteLLM 재시작 성공")
    else
        RESTART_LOG+=("❌ LiteLLM 재시작 실패 — 수동 확인 필요")
    fi
fi

# ── 2. Nanobot 상태 ───────────────────────────────────────────────────────────
NANOBOT_STATUS=$(check_http "Nanobot" "http://localhost:${NANOBOT_PORT}/health")
echo "  Nanobot  : ${NANOBOT_STATUS}" | tee -a "$HEALTH_LOG"

if [[ "$NANOBOT_STATUS" != "UP" ]]; then
    ISSUES+=("❌ Nanobot (포트 ${NANOBOT_PORT}): ${NANOBOT_STATUS}")
    echo "  → Nanobot 재시작 시도..." | tee -a "$HEALTH_LOG"
    restart_service "nanobot"
    NANOBOT_RETRY=$(check_http "Nanobot" "http://localhost:${NANOBOT_PORT}/health")
    if [[ "$NANOBOT_RETRY" == "UP" ]]; then
        RESTART_LOG+=("✅ Nanobot 재시작 성공")
    else
        RESTART_LOG+=("❌ Nanobot 재시작 실패 — 수동 확인 필요")
    fi
fi

# ── 3. MCP 서버 프로세스 ──────────────────────────────────────────────────────
declare -A MCP_SERVERS=(
    ["esp-idf-mcp"]="esp_idf_mcp.py"
    ["gemini-cli"]="gemini-cli"
    ["telegram-mcp"]="server-telegram"
    ["github-mcp"]="server-github"
)

for MCP_NAME in "${!MCP_SERVERS[@]}"; do
    PROC="${MCP_SERVERS[$MCP_NAME]}"
    STATUS=$(check_process "$PROC")
    echo "  ${MCP_NAME}: ${STATUS}" | tee -a "$HEALTH_LOG"
    if [[ "$STATUS" == "STOPPED" ]]; then
        ISSUES+=("⚠️ MCP 서버 중단: ${MCP_NAME}")
    fi
done

# ── 4. 디스크 사용량 ──────────────────────────────────────────────────────────
DISK_PCT=$(df "$EMBEDDED_LAB_DIR" 2>/dev/null \
    | awk 'NR==2 {gsub("%",""); print $5}' || echo "0")
echo "  디스크   : ${DISK_PCT}%" | tee -a "$HEALTH_LOG"

if [ "${DISK_PCT:-0}" -ge "$DISK_WARN_PCT" ]; then
    ISSUES+=("⚠️ 디스크 사용률 높음: ${DISK_PCT}% (임계값: ${DISK_WARN_PCT}%)")
fi

# ── 5. 메모리 사용량 ──────────────────────────────────────────────────────────
MEM_PCT=$(free 2>/dev/null \
    | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}' || echo "0")
echo "  메모리   : ${MEM_PCT}%" | tee -a "$HEALTH_LOG"

if [ "${MEM_PCT:-0}" -ge "$MEM_WARN_PCT" ]; then
    ISSUES+=("⚠️ 메모리 사용률 높음: ${MEM_PCT}% (임계값: ${MEM_WARN_PCT}%)")
fi

# ── 6. CPU 사용량 (1분 평균) ──────────────────────────────────────────────────
CPU_LOAD=$(uptime 2>/dev/null \
    | awk -F'load average:' '{print $2}' \
    | awk -F',' '{gsub(/ /,"",$1); print $1}' || echo "0")
CPU_CORES=$(nproc 2>/dev/null || echo "1")
CPU_PCT=$(awk "BEGIN {printf \"%.0f\", (${CPU_LOAD}/${CPU_CORES})*100}" 2>/dev/null || echo "0")
echo "  CPU 로드 : ${CPU_LOAD} (${CPU_PCT}%)" | tee -a "$HEALTH_LOG"

if [ "${CPU_PCT:-0}" -ge "$CPU_WARN_PCT" ]; then
    ISSUES+=("⚠️ CPU 사용률 높음: ${CPU_PCT}% (임계값: ${CPU_WARN_PCT}%)")
fi

# ── 상태 JSON 저장 ────────────────────────────────────────────────────────────
jq -n \
    --arg ts "$TIMESTAMP" \
    --arg litellm "$LITELLM_STATUS" \
    --arg nanobot "$NANOBOT_STATUS" \
    --arg disk "${DISK_PCT}%" \
    --arg mem "${MEM_PCT}%" \
    --arg cpu "${CPU_PCT}%" \
    --argjson issues "$(printf '%s\n' "${ISSUES[@]:-}" | jq -R . | jq -s .)" \
    '{
        timestamp: $ts,
        services: { litellm: $litellm, nanobot: $nanobot },
        resources: { disk: $disk, memory: $mem, cpu: $cpu },
        issues: $issues
    }' > "$STATUS_CACHE" 2>/dev/null || true

# ── 결과 알림 (이상 있을 때만) ───────────────────────────────────────────────
if [ "${#ISSUES[@]}" -gt 0 ]; then
    ISSUE_LIST=$(printf '%s\n' "${ISSUES[@]}")
    RESTART_LIST=""
    [ "${#RESTART_LOG[@]}" -gt 0 ] && RESTART_LIST=$(printf '%s\n' "${RESTART_LOG[@]}")

    MESSAGE="🔧 *파이프라인 헬스체크 이상 감지*
⏰ ${TIMESTAMP}

*감지된 문제:*
${ISSUE_LIST}

${RESTART_LIST:+*자동 재시작 결과:*
${RESTART_LIST}}

💾 디스크: ${DISK_PCT}% | 🧠 메모리: ${MEM_PCT}% | ⚙️ CPU: ${CPU_PCT}%"

    send_telegram "$MESSAGE"
    echo "[${TIMESTAMP}] 이상 감지 — Telegram 알림 전송" | tee -a "$HEALTH_LOG"
else
    echo "[${TIMESTAMP}] 모든 서비스 정상" | tee -a "$HEALTH_LOG"
fi

exit 0
