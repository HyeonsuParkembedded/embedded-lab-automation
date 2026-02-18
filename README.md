# Embedded Lab AI Agent System

경상국립대 전자공학과 위성 시스템 연구실 — 임베디드 개발 자동화 파이프라인

> **PRD v5.2** 기반 | Nanobot + LiteLLM Proxy | GitHub Copilot OAuth ($0 모델 비용)

---

## 목차

1. [개요](#개요)
2. [시스템 아키텍처](#시스템-아키텍처)
3. [에이전트 팀](#에이전트-팀)
4. [MCP 서버](#mcp-서버)
5. [Gate 파이프라인](#gate-파이프라인)
6. [파일 구조](#파일-구조)
7. [설치 및 설정 가이드 (Ubuntu 24.04)](#설치-및-설정-가이드-ubuntu-2404)
8. [빠른 시작](#빠른-시작)
9. [환경 변수](#환경-변수)
10. [cron 스케줄](#cron-스케줄)
11. [스크립트 레퍼런스](#스크립트-레퍼런스)

---

## 개요

임베디드 펌웨어 개발의 반복 작업(빌드 → 정적 분석 → 시뮬레이션 → 통합 테스트)을 AI 에이전트 팀이 자동으로 처리하는 시스템입니다.

**핵심 특징**

- **$0 모델 비용** — GitHub Copilot OAuth를 LiteLLM Proxy가 GPT-4.1 / Claude Opus 4.6 / Gemini 3.0 Pro로 라우팅
- **완전 로컬** — 모든 서비스가 온프레미스 서버(Ryzen 5 4650G, Ubuntu 24.04)에서 실행
- **멀티 에이전트** — Nanobot이 역할별 전문 에이전트 8개를 조율
- **4단계 Gate** — Compile → Static Analysis → Simulation → Integration 순차 검증
- **24/7 자동화** — cron 기반 야간 빌드·아침 브리핑·헬스 체크 무인 운영

---

## 시스템 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                        cron 스케줄러                             │
│  00:00 nightly_build  07:50 arxiv_fetch  08:00 morning_briefing │
│  09:00 weekly_review  4h pipeline_health  30s guard_heartbeat   │
└────────────────────────┬────────────────────────────────────────┘
                         │ HTTP
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Nanobot (port 8080)                           │
│              Multi-Agent MCP Host (Apache 2.0)                  │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │@architect│  │@developer│  │@misra    │  │@reporter │        │
│  │Opus 4.6  │  │Codex 5.3 │  │Sonnet 4.6│  │Sonnet 4.6│        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │@gemini   │  │@researcher│ │@guard    │  │@main     │        │
│  │Gemini Pro│  │GPT-4.1   │  │Sonnet 4.6│  │GPT-4.1   │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
└─────────────────────────┬───────────────────────────────────────┘
                          │ OpenAI API (호환)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│              LiteLLM Proxy (port 4000)                          │
│         GitHub Copilot OAuth → 모델 라우팅                       │
└─────────────────────────────────────────────────────────────────┘

MCP 서버 (에이전트별 선택 연결)
  telegram-mcp  github-mcp    n8n-mcp       context7-mcp
  hyperbrowser  brave-search  memory-mcp    arm-mcp
  esp-idf-mcp   gemini-mcp
```

---

## 에이전트 팀

| 에이전트 | 모델 | 역할 | 호출 시점 |
|---|---|---|---|
| **@architect** | Claude Opus 4.6 | 최고 결정권자. 설계 판단·에스컬레이션 해결 | 난제 발생, N회 실패 후 |
| **@developer** | GPT-5.3 Codex | 펌웨어 코드 작성·빌드 수정 | Gate 1/3/4 실패 시 |
| **@misra-agent** | Claude Sonnet 4.6 | 정적 분석·MISRA-C 2023 위반 처리 | Gate 2 실패 시 |
| **@guard** | Claude Sonnet 4.6 | Gate 3/4 담당·런타임 안전 감시 | 시뮬레이션·통합 테스트 |
| **@reporter** | Claude Sonnet 4.6 | 빌드 리포트·논문 요약 문서 생성 | 빌드 완료·문서 요청 |
| **@gemini** | Gemini 3.0 Pro | 고급 브라우저 자동화·코드 전수 조사 | @architect 지시 |
| **@researcher** | GPT-4.1 | arXiv 논문 요약·공식 문서 검색 | 아침 브리핑·기술 조사 |
| **@main** | GPT-4.1 | Orchestrator. 작업 분배·위계 관리 | 상시 |

### 에스컬레이션 흐름

```
Gate 1/3/4 실패
  └─ @developer (최대 4회)
       └─ 해결 실패 → @architect

Gate 2 실패 (MISRA)
  └─ @misra-agent (최대 2회)
       └─ 해결 실패 → @architect

런타임 경보 (guard_heartbeat.sh)
  └─ @guard 분류
       ├─ HardFault / 패닉 → @architect
       ├─ WDT 반복        → @developer
       └─ 빌드 에러       → nightly_build.sh 루틴
```

---

## MCP 서버

| 서버 | 패키지 | 담당 에이전트 | 용도 |
|---|---|---|---|
| `telegram-mcp` | `@modelcontextprotocol/server-telegram` | @main, @reporter, @guard | 알림 발송 |
| `github-mcp` | `@modelcontextprotocol/server-github` | 전체 | PR·이슈·코드 관리 |
| `n8n-mcp` | `@n8n/mcp-server` | @main | 복잡한 조건부 워크플로우 |
| `context7-mcp` | `@upstash/context7-mcp` | @architect, @developer, @researcher | 공식 문서 실시간 조회 |
| `hyperbrowser-mcp` | `@hyperbrowser/mcp` | @gemini | 스크린샷·JS 실행·웹 스크래핑 |
| `brave-search-mcp` | `@modelcontextprotocol/server-brave-search` | @gemini, @researcher | 데이터시트·Errata 검색 |
| `memory-mcp` | `@modelcontextprotocol/server-memory` | @architect, @developer, @researcher | 세션 간 지식 그래프 유지 |
| `arm-mcp` | `@arm-developer/mcp-server` | @architect, @developer | Cortex-M 레퍼런스·CMSIS |
| `hwpx-mcp` | `uvx hwpx-mcp-server` | @reporter | 한글(.hwpx) 문서 읽기·편집·생성 (국내 제출용) |
| `esp-idf-mcp` | 커스텀 Python | @developer | ESP-IDF 빌드·플래시 |
| `gemini-mcp` | `gemini-cli mcp-server` | @gemini | Gemini 네이티브 도구 |

---

## Gate 파이프라인

`gate_runner.sh`가 4단계를 순차 실행합니다. 한 단계라도 실패하면 해당 번호를 종료 코드로 반환합니다.

```
┌─────────────────────────────────────────────────────────────────┐
│  Gate 1 — Compile                                               │
│  ESP32: idf.py build  /  STM32: cmake --build                  │
│  실패 → exit 1 → @developer                                     │
├─────────────────────────────────────────────────────────────────┤
│  Gate 2 — Static Analysis                                       │
│  cppcheck --addon=misra.py                                      │
│  실패 → exit 2 → @misra-agent (전담)                            │
├─────────────────────────────────────────────────────────────────┤
│  Gate 3 — Simulation (vHIL)                                     │
│  ESP32: qemu-system-xtensa  /  STM32: Renode                   │
│  실패 패턴: HardFault, Guru Meditation, STACK OVERFLOW 등 14종  │
│  실패 → exit 3 → @developer                                     │
├─────────────────────────────────────────────────────────────────┤
│  Gate 4 — Integration (실제 보드)                                │
│  ESP32: idf.py flash  /  STM32: st-flash or openocd            │
│  serial_capture.py 로 부팅 확인 ("SYSTEM READY")               │
│  실패 → exit 4 → @developer                                     │
│  (GATE4_SKIP=1 로 CI 환경에서 건너뜀 가능)                      │
└─────────────────────────────────────────────────────────────────┘
```

**종료 코드 → 에이전트 라우팅**

```
exit 0  — 전체 통과 → Git 태그 생성 + Telegram 성공 알림
exit 1  — Gate 1 실패 → @developer (최대 4회)
exit 2  — Gate 2 실패 → @misra-agent (최대 2회)
exit 3  — Gate 3 실패 → @developer (최대 4회)
exit 4  — Gate 4 실패 → @developer (최대 4회)
모두 실패 → @architect 에스컬레이션
```

---

## 파일 구조

```
embedded-lab-automation/
├── README.md                        ← 이 파일
├── SKILL.md                         ← Claude Code 스킬 정의
├── assets/
│   ├── install.sh                   ← 원클릭 설치 스크립트
│   │
│   ├── agents/                      ← Nanobot 에이전트 정의
│   │   ├── main.md                  ← Orchestrator (GPT-4.1)
│   │   ├── architect.md             ← 수석 아키텍트 (Opus 4.6)
│   │   ├── developer.md             ← 시니어 개발자 (Codex 5.3)
│   │   ├── misra-agent.md           ← MISRA 전담 (Sonnet 4.6)
│   │   ├── guard.md                 ← 안전 감시 (Sonnet 4.6)
│   │   ├── reporter.md              ← 문서 작성 (Sonnet 4.6)
│   │   ├── gemini.md                ← 도구 지원 (Gemini Pro)
│   │   └── researcher.md            ← 기술 조사 (GPT-4.1)
│   │
│   ├── configs/
│   │   ├── litellm_config.yaml      ← LiteLLM 모델 라우팅
│   │   ├── mcp-servers.yaml         ← MCP 서버 10개 정의
│   │   └── .env.example             ← 환경 변수 템플릿
│   │
│   ├── gates/
│   │   └── gate_runner.sh           ← Gate 1~4 순차 실행기
│   │
│   ├── mcp-servers/                 ← 커스텀 MCP 서버
│   │   └── esp_idf_mcp.py           ← ESP-IDF 전용 MCP 서버
│   │
│   ├── sim/                         ← Renode 시뮬레이션 스크립트
│   │   └── stm32f4_test.resc        ← STM32F4 Discovery 예제
│   │
│   └── scripts/
│       ├── nightly_build.sh         ← 야간 배치 빌드 (00:00)
│       ├── guard_heartbeat.sh       ← 런타임 에러 감시 (30초)
│       ├── morning_briefing.sh      ← 아침 브리핑 (08:00)
│       ├── arxiv_fetch.sh           ← arXiv 수집 (07:50)
│       ├── weekly_review.sh         ← 주간 리뷰 (월 09:00)
│       ├── pipeline_health.sh       ← 헬스 체크 (4시간)
│       └── serial_capture.py        ← 시리얼 부팅 확인 도구
│
└── references/
    ├── PRD_v5.1.md
    └── PRD_v5.2.md
```

**배포 후 서버 디렉토리 구조** (`~/embedded-lab/`)

```
~/embedded-lab/
├── .env                 ← API 키 (chmod 600)
├── nanobot.yaml         ← Nanobot 설정
├── agents/              ← 에이전트 .md 파일
├── configs/             ← litellm_config.yaml, mcp-servers.yaml
├── gates/               ← gate_runner.sh
├── scripts/             ← 모든 자동화 스크립트
├── mcp-servers/         ← 커스텀 MCP 서버 (esp_idf_mcp.py)
├── firmware/            ← 빌드 대상 프로젝트
├── sim/                 ← Renode .resc 스크립트
├── reports/             ← 생성된 보고서 (.pdf/.docx/.pptx/.hwpx)
├── .memory/             ← Memory MCP 지식 그래프
└── logs/                ← 모든 스크립트 로그
```

---

## 설치 및 설정 가이드 (Ubuntu 24.04)

본 저장소의 `install.sh`를 통해 시스템을 Ubuntu 서버에 간편하게 배포할 수 있습니다.

### 7.1 Nanobot (에이전트 호스트) 설치
Nanobot은 멀티 에이전트와 MCP 서버를 조율하는 핵심 엔진입니다.
- **자동 설치:** `install.sh` 실행 시 `npm` 또는 `go install`을 통해 자동으로 설치됩니다.
- **수동 설치:**
  ```bash
  sudo npm install -g nanobot
  # 또는
  go install github.com/nanobot-ai/nanobot@latest
  ```
- **설정:** `~/embedded-lab/nanobot.yaml` 파일에서 에이전트 디렉토리와 환경 변수 파일을 관리합니다.

### 7.2 MCP 서버 설정 및 구동
MCP(Model Context Protocol) 서버는 에이전트에게 도구(Tool)를 제공합니다.
- **정의:** `~/embedded-lab/configs/mcp-servers.yaml`에 모든 연결 정보가 명시되어 있습니다.
- **커스텀 서버 (`esp-idf-mcp`):**
  - 본 프로젝트 전용 Python 서버입니다 (`mcp-servers/esp_idf_mcp.py`).
  - 에이전트가 `build`, `flash`, `size`, `clean` 명령을 수행할 수 있게 합니다.
  - 실행에 `mcp` Python 패키지가 필요하며, `install.sh`가 이를 자동으로 설치합니다.
- **표준 서버:** Telegram, GitHub, Brave Search 등은 `npx`를 통해 요청 시 자동 실행됩니다.

### 7.3 Skill 시스템 활용
**Gemini CLI** 및 **Claude Code**와 호환되는 Skill 정의(`SKILL.md`)가 포함되어 있습니다.
- **Skill 로드:** Gemini CLI 실행 시 본 디렉토리를 참조하면, 에이전트가 `SKILL.md`에 정의된 워크플로우를 자동으로 학습합니다.
- **명령어:** 
  - `activate_skill skill-creator`: 새로운 에이전트 기능을 확장할 때 사용합니다.
  - 에이전트에게 "임베디드 랩 시스템 인수인계 자료 읽어줘"와 같이 직접 질문할 수 있습니다.

---

## 빠른 시작

### 1. 설치

```bash
# 스킬 디렉토리에서 실행
cd assets/
bash install.sh

# 옵션: ESP-IDF 이미 설치된 경우
bash install.sh --skip-esp-idf

# 하드웨어 없는 CI 서버
bash install.sh --skip-esp-idf --skip-renode
```

### 2. API 키 설정

```bash
nano ~/embedded-lab/.env
```

필수 항목:
- `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` — 알림 수신
- `GITHUB_TOKEN` — PR·이슈 관리
- `GOOGLE_API_KEY` — Gemini 3.0 Pro (@gemini 에이전트)

### 3. 서비스 시작

```bash
# LiteLLM Proxy (GitHub Copilot → 모델 라우팅)
sudo systemctl start litellm-proxy
curl http://localhost:4000/health

# Nanobot (에이전트 호스트)
sudo systemctl start nanobot
curl http://localhost:8080/v1/models
```

### 4. 수동 테스트

```bash
# Gate 전체 실행
bash ~/embedded-lab/gates/gate_runner.sh \
    ~/embedded-lab/firmware esp32

# 시리얼 캡처 단독 테스트
python3 ~/embedded-lab/scripts/serial_capture.py \
    --port /dev/ttyUSB0 --baud 115200 \
    --expect "SYSTEM READY" --timeout 30 --timestamp

# 파이프라인 상태 점검
bash ~/embedded-lab/scripts/pipeline_health.sh
```

---

## 환경 변수

| 변수 | 필수 | 기본값 | 설명 |
|---|---|---|---|
| `OPENAI_API_BASE` | ✓ | `http://localhost:4000` | LiteLLM Proxy 주소 |
| `OPENAI_API_KEY` | ✓ | `dummy` | LiteLLM 더미 키 |
| `GOOGLE_API_KEY` | ✓ | — | Gemini API 키 |
| `TELEGRAM_BOT_TOKEN` | ✓ | — | Telegram 봇 토큰 |
| `TELEGRAM_CHAT_ID` | ✓ | — | Telegram 채팅 ID |
| `GITHUB_TOKEN` | ✓ | — | GitHub PAT |
| `BRAVE_API_KEY` | 권장 | — | Brave Search API |
| `HYPERBROWSER_API_KEY` | 권장 | — | Hyperbrowser API |
| `N8N_API_URL` | 선택 | `http://localhost:5678/api/v1` | n8n 서버 주소 |
| `N8N_API_KEY` | 선택 | — | n8n API 키 |
| `ARM_API_KEY` | 선택 | — | ARM Developer API |
| `SERIAL_PORT` | 선택 | `/dev/ttyUSB0` | 보드 연결 포트 |
| `BAUD_RATE` | 선택 | `115200` | 시리얼 보드레이트 |
| `IDF_PATH` | 선택 | `/opt/esp-idf` | ESP-IDF 경로 |
| `RENODE_PATH` | 선택 | `/usr/bin/renode` | Renode 실행 파일 |
| `PROJECT_PATH` | 선택 | `/home/ubuntu/embedded-lab/firmware` | 빌드 대상 경로 |
| `BOARD_TYPE` | 선택 | `esp32` | 타겟 보드 |
| `MAX_RETRY` | 선택 | `4` | @developer 최대 재시도 |
| `MAX_RETRY_MISRA` | 선택 | `2` | @misra-agent 최대 재시도 |
| `GATE4_SKIP` | 선택 | `0` | `1`이면 Gate 4 건너뜀 |
| `GATE4_EXPECT` | 선택 | `SYSTEM READY` | Gate 4 성공 키워드 |
| `MEMORY_FILE_PATH` | 선택 | `~/.memory/knowledge.json` | Memory MCP 파일 |

---

## cron 스케줄

```
# ── Embedded Lab AI Agent System ─────────────────────────────
0  0  * * *    nightly_build.sh         매일 자정 — Gate 1~4 + 에이전트 루프
50 7  * * *    arxiv_fetch.sh           매일 07:50 — arXiv 임베디드/위성 논문 수집
0  8  * * *    morning_briefing.sh      매일 08:00 — 빌드 결과 + 논문 요약 브리핑
0  9  * * 1    weekly_review.sh         매주 월요일 09:00 — 주간 아키텍처 리뷰
0 4,8,12,16,20 * * *  pipeline_health.sh   4시간마다 — 서비스 상태 점검
* * * * *      guard_heartbeat.sh       매분 — 시리얼/빌드 로그 에러 감시
* * * * * sleep 30 && guard_heartbeat.sh  30초 오프셋
```

---

## 스크립트 레퍼런스

### `nightly_build.sh`
야간 배치 빌드의 핵심 루프.

```
gate_runner.sh 실행
  └─ Gate 2 실패 → @misra-agent (MAX_RETRY_MISRA=2)
  └─ Gate 1/3/4 실패 → @developer (MAX_RETRY=4)
  └─ 모두 실패 → @architect 에스컬레이션
  └─ 성공 → Git 태그 nightly-YYYYMMDD + Telegram 알림
```

### `gate_runner.sh`
4단계 Gate를 순차 실행. 종료 코드 = 실패 Gate 번호 (0=전체 통과).

### `serial_capture.py`
시리얼 포트 캡처 및 부팅 확인 전용 도구.

```bash
# 종료 코드
# 0 — expect 키워드 수신 (성공)
# 1 — 타임아웃
# 2 — 실패 패턴 탐지 (HardFault 등)
# 3 — 포트 열기 실패
```

### `guard_heartbeat.sh`
30초마다 실행. 시리얼·빌드 로그에서 14종 에러 패턴 탐지 시 Telegram 경보.

### `morning_briefing.sh`
`arxiv_fetch.sh`가 수집한 논문을 @researcher가 한국어로 요약 → Telegram 전송.

### `arxiv_fetch.sh`
5개 키워드 쿼리로 arXiv API 검색 → `/tmp/arxiv_latest.json` 저장.

```
embedded+systems+RTOS
satellite+onboard+software+cFS
AUTOSAR+automotive+embedded
Zephyr+RTOS+firmware
CubeSat+flight+software
```

### `weekly_review.sh`
7일간 빌드 통계·Git 활동을 집계 → @architect 주간 아키텍처 리뷰 → Telegram 전송.

### `pipeline_health.sh`
LiteLLM(4000), Nanobot(8080), MCP 서버 프로세스 및 디스크·메모리·CPU 점검. 이상 시 자동 재시작 시도.

---

## 참고

- [PRD v5.2](references/PRD_v5.2.md) — 시스템 설계 원본 문서
- [Nanobot](https://github.com/nanobot-ai/nanobot) — 오픈소스 MCP Agent Host
- [LiteLLM](https://github.com/BerriAI/litellm) — 모델 프록시
- [Model Context Protocol](https://modelcontextprotocol.io) — MCP 표준
