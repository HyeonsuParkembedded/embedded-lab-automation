# PRD: Embedded AI Agent System on Nanobot (v5.2 - Claude Opus 4.6 Chief Architect)

**문서 버전:** v5.2
**작성일:** 2026년 2월 18일
**작성자:** Gemini CLI
**상태:** Draft

> **v5.2 변경 이유:**
> 지휘 체계 재정립. **Claude Opus 4.6**이 명실상부한 **수석(Chief) 아키텍트**로서 프로젝트의 최종 의사결정권을 가짐.
> Gemini CLI는 **특수 분석관(Specialist)**으로서 브라우저 및 코드베이스 전수 조사를 담당하며, 아키텍트의 지시를 따름.

***

## 1. 배경 및 목적

### 1.1 배경
임베디드 개발자는 다음과 같은 반복적이고 시간 소모적인 작업을 매일 수행합니다:
- ESP-IDF / STM32Cube 빌드 및 디버깅
- Renode / QEMU 기반 시뮬레이션 실행
- 대용량 로그 분석 및 에러 추적
- 데이터시트 검색 및 레지스터 맵 분석
- 반복적인 보일러플레이트 코드 작성

### 1.2 목적
**Ryzen 5 4650G 서버(JONSBO C6)** 위에서 **Nanobot**을 MCP 호스트로 활용하여, **LiteLLM 프록시**를 통해 **GitHub Copilot OAuth(학생 무료)**로 고성능 GPT-4o를 구동하는 **역할별 분산 에이전트 팀**을 구성하고, 임베디드 개발 파이프라인 전체를 **$0 비용으로 자동화**하는 시스템을 구축한다.

### 1.3 Nanobot이란?
Nanobot은 MCP(Model Context Protocol) 서버와 LLM을 결합하는 **오픈소스 에이전트 호스트**입니다.
- **라이선스:** Apache 2.0 (코드 전체 감사 가능)
- **표준 프로토콜:** MCP 기반 — 특정 벤더 종속 없음
- **에이전트 정의:** 마크다운 파일(`.md`) 하나로 에이전트 역할 완전 정의
- **도구(Tool) 제공:** MCP 서버가 에이전트에게 능력(도구)을 부여
- **보안:** API 키는 환경 변수에만 존재, 설정 파일에 하드코딩 불가

***

## 2. 목표 (Goals)

1. **개발 속도 3배 향상:** AI 에이전트가 빌드~시뮬레이션~디버깅 사이클을 자동화합니다.
2. **24/7 무인 운영:** 개발자가 자는 동안에도 에이전트가 CI/CD를 자동 수행합니다.
3. **보안:** 기밀 코드는 외부(Cloud)로 나가지 않고 4650G 로컬에서만 처리합니다.
4. **$0 비용 운영:** GitHub Copilot 학생 구독 + LiteLLM OAuth로 API 과금 없이 고성능 GPT-4o를 사용합니다.
5. **완전 오픈소스:** Nanobot + MCP 서버 모두 소스 감사 가능한 오픈소스로 구성합니다.

***

## 3. 비목표 (Non-Goals)
- 로컬 LLM을 주력으로 운용하는 것 (성능 한계)
- GUI 기반 대화형 챗봇 구축 (Nanobot이 기본 제공)
- 하드웨어 실제 플래싱 자동화 (이번 버전 범위 밖)

***

## 4. 사용자 페르소나

| 항목 | 내용 |
| :--- | :--- |
| **역할** | 위성 시스템 임베디드 개발자 (대학원생) |
| **기기** | 4650G 서버 (24/7), 노트북 (SSH 접속), Raspberry Pi (테스트 보드) |
| **보유 AI** | GitHub Copilot (학생 무료) — LiteLLM OAuth로 GPT-4o 구동 |
| **핵심 고통** | 빌드 시간, 반복 디버깅, 대용량 로그 분석, 잦은 컨텍스트 스위칭 |
| **핵심 욕구** | "내가 설계만 하면, 나머지는 에이전트들이 알아서 해줬으면" |

***

