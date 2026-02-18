#!/bin/bash
# =============================================================================
# morning_briefing.sh
# Embedded Lab - 매일 08:00 아침 브리핑
#
# 역할:
#   1. 전날 야간 빌드 결과 요약
#   2. arXiv 논문 크롤링 결과 (arxiv_fetch.sh 출력) 포함
#   3. Nanobot @researcher 에이전트 호출 → 논문 요약 생성
#   4. Telegram으로 브리핑 전송
#
# cron: 0 8 * * * /embedded-lab/scripts/morning_briefing.sh
#       (arxiv_fetch.sh가 07:50에 먼저 실행되어야 함)
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
NANOBOT_URL="${NANOBOT_URL:-http://localhost:8080}"
ARXIV_CACHE="${ARXIV_CACHE:-/tmp/arxiv_latest.json}"
BUILD_STATUS_FILE="${BUILD_STATUS_FILE:-/tmp/build_status.json}"
BRIEFING_LOG="${BRIEFING_LOG:-/tmp/morning_briefing.log}"
TIMEOUT="${NANOBOT_TIMEOUT:-120}"

# ── 함수: Telegram 알림 전송 ──────────────────────────────────────────────────
send_telegram() {
    local message="$1"

    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "[WARN] Telegram 미설정 — 알림 스킵" >&2
        return 0
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "parse_mode=Markdown" \
        -o /dev/null
}

# ── 함수: Nanobot 에이전트 호출 ───────────────────────────────────────────────
call_nanobot_agent() {
    local agent="$1"
    local prompt="$2"

    curl -s --max-time "$TIMEOUT" \
        -X POST "${NANOBOT_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${OPENAI_API_KEY:-dummy}" \
        -d "$(jq -n \
            --arg agent "$agent" \
            --arg prompt "$prompt" \
            '{
                model: $agent,
                messages: [{"role": "user", "content": $prompt}],
                stream: false
            }')" \
        | jq -r '.choices[0].message.content // "응답 없음"'
}

# ── 1단계: 야간 빌드 결과 읽기 ───────────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] 야간 빌드 상태 확인 중..." | tee -a "$BRIEFING_LOG"

BUILD_STATE="unknown"
BUILD_GATE=0
BUILD_REASON=""

if [ -f "$BUILD_STATUS_FILE" ]; then
    BUILD_STATE=$(jq -r '.state // "unknown"' "$BUILD_STATUS_FILE" 2>/dev/null || echo "unknown")
    BUILD_GATE=$(jq -r '.gate // 0' "$BUILD_STATUS_FILE" 2>/dev/null || echo "0")
    BUILD_REASON=$(jq -r '.reason // ""' "$BUILD_STATUS_FILE" 2>/dev/null || echo "")
fi

case "$BUILD_STATE" in
    "completed") BUILD_ICON="✅" ; BUILD_MSG="전체 Gate 통과 — 배포 준비 완료" ;;
    "failed")    BUILD_ICON="❌" ; BUILD_MSG="Gate ${BUILD_GATE} 실패 (${BUILD_REASON})" ;;
    *)           BUILD_ICON="⚠️" ; BUILD_MSG="빌드 상태 정보 없음" ;;
esac

# ── 2단계: arXiv 논문 로드 ────────────────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] arXiv 논문 데이터 로드 중..." | tee -a "$BRIEFING_LOG"

ARXIV_SUMMARY="논문 데이터 없음 (arxiv_fetch.sh 실행 확인 필요)"
PAPER_COUNT=0

if [ -f "$ARXIV_CACHE" ]; then
    PAPER_COUNT=$(jq '. | length' "$ARXIV_CACHE" 2>/dev/null || echo "0")

    if [ "$PAPER_COUNT" -gt 0 ]; then
        # 논문 제목 목록 추출 (최대 5편)
        ARXIV_SUMMARY=$(jq -r '.[0:5] | to_entries[] |
            "[\(.key+1)] \(.value.title) — \(.value.authors[0] // "Unknown")"' \
            "$ARXIV_CACHE" 2>/dev/null || echo "파싱 실패")
    fi
fi

# ── 3단계: Nanobot @researcher 호출 (논문 요약) ───────────────────────────────
RESEARCHER_SUMMARY="요약 생략 (논문 없음)"

if [ "$PAPER_COUNT" -gt 0 ]; then
    echo "[$(date '+%H:%M:%S')] @researcher 에이전트 호출 중..." | tee -a "$BRIEFING_LOG"

    PAPER_LIST=$(jq -r '.[0:5][] |
        "제목: \(.title)\n초록: \(.abstract[0:300])..."' \
        "$ARXIV_CACHE" 2>/dev/null || echo "$ARXIV_SUMMARY")

    RESEARCHER_PROMPT="아래 임베디드/위성 시스템 관련 arXiv 논문들을 각 1~2줄로 한국어 요약해줘.
임베디드 개발자 관점에서 실용적인 포인트를 강조해줘.

${PAPER_LIST}"

    RESEARCHER_SUMMARY=$(call_nanobot_agent "researcher" "$RESEARCHER_PROMPT" 2>>"$BRIEFING_LOG" \
        || echo "Nanobot 응답 실패 — 수동 확인 필요")
fi

# ── 4단계: Telegram 브리핑 전송 ──────────────────────────────────────────────
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

# 메시지 길이 제한 (Telegram 4096자)
SUMMARY_TRUNCATED=$(echo "$RESEARCHER_SUMMARY" | head -20 | cut -c1-800)

MESSAGE="☀️ *아침 브리핑 — ${TIMESTAMP}*

━━━━━━━━━━━━━━━━
🔨 *야간 빌드 결과*
${BUILD_ICON} ${BUILD_MSG}
━━━━━━━━━━━━━━━━
📄 *arXiv 신규 논문 (${PAPER_COUNT}편)*
${SUMMARY_TRUNCATED}
━━━━━━━━━━━━━━━━
🤖 오늘도 좋은 개발 되세요, 현수님!"

echo "[$(date '+%H:%M:%S')] Telegram 브리핑 전송 중..." | tee -a "$BRIEFING_LOG"
send_telegram "$MESSAGE"

echo "[$(date '+%H:%M:%S')] 아침 브리핑 완료." | tee -a "$BRIEFING_LOG"
exit 0
