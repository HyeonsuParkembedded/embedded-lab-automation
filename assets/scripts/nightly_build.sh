#!/bin/bash
# =============================================================================
# nightly_build.sh
# Embedded Lab - 매일 00:00 야간 배치 빌드
#
# 역할:
#   1. gate_runner.sh 실행 (Compile → Static → Simulation → Integration)
#   2. Gate 실패 시 Gate 번호에 따라 에이전트 분기
#      - Gate 1, 3, 4 실패 → @developer
#      - Gate 2 실패     → @misra-agent (정적 분석 전담)
#   3. 수정 후 Gate 재실행 (최대 MAX_RETRY회)
#   4. 최종 결과 Telegram 알림 + 성공 시 Git 태그 생성
#
# cron: 0 0 * * * /embedded-lab/scripts/nightly_build.sh
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
BOARD_TYPE="${BOARD_TYPE:-esp32}"           # "esp32" or "stm32"
GATE_RUNNER="${SCRIPT_DIR}/../gates/gate_runner.sh"
BUILD_STATUS_FILE="${BUILD_STATUS_FILE:-/tmp/build_status.json}"
BUILD_LOG="/tmp/nightly_build_$(date +%Y%m%d).log"
MAX_RETRY="${MAX_RETRY:-4}"                 # 에이전트 최대 시도 횟수 (초과 시 architect 에스컬레이션)
MAX_RETRY_MISRA="${MAX_RETRY_MISRA:-2}"    # misra-agent 최대 시도 횟수 (Gate 2 전용)
NANOBOT_TIMEOUT="${NANOBOT_TIMEOUT:-300}"

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

# ── 함수: Gate 실행 ───────────────────────────────────────────────────────────
run_gates() {
    if [ ! -x "$GATE_RUNNER" ]; then
        echo "[ERROR] gate_runner.sh 없음 또는 실행 권한 없음: $GATE_RUNNER" | tee -a "$BUILD_LOG"
        return 1
    fi

    bash "$GATE_RUNNER" "$PROJECT_PATH" "$BOARD_TYPE" 2>&1 | tee -a "$BUILD_LOG"
    return "${PIPESTATUS[0]}"
}

# ── 함수: 빌드 실패 로그 추출 ────────────────────────────────────────────────
extract_error_log() {
    grep -E "error:|Error:|FAIL|FAULT|undefined reference" "$BUILD_LOG" \
        | tail -30 \
        | head -20 \
        || echo "로그 파싱 실패"
}

# ── 빌드 시작 ─────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
echo "================================================================" | tee -a "$BUILD_LOG"
echo "[$(date '+%H:%M:%S')] 야간 빌드 시작 — ${TIMESTAMP}" | tee -a "$BUILD_LOG"
echo "  PROJECT: ${PROJECT_PATH}" | tee -a "$BUILD_LOG"
echo "  BOARD:   ${BOARD_TYPE}" | tee -a "$BUILD_LOG"
echo "================================================================" | tee -a "$BUILD_LOG"