## 5. 시스템 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                    4650G Server (JONSBO C6)                 │
│                                                             │
│           GitHub Copilot 학생 구독 (월 $0)                   │
│                ↕ OAuth device flow                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │        LiteLLM Proxy (포트 4000)                     │   │
│  │  OpenAI 호환 API  ←→  gpt-4.1 / gpt-5-mini (0×)      │   │
│  │                  ←→  gpt-5.3-codex (1×)             │   │
│  │                  ←→  claude-sonnet-4-6 (1×)         │   │
│  │                  ←→  claude-opus-4-6 (3×)           │   │
│  │   토큰 자동 갱신 (~/.litellm/github_copilot_token)    │   │
│  └───────────────────────┬─────────────────────────────┘   │
│                          │ OpenAI 호환 API                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Nanobot (포트 8080)                     │   │
│  │  OPENAI_API_BASE=http://localhost:4000               │   │
│  │                                                     │   │
│  │   agents/main.md ──┬── agents/architect.md (Chief)  │   │
│  │   (Orchestrator)   ├── agents/developer.md          │   │
│  │                    ├── agents/gemini.md (Specialist)│   │
│  │                    └── agents/guard.md              │   │
│  └──────────────────────┬──────────────────────────────┘   │
│                         │ MCP Protocol                     │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              MCP 서버 레이어                         │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ │   │
│  │  │esp-idf   │ │renode    │ │gemini    │ │pdf-rag │ │   │
│  │  │-mcp      │ │-mcp      │ │-cli-mcp  │ │-mcp    │ │   │
│  │  │(stdio)   │ │(stdio)   │ │(stdio)   │ │(stdio) │ │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               Execution Layer (4650G)               │   │
│  │   ┌──────────┐  ┌──────────┐  ┌────────────────┐   │   │
│  │   │ESP-IDF   │  │ Renode / │  │  Jenkins /     │   │   │
│  │   │STM32Cube │  │  QEMU    │  │  GitLab CI     │   │   │
│  │   └──────────┘  └──────────┘  └────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

***

## 6. AI 에이전트 팀 구성 (Revised)

| Agent 파일 | 모델 | 역할 | 위계 |
| :--- | :--- | :--- | :--- |
| **`architect.md`** | **github_copilot/claude-opus-4-6** | **Chief Architect (수석)** | **★★★★★ (최고 결정권자)** |
| `main.md` | github_copilot/gpt-4.1 | Orchestrator (팀장) | ★★★★ |
| `developer.md` | github_copilot/gpt-5.3-codex | Senior Developer | ★★★ |
| `gemini.md` | **google_genai/gemini-3.0-pro** | **Specialist (특수분석)** | ★★★ (도구 지원) |
| `researcher.md` | github_copilot/claude-sonnet-4-6 | Researcher | ★★★ |
| `guard.md` | github_copilot/gpt-5-mini | Monitoring | ★★ |

### 6.1 역할 상세

#### **@architect (Claude Opus 4.6)**
*   **권한:** 프로젝트의 모든 기술적 난제에 대한 **최종 판결**을 내림.
*   **임무:** 아키텍처 설계, 보안 감사 최종 승인, `@developer`가 5회 실패한 문제의 해결 방향 제시.
*   **비용:** 가장 고성능/고비용 모델이므로, 결정적인 순간에만 호출.

#### **@gemini (Gemini 3.0 Pro + CLI Tools)**
*   **권한:** 독립적인 결정권 없음. 아키텍트나 팀장의 요청에 따라 **정보를 수집하고 분석하여 보고**함.
*   **임무:**
    1.  `investigate_codebase`: 아키텍트가 의심하는 모듈의 의존성 전수 조사.
    2.  `browser_use`: 아키텍트가 요청한 최신 칩셋 에라타(Errata) 및 포럼 검색.
    3.  **보고:** 분석된 Raw Data와 1차 견해를 아키텍트에게 제출.

## 7. 에스컬레이션 시나리오 (Revised)

