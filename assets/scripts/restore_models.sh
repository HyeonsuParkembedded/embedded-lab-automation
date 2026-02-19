#!/bin/bash
# =============================================================================
# restore_models.sh
# GitHub Copilot 쿼터 복구 확인 후 에이전트 모델 원복
#
# 동작 방식:
#   - LiteLLM을 통해 Claude 모델 호출 테스트
#   - 성공하면 각 에이전트를 원래 전용 모델로 원복
#   - 이미 원복된 상태면 아무것도 하지 않음
#
# cron 등록:
#   0 9 * * * bash ~/embedded-lab/scripts/restore_models.sh
# =============================================================================

AGENTS_DIR="${HOME}/embedded-lab/agents"
LOG="${HOME}/embedded-lab/logs/restore_models.log"
LITELLM_URL="http://localhost:4000/v1/chat/completions"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ── 이미 원복된 상태인지 확인 ─────────────────────────────────
current_model=$(grep "^model:" "${AGENTS_DIR}/architect.md" | awk '{print $2}')
if [ "$current_model" != "github_copilot/gpt-4.1" ]; then
    log "이미 원복 완료 상태입니다 (architect: ${current_model}). 종료합니다."
    exit 0
fi

# ── LiteLLM 실행 중인지 확인 ──────────────────────────────────
if ! curl -sf http://localhost:4000/health > /dev/null 2>&1; then
    log "LiteLLM Proxy가 실행 중이지 않습니다. 종료합니다."
    exit 1
fi

# ── Claude 쿼터 테스트 ────────────────────────────────────────
log "Claude 쿼터 확인 중..."
response=$(curl -s --max-time 30 "${LITELLM_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer dummy" \
    -d '{"model":"github_copilot/claude-sonnet-4.6","messages":[{"role":"user","content":"hi"}],"max_tokens":5}')

if echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'choices' in d else 1)" 2>/dev/null; then
    log "Claude 쿼터 복구 확인! 에이전트 모델 원복을 시작합니다."
else
    log "Claude 쿼터 아직 소진 상태입니다. 내일 다시 시도합니다."
    exit 0
fi

# ── 에이전트 모델 원복 ────────────────────────────────────────
sed -i 's|model: github_copilot/gpt-4.1|model: github_copilot/claude-opus-4.6|'   "${AGENTS_DIR}/architect.md"
sed -i 's|model: github_copilot/gpt-4.1|model: github_copilot/gpt-5.3-codex|'     "${AGENTS_DIR}/developer.md"
sed -i 's|model: github_copilot/gpt-4.1|model: github_copilot/gemini-2.5-pro|'    "${AGENTS_DIR}/gemini.md"
sed -i 's|model: github_copilot/gpt-4.1|model: github_copilot/claude-sonnet-4.6|' "${AGENTS_DIR}/guard.md"
sed -i 's|model: github_copilot/gpt-4.1|model: github_copilot/claude-sonnet-4.6|' "${AGENTS_DIR}/misra-agent.md"
sed -i 's|model: github_copilot/gpt-4.1|model: github_copilot/claude-sonnet-4.6|' "${AGENTS_DIR}/reporter.md"

log "원복 완료:"
grep "^model:" "${AGENTS_DIR}"/*.md | sed 's|.*agents/||' | tee -a "$LOG"

# ── Nanobot 재시작 (변경 반영) ────────────────────────────────
if systemctl is-active --quiet nanobot 2>/dev/null; then
    sudo systemctl restart nanobot
    log "Nanobot 재시작 완료"
fi