send_telegram "🌙 *야간 빌드 시작*
⏰ ${TIMESTAMP}
📋 프로젝트: \`${PROJECT_PATH}\`
🔧 타겟: \`${BOARD_TYPE}\`"

# ── 빌드 + 에이전트 재시도 루프 ──────────────────────────────────────────────
ATTEMPT=0
ATTEMPT_MISRA=0
GATE_EXIT=0

while [ "$ATTEMPT" -le "$MAX_RETRY" ]; do

    echo "" | tee -a "$BUILD_LOG"
    echo "[$(date '+%H:%M:%S')] ── Gate 실행 (시도 $((ATTEMPT+1))/$((MAX_RETRY+1))) ──" | tee -a "$BUILD_LOG"

    if run_gates; then
        GATE_EXIT=0
        break
    else
        GATE_EXIT=$?
    fi

    # 실패한 Gate 번호 확인
    FAILED_GATE=$(jq -r '.gate // "unknown"' "$BUILD_STATUS_FILE" 2>/dev/null || echo "unknown")
    FAILED_REASON=$(jq -r '.reason // ""' "$BUILD_STATUS_FILE" 2>/dev/null || echo "")
    ERROR_LOG=$(extract_error_log)

    # ── Gate 2 실패 → @misra-agent 호출 ─────────────────────────────────────
    if [ "$FAILED_GATE" = "2" ]; then

        if [ "$ATTEMPT_MISRA" -ge "$MAX_RETRY_MISRA" ]; then
            echo "[$(date '+%H:%M:%S')] @misra-agent ${MAX_RETRY_MISRA}회 실패 — @architect 에스컬레이션" | tee -a "$BUILD_LOG"
            break
        fi

        echo "[$(date '+%H:%M:%S')] Gate 2 실패 — @misra-agent 호출 중... (시도 $((ATTEMPT_MISRA+1))/${MAX_RETRY_MISRA})" | tee -a "$BUILD_LOG"

        MISRA_PROMPT="야간 빌드에서 Gate 2 (Static Analysis) 가 실패했어.

실패 원인: ${FAILED_REASON}
프로젝트: ${PROJECT_PATH}

cppcheck 에러 로그:
\`\`\`
${ERROR_LOG}
\`\`\`

다음 순서로 처리해줘:
1. 위반 항목을 Mandatory / Advisory / 거짓양성으로 분류
2. 실제 버그 가능성이 있는 항목은 @developer에게 수정 요청
3. 억제 가능한 항목은 정당화 주석을 추가해서 억제
4. 처리 완료 후 결과 요약을 보고해줘"

        MISRA_RESPONSE=$(call_nanobot_agent "misra-agent" "$MISRA_PROMPT" 2>>"$BUILD_LOG" \
            || echo "Nanobot @misra-agent 응답 실패")

        echo "[$(date '+%H:%M:%S')] @misra-agent 응답: ${MISRA_RESPONSE:0:300}" | tee -a "$BUILD_LOG"
        ATTEMPT_MISRA=$((ATTEMPT_MISRA + 1))

    # ── Gate 1, 3, 4 실패 → @developer 호출 ─────────────────────────────────
    else

        if [ "$ATTEMPT" -ge "$MAX_RETRY" ]; then
            echo "[$(date '+%H:%M:%S')] 최대 재시도 초과 — @architect 에스컬레이션" | tee -a "$BUILD_LOG"
            break
        fi

        echo "[$(date '+%H:%M:%S')] Gate ${FAILED_GATE} 실패 — @developer 호출 중..." | tee -a "$BUILD_LOG"

        DEVELOPER_PROMPT="야간 빌드에서 Gate ${FAILED_GATE}가 실패했어.

실패 원인: ${FAILED_REASON}
프로젝트: ${PROJECT_PATH}
타겟 보드: ${BOARD_TYPE}

에러 로그:
\`\`\`
${ERROR_LOG}
\`\`\`

${PROJECT_PATH} 의 코드를 수정해서 빌드가 통과되도록 해줘.
수정 완료 후 반드시 '수정 완료' 라고 응답해줘."

        DEV_RESPONSE=$(call_nanobot_agent "developer" "$DEVELOPER_PROMPT" 2>>"$BUILD_LOG" \
            || echo "Nanobot 응답 실패")

        echo "[$(date '+%H:%M:%S')] @developer 응답: ${DEV_RESPONSE:0:200}" | tee -a "$BUILD_LOG"

    fi

    ATTEMPT=$((ATTEMPT + 1))
done

# ── 최종 결과 처리 ────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

if [ "$GATE_EXIT" -eq 0 ]; then
    # ── 성공 ─────────────────────────────────────────────────────────────────
    echo "[$(date '+%H:%M:%S')] 전체 Gate 통과 — 빌드 성공!" | tee -a "$BUILD_LOG"

    # Git 태그 자동 생성
    GIT_TAG="nightly-$(date +%Y%m%d)"
    if git -C "$PROJECT_PATH" rev-parse --git-dir > /dev/null 2>&1; then
        git -C "$PROJECT_PATH" tag -f "$GIT_TAG" \
            -m "Nightly build passed all gates — $(date '+%Y-%m-%d')" \
            >> "$BUILD_LOG" 2>&1 && \
            echo "[$(date '+%H:%M:%S')] Git 태그 생성: ${GIT_TAG}" | tee -a "$BUILD_LOG"
    fi

    send_telegram "✅ *야간 빌드 성공*
⏱️ 소요시간: ${ELAPSED_MIN}분 ${ELAPSED_SEC}초
🏷️ Git 태그: \`${GIT_TAG}\`
🔢 시도 횟수: $((ATTEMPT+1))회

모든 Gate 통과 — 배포 준비 완료!"

else
    # ── 실패 (architect 에스컬레이션) ────────────────────────────────────────
    FAILED_GATE=$(jq -r '.gate // "unknown"' "$BUILD_STATUS_FILE" 2>/dev/null || echo "unknown")
    ERROR_LOG=$(extract_error_log)

    # 에스컬레이션 주체 결정 (Gate 2는 misra-agent, 나머지는 developer)
    if [ "$FAILED_GATE" = "2" ]; then
        ESCALATION_AGENT="@misra-agent"
        ESCALATION_RETRY="$MAX_RETRY_MISRA"
    else
        ESCALATION_AGENT="@developer"
        ESCALATION_RETRY="$MAX_RETRY"
    fi

    echo "[$(date '+%H:%M:%S')] ${ESCALATION_AGENT} ${ESCALATION_RETRY}회 실패 — @architect 에스컬레이션" | tee -a "$BUILD_LOG"

    ARCHITECT_PROMPT="${ESCALATION_AGENT}가 Gate ${FAILED_GATE} 실패를 ${ESCALATION_RETRY}회 시도했지만 해결하지 못했어.

프로젝트: ${PROJECT_PATH}
타겟 보드: ${BOARD_TYPE}

에러 로그:
\`\`\`
${ERROR_LOG}
\`\`\`

근본 원인을 분석하고 해결 방향을 제시해줘.
필요하면 @gemini에게 최신 데이터시트나 코드 전수 조사를 요청해."

    ARCHITECT_RESPONSE=$(call_nanobot_agent "architect" "$ARCHITECT_PROMPT" 2>>"$BUILD_LOG" \
        || echo "Nanobot @architect 응답 실패")

    echo "[$(date '+%H:%M:%S')] @architect 응답: ${ARCHITECT_RESPONSE:0:500}" | tee -a "$BUILD_LOG"

    # architect 응답 요약 (Telegram 길이 제한)
    ARCH_SUMMARY=$(echo "$ARCHITECT_RESPONSE" | head -10 | cut -c1-600)

    send_telegram "❌ *야간 빌드 실패 — Architect 에스컬레이션*
⏱️ 소요시간: ${ELAPSED_MIN}분 ${ELAPSED_SEC}초
🔢 ${ESCALATION_AGENT} 시도: ${ESCALATION_RETRY}회 전부 실패
🚫 실패 Gate: ${FAILED_GATE}

🏛️ *@architect 분석:*
${ARCH_SUMMARY}

📋 전체 로그: \`${BUILD_LOG}\`"

fi

echo "[$(date '+%H:%M:%S')] 야간 빌드 종료." | tee -a "$BUILD_LOG"
exit "$GATE_EXIT"