1.  `developer` (GPT-5.3)가 빌드 실패. (1~4차 시도)
2.  **5차 실패 시** → `main`이 **`architect` (Opus 4.6)** 호출.
3.  **`architect` 판단:** "이건 레지스터 충돌 문제 같은데, 최신 데이터시트와 전체 코드의 인터럽트 우선순위를 확인해야 해."
4.  **`architect` 명령:** " **@gemini**, `browser_use`로 STM32H7xx Errata Sheet를 확인하고, `investigate_codebase`로 `stm32_it.c`를 조사해서 보고해."
5.  **`gemini` 실행:** 도구 사용 후 결과 리포트 제출.
6.  **`architect` 최종 해결:** 리포트를 바탕으로 수정된 아키텍처/코드 지시.

***

## 8. 기술 스택 (Tech Stack)

### 8.1 4650G 서버 필수 설치 목록

```bash
# 컨테이너 환경
docker + docker-compose

# Nanobot (에이전트 호스트)
git clone https://github.com/nanobot-ai/nanobot
cd nanobot && make

# 지식베이스 (RAG, MCP 서버 포함)
docker run -d -p 3001:3001 \
  -v ./anythingllm:/app/server/storage \
  --name anythingllm \
  mintplexlabs/anythingllm

# ── LiteLLM 프록시 (GitHub Copilot OAuth 브릿지, 필수) ──
pip install 'litellm[proxy]'

# ── Gemini CLI (Specialist Agent용) ──
npm install -g @google/gemini-cli

# 빌드 환경
docker pull espressif/idf:latest        # ESP-IDF
docker pull registry/stm32cubeide       # STM32

# 시뮬레이션
snap install renode
apt install qemu-kvm

# MCP 서버 의존성
pip install mcp                          # Python MCP SDK
npm install -g @modelcontextprotocol/server-github
npm install -g @modelcontextprotocol/server-telegram

# 정적 분석
apt install cppcheck
```

### 8.2 Nanobot 설정

Nanobot은 `~/embedded-lab/` 디렉토리 전체를 설정으로 인식합니다:

```bash
# LiteLLM을 먼저 실행한 후 Nanobot 시작 (start.sh 에서 자동화)
nanobot run ~/embedded-lab/
```

- **LiteLLM 연동:** `OPENAI_API_BASE=http://localhost:4000` 으로 LiteLLM을 OpenAI 공급자로 사용합니다.
- **Gemini CLI 연동:** `gemini-mcp` 서버를 통해 `@gemini` 에이전트가 CLI 도구를 호출합니다.

***

## 9. Cron Job 설계

Nanobot은 내장 cron 기능을 제공하지 않습니다. 대신 **시스템 cron + 래퍼 스크립트** 조합으로 동일한 기능을 구현합니다.

> **설계 원칙:** Guard 에이전트의 24/7 감시는 cron이 30초마다 래퍼 스크립트를 호출하는 방식으로 구현합니다. 각 작업은 독립 프로세스로 실행되어 세션이 격리됩니다.

### 9.1 Cron 설계 원칙

```
정확한 시각에 실행 필요?
    YES → 시스템 cron (crontab) 사용
    NO  ↓

주기적 헬스체크 (30초 단위)?
    YES → 30초 cron + 래퍼 스크립트
    NO  ↓

복잡한 조건부 워크플로우?
    YES → n8n 워크플로우 자동화 (MCP 지원)
    NO  → 단순 bash 래퍼 스크립트
```

### 9.2 래퍼 스크립트 (Guard 24/7 감시)

**`/embedded-lab/scripts/guard_heartbeat.sh`:**
```bash
#!/bin/bash
# Guard 에이전트 대신 30초마다 실행되는 로그 감시 스크립트
# Nanobot이 내장 Heartbeat을 지원하지 않으므로 cron으로 대체

LOG_FILE="/var/log/serial.log"
STATUS_FILE="/tmp/guard_last_error.txt"
ALERT_COOLDOWN=300   # 같은 에러 5분 내 재알림 방지

# 에러 패턴 탐지
ERRORS=$(grep -E "\[ERROR\]|HardFault|Stack Overflow|FAULT" "$LOG_FILE" \
  | tail -500 | head -50)

if [ -n "$ERRORS" ]; then
    # 중복 체크: 같은 에러가 이미 알림됐으면 스킵
    CURRENT_HASH=$(echo "$ERRORS" | md5sum | cut -d' ' -f1)
    LAST_HASH=$(cat "$STATUS_FILE" 2>/dev/null || echo "")

    if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        echo "$CURRENT_HASH" > "$STATUS_FILE"
        # 텔레그램 직접 호출 (Nanobot 없이도 알림 가능)
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
          -d "chat_id=${TELEGRAM_CHAT_ID}" \
          -d "text=[GUARD ALERT] 에러 감지: $(echo "$ERRORS" | head -5)"
    fi
fi
```

