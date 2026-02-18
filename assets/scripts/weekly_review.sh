#!/bin/bash
# =============================================================================
# weekly_review.sh
# Embedded Lab - 매주 월요일 09:00 주간 아키텍처 리뷰
#
# 역할:
#   1. 지난 1주일간 빌드 결과 / Git 커밋 통계 수집
#   2. Nanobot @architect 에이전트 호출 → 아키텍처 리뷰 및 개선점 도출
#   3. Telegram으로 주간 리포트 전송
#
# cron: 0 9 * * 1 /embedded-lab/scripts/weekly_review.sh
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
PROJECT_PATH="${PROJECT_PATH:-/home/ubuntu/embedded-lab/firmware}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/tmp}"
REVIEW_LOG="/tmp/weekly_review_$(date +%Y%m%d).log"
NANOBOT_TIMEOUT="${NANOBOT_TIMEOUT:-300}"

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

# ── 함수: Nanobot 에이전트 호출 ───────────────────────────────────────────────
call_nanobot_agent() {
    local agent="$1"
    local prompt="$2"

    curl -s --max-time "$NANOBOT_TIMEOUT" \
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

# ── 1단계: 지난 주 빌드 로그 통계 ────────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] 주간 빌드 통계 수집 중..." | tee -a "$REVIEW_LOG"

WEEK_START=$(date -d "7 days ago" "+%Y%m%d" 2>/dev/null || date -v-7d "+%Y%m%d")
TODAY=$(date "+%Y%m%d")

BUILD_SUCCESS=0
BUILD_FAIL=0

for LOG_FILE in "${BUILD_LOG_DIR}"/nightly_build_*.log; do
    [ -f "$LOG_FILE" ] || continue
    LOG_DATE=$(basename "$LOG_FILE" | grep -oE '[0-9]{8}' || echo "0")
    [ "$LOG_DATE" -ge "$WEEK_START" ] 2>/dev/null || continue

    if grep -q "전체 Gate 통과" "$LOG_FILE" 2>/dev/null; then
        BUILD_SUCCESS=$((BUILD_SUCCESS + 1))
    else
        BUILD_FAIL=$((BUILD_FAIL + 1))
    fi
done

TOTAL_BUILDS=$((BUILD_SUCCESS + BUILD_FAIL))
SUCCESS_RATE=0
[ "$TOTAL_BUILDS" -gt 0 ] && SUCCESS_RATE=$(( BUILD_SUCCESS * 100 / TOTAL_BUILDS ))

# ── 2단계: Git 커밋 통계 ──────────────────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] Git 커밋 통계 수집 중..." | tee -a "$REVIEW_LOG"

GIT_STATS="Git 통계 없음"
COMMIT_COUNT=0
CHANGED_FILES=0
TOP_FILES=""

if git -C "$PROJECT_PATH" rev-parse --git-dir > /dev/null 2>&1; then
    COMMIT_COUNT=$(git -C "$PROJECT_PATH" \
        log --oneline --since="7 days ago" 2>/dev/null | wc -l | tr -d ' ')

    CHANGED_FILES=$(git -C "$PROJECT_PATH" \
        diff --stat HEAD~"${COMMIT_COUNT:-1}" HEAD 2>/dev/null \
        | tail -1 | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")

    TOP_FILES=$(git -C "$PROJECT_PATH" \
        log --since="7 days ago" --name-only --pretty=format: 2>/dev/null \
        | sort | uniq -c | sort -rn | head -5 \
        | awk '{print $2 " (" $1 "회)"}' || echo "정보 없음")

    GIT_STATS="커밋: ${COMMIT_COUNT}회 | 변경 파일: ${CHANGED_FILES}개"
fi

# ── 3단계: 최근 에러 패턴 수집 ───────────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] 에러 패턴 분석 중..." | tee -a "$REVIEW_LOG"

ERROR_SUMMARY="에러 로그 없음"
ERROR_PATTERNS=""

for LOG_FILE in "${BUILD_LOG_DIR}"/nightly_build_*.log; do
    [ -f "$LOG_FILE" ] || continue
    LOG_DATE=$(basename "$LOG_FILE" | grep -oE '[0-9]{8}' || echo "0")
    [ "$LOG_DATE" -ge "$WEEK_START" ] 2>/dev/null || continue
    grep -E "error:|undefined reference|HardFault|Gate [0-9]+ FAIL" "$LOG_FILE" 2>/dev/null || true
done | sort | uniq -c | sort -rn | head -10 > /tmp/weekly_errors.txt

if [ -s /tmp/weekly_errors.txt ]; then
    ERROR_PATTERNS=$(cat /tmp/weekly_errors.txt)
    ERROR_SUMMARY=$(wc -l < /tmp/weekly_errors.txt | tr -d ' ')개 패턴
fi

# ── 4단계: @architect 주간 리뷰 ──────────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] @architect 주간 리뷰 호출 중..." | tee -a "$REVIEW_LOG"

WEEK_RANGE="${WEEK_START} ~ ${TODAY}"

ARCHITECT_PROMPT="지난 주(${WEEK_RANGE}) 임베디드 개발 파이프라인 주간 리뷰를 수행해줘.

📊 빌드 통계:
- 총 빌드: ${TOTAL_BUILDS}회
- 성공: ${BUILD_SUCCESS}회 / 실패: ${BUILD_FAIL}회 (성공률 ${SUCCESS_RATE}%)

📝 Git 활동:
- ${GIT_STATS}
- 주요 변경 파일:
${TOP_FILES}

🔴 반복 에러 패턴:
${ERROR_PATTERNS:-없음}

위 데이터를 바탕으로:
1. 이번 주 아키텍처/코드 품질 평가
2. 반복 에러의 근본 원인 분석
3. 다음 주 개선 우선순위 3가지 제안
을 간결하게 한국어로 작성해줘."

ARCHITECT_REVIEW=$(call_nanobot_agent "architect" "$ARCHITECT_PROMPT" 2>>"$REVIEW_LOG" \
    || echo "@architect 응답 실패 — 수동 리뷰 필요")

echo "[$(date '+%H:%M:%S')] @architect 리뷰 완료" | tee -a "$REVIEW_LOG"

# ── 5단계: Telegram 주간 리포트 전송 ─────────────────────────────────────────
REVIEW_SUMMARY=$(echo "$ARCHITECT_REVIEW" | head -25 | cut -c1-900)

# 성공률에 따른 아이콘
if [ "$SUCCESS_RATE" -ge 80 ]; then
    RATE_ICON="🟢"
elif [ "$SUCCESS_RATE" -ge 50 ]; then
    RATE_ICON="🟡"
else
    RATE_ICON="🔴"
fi

MESSAGE="📅 *주간 아키텍처 리뷰 — ${WEEK_RANGE}*

━━━━━━━━━━━━━━━━
📊 *빌드 통계*
${RATE_ICON} 성공률: ${SUCCESS_RATE}% (${BUILD_SUCCESS}/${TOTAL_BUILDS}회)
📝 커밋: ${COMMIT_COUNT}회

━━━━━━━━━━━━━━━━
🏛️ *@architect 리뷰*
${REVIEW_SUMMARY}

━━━━━━━━━━━━━━━━
📋 전체 로그: \`${REVIEW_LOG}\`"

send_telegram "$MESSAGE"

echo "[$(date '+%H:%M:%S')] 주간 리뷰 완료." | tee -a "$REVIEW_LOG"
exit 0