### 9.3 시스템 Cron 등록 (임베디드 개발 4종)

**`crontab -e` 에 추가:**
```bash
# 30초마다: Guard 로그 감시 (Heartbeat 대체)
* * * * * /embedded-lab/scripts/guard_heartbeat.sh
* * * * * sleep 30 && /embedded-lab/scripts/guard_heartbeat.sh

# 매일 07:50: arXiv 논문 크롤링 사전 준비
50 7 * * * /embedded-lab/scripts/arxiv_fetch.sh

# 매일 08:00: 아침 브리핑 (Nanobot researcher 에이전트 호출)
0 8 * * * /embedded-lab/scripts/morning_briefing.sh

# 매일 00:00: 야간 배치 빌드 (Nanobot developer 에이전트 호출)
0 0 * * * /embedded-lab/scripts/nightly_build.sh

# 매주 월요일 09:00: 주간 아키텍처 리뷰 (Nanobot architect 에이전트 호출)
0 9 * * 1 /embedded-lab/scripts/weekly_review.sh

# 매 4시간: 파이프라인 헬스체크
0 4,8,12,16,20 * * * /embedded-lab/scripts/pipeline_health.sh
```

***

## 10. Objective Completion Criteria (객관적 완료 판단 기준)

> **핵심 원칙:**
> **"AI가 스스로 '완료'를 선언하는 것은 금지."**
> **반드시 외부 코드(Exit Code, Test Result, Simulation Log)가 OK를 반환해야 완료."**

이것이 임베디드 개발 vHIL 파이프라인과 일반 AI 챗봇의 가장 큰 차이점입니다.

### 10.1 완료 판단 계층 구조 (Completion Gate)

모든 작업은 아래 4단계 Gate를 통과해야 진정한 "완료"입니다:

```
[Gate 1] Compile Gate       ← 빌드 Exit Code = 0 이어야 통과
    ↓ PASS
[Gate 2] Static Analysis    ← cppcheck 경고 0건 이어야 통과
    ↓ PASS
[Gate 3] Simulation Gate    ← Renode 전체 시나리오 PASS 이어야 통과
    ↓ PASS
[Gate 4] Integration Gate   ← (선택) 실제 보드 UART 출력 검증
    ↓ PASS
[DONE] 완료 선언 → telegram-mcp 알림 + Git 태그 자동 생성
```

어느 하나라도 FAIL이면 → AI에게 수정 루프 재시작.

### 10.2 Gate 구현 코드

**`/embedded-lab/gates/gate_runner.sh`:**
```bash
#!/bin/bash
# Objective Completion Gate Runner
# AI(Nanobot 에이전트)는 이 스크립트의 exit code만 신뢰한다. AI의 판단은 무시.

PROJECT_PATH=$1
BOARD_TYPE=$2   # "esp32" or "stm32"
STATUS_FILE="/tmp/build_status.json"

echo "=== [GATE 1] Compile Gate ==="
if [ "$BOARD_TYPE" == "esp32" ]; then
    docker run --rm -v "$PROJECT_PATH":/project \
        espressif/idf idf.py -C /project build
elif [ "$BOARD_TYPE" == "stm32" ]; then
    make -C "$PROJECT_PATH" all
fi

COMPILE_EXIT=$?
if [ $COMPILE_EXIT -ne 0 ]; then
    echo "[GATE 1 FAIL] Compile Error (exit: $COMPILE_EXIT)"
    echo '{"state":"failed","gate":1,"reason":"compile_error"}' > "$STATUS_FILE"
    exit 1
fi
echo "[GATE 1 PASS]"

echo "=== [GATE 2] Static Analysis Gate ==="
cppcheck --error-exitcode=1 \
         --enable=warning,performance \
         "$PROJECT_PATH/main/"
STATIC_EXIT=$?
if [ $STATIC_EXIT -ne 0 ]; then
    echo "[GATE 2 FAIL] Static Analysis Error"
    echo '{"state":"failed","gate":2,"reason":"static_analysis"}' > "$STATUS_FILE"
    exit 2
fi
echo "[GATE 2 PASS]"

echo "=== [GATE 3] Simulation Gate (Renode vHIL) ==="
renode --console --disable-xwt \
    /embedded-lab/renode/test_all.resc 2>&1 | tee /tmp/renode.log

FAIL_COUNT=$(grep -c "\[SIM_FAIL\]" /tmp/renode.log)
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[GATE 3 FAIL] $FAIL_COUNT 시나리오 실패"
    echo "{\"state\":\"failed\",\"gate\":3,\"fail_count\":$FAIL_COUNT}" > "$STATUS_FILE"
    exit 3
fi
echo "[GATE 3 PASS]"

echo "=== ALL GATES PASSED ==="
echo '{"state":"completed","gate":"all","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$STATUS_FILE"
exit 0    # 이 exit 0만이 진정한 "완료" 신호
```

***

## 11. 성능 요구사항

| 항목 | 목표값 | 비고 |
| :--- | :--- | :--- |
| **빌드 응답 시간** | 2분 이내 (ESP-IDF 증분 빌드) | 4650G 6코어 활용 |
| **로그 알림 지연** | 에러 발생 후 30초 이내 | cron Heartbeat 30초 주기 |
| **RAG 검색 응답** | 5초 이내 | 로컬 AnythingLLM |
| **vHIL 테스트 처리** | 6개 시나리오 병렬 실행 | Renode + 6코어 |
| **서버 가동률** | 99% 이상 (24/7) | AC Power Loss: Always On 설정 |
| **Agent API 비용** | 월 $0 | GitHub Copilot 학생 구독 + LiteLLM OAuth |

***

## 12. 전체 파일 트리 (Directory Structure)

```
~/embedded-lab/                       ← nanobot run 의 대상 디렉토리
├── .env                              ← API 키 저장 (Git 커밋 절대 금지)
├── .env.example                      ← 키 없는 템플릿 (Git 커밋 OK)
├── .gitignore
├── litellm_config.yaml               ← LiteLLM 모델 라우팅 설정 (Git 커밋 OK)
├── start.sh                          ← LiteLLM → Nanobot 순서 실행 래퍼
│
├── agents/                           ← Nanobot 에이전트 정의
│   ├── main.md                       ← Orchestrator (기본 진입점)
│   ├── architect.md                  ← Chief Architect (Opus 4.6)
│   ├── developer.md                  ← Developer (GPT-5.3)
│   ├── gemini.md                     ← Specialist (Gemini 3.0 Pro)
│   ├── guard.md                      ← Guard (GPT-5-mini)
│   └── researcher.md                 ← Researcher (Claude 3.7)
│
├── mcp-servers.yaml                  ← MCP 서버 정의 (Gemini CLI 포함)
│
├── mcp-servers/                      ← 커스텀 MCP 서버 소스 코드
│   ├── esp_idf_mcp.py               ← ESP-IDF 빌드 MCP
│   └── (기타 3종)
│
├── gates/
│   └── gate_runner.sh               ← Completion Gate (chmod +x 필수)
│
├── scripts/
│   └── (cron 래퍼 스크립트들)
│
└── renode/
    └── test_all.resc                ← Renode 전체 시나리오 스크립트
```

***

## 13. 환경 변수 관리 (Secrets)

### 13.1 .env.example 템플릿

```bash
# ~/embedded-lab/.env.example

# ── LiteLLM Proxy 설정 (GitHub Copilot OAuth) ──
OPENAI_API_BASE=http://localhost:4000
OPENAI_API_KEY=dummy
LITELLM_PORT=4000

# ── Gemini CLI 설정 (Specialist) ──
GOOGLE_API_KEY=your_gemini_api_key_here

# ── 알림 ──
TELEGRAM_BOT_TOKEN=your_bot_token
TELEGRAM_CHAT_ID=your_chat_id

# ── GitHub MCP ──
GITHUB_TOKEN=your_ghp_token

# ── 로컬 설정 (Ubuntu 24.04 기준 예시) ──
SERIAL_PORT=/dev/ttyUSB0
BAUD_RATE=115200
IDF_PATH=/opt/esp-idf
RENODE_PATH=/usr/bin/renode
PROJECT_PATH=/home/ubuntu/embedded-lab/firmware
```

***

## 14. Phase 1 설치 순서 (Step-by-step)

> AI가 이 섹션을 보고 순서대로 실행한다. 순서를 바꾸면 의존성 오류 발생.
> STEP 5 (GitHub Copilot OAuth 인증)는 자동화 불가.

```bash
# ── STEP 1 ~ 4 생략 (기존과 동일) ──

# ── STEP 5: litellm_config.yaml 작성 ──
# (Gemini 3.0 Pro 및 Opus 4.6 설정 포함)

# ── STEP 5b: GitHub Copilot OAuth 인증 ──
litellm --config ~/embedded-lab/litellm_config.yaml --port 4000

# ── STEP 6: 환경 변수 설정 ──
cp ~/embedded-lab/.env.example ~/embedded-lab/.env
nano ~/embedded-lab/.env

# ── STEP 7: MCP 커뮤니티 서버 및 Gemini CLI 설치 ──
npm install -g @modelcontextprotocol/server-github
npm install -g @modelcontextprotocol/server-telegram
npm install -g @google/gemini-cli

# ── STEP 12: LiteLLM + Nanobot 시작 ──
chmod +x ~/embedded-lab/start.sh
~/embedded-lab/start.sh
```

***

## 15. 구현 로드맵

### Phase 1 (1주차): 기반 구축
- [ ] Ubuntu Server 24.04 설치 및 SSH 설정
- [ ] Nanobot + LiteLLM + Gemini CLI 설치
- [ ] .env 설정

### Phase 2 (2주차): 핵심 에이전트 구축
- [ ] agents/*.md 파일 6종 작성 (Claude Opus Chief Architect 포함)
- [ ] mcp-servers.yaml 작성 (Gemini MCP 포함)
- [ ] gate_runner.sh 배포

### Phase 3 (3주차): 고급 기능
- [ ] AnythingLLM + PDF 지식베이스 구축
- [ ] Morning Briefing 자동화
- [ ] Renode vHIL 자동화

### Phase 4 (4주차): 최적화
- [ ] 에이전트 호출 비용 모니터링 (Opus 호출 횟수 제한)

***

## 16. 성공 지표 (KPI)

| 지표 | 현재 (Before) | 목표 (After) |
| :--- | :--- | :--- |
| **빌드~테스트 사이클 시간** | 30분 (수동) | 5분 (자동) |
| **아키텍처 결정 정확도** | - | 99% (Opus 4.6 검수) |
| **데이터시트 검색 시간** | 20분 (수동) | 30초 (Gemini Browser Use) |
| **월 AI API 비용** | $0 (미사용) | $0 (GitHub Copilot + Gemini Free Tier) |

***

## 17. OpenClaw → Nanobot 마이그레이션 대응표

| OpenClaw 개념 | Nanobot 대응 | 비고 |
| :--- | :--- | :--- |
| `SOUL.md` | `agents/*.md` | 표준 마크다운 |
| `SKILL.md` | `mcp-servers.yaml` | 표준 MCP |
| `HEARTBEAT.md` | `guard_heartbeat.sh` | Bash script |
| `ClawHub` | MCP 서버 생태계 | 오픈소스 |
| 독점 서버 | Apache 2.0 소스 감사 | 보안 |
| 유료 API | LiteLLM (Copilot) | 비용 $0 |

***

**문서 끝. (PRD v5.2 — Nanobot + Claude Opus Chief + Gemini Specialist)**
