---
name: embedded-lab-automation
description: >
  Sets up, operates, and extends the Embedded Lab AI Agent System built on Nanobot + LiteLLM Proxy.
  Use when: installing the system from scratch, adding/modifying Nanobot agents, configuring MCP servers,
  debugging the Gate pipeline (Compile → Static → Simulation → Integration), writing or updating
  automation scripts (nightly_build, guard_heartbeat, morning_briefing, arxiv_fetch, weekly_review,
  pipeline_health, serial_capture), or troubleshooting embedded firmware build failures on ESP32/STM32.
---

# Embedded Lab Automation Skill

경상국립대 전자공학과 위성 시스템 연구실 — 임베디드 AI 에이전트 시스템 운영 스킬

**PRD v5.2** 기반 | Nanobot + LiteLLM Proxy + GitHub Copilot OAuth

---

## 역할

이 스킬은 다음 상황에서 호출된다:

- 시스템 신규 설치 또는 마이그레이션
- Nanobot 에이전트 파일(`.md`) 생성·수정
- MCP 서버 추가·설정 변경
- Gate 파이프라인 디버깅 또는 스크립트 수정
- 빌드 실패 분석 및 에이전트 라우팅 조정
- 보고서·브리핑 자동화 흐름 변경

---

## 에이전트 파일

| 파일 | 모델 | 역할 |
|---|---|---|
| [agents/main.md](assets/agents/main.md) | GPT-4.1 | Orchestrator — 작업 분배·위계 관리 |
| [agents/architect.md](assets/agents/architect.md) | Claude Opus 4.6 | 수석 아키텍트 — 설계 결정·에스컬레이션 해결 |
| [agents/developer.md](assets/agents/developer.md) | GPT-5.3 Codex | 시니어 개발자 — 코드 작성·Gate 1/3/4 수정 |
| [agents/misra-agent.md](assets/agents/misra-agent.md) | Claude Sonnet 4.6 | MISRA 전담 — Gate 2(cppcheck) 위반 처리 |
| [agents/guard.md](assets/agents/guard.md) | Claude Sonnet 4.6 | 안전 감시 — Gate 3/4 판정·런타임 경보 처리 |
| [agents/reporter.md](assets/agents/reporter.md) | Claude Sonnet 4.6 | 문서 작성 — 빌드 리포트·논문 요약 .pdf/.docx/.pptx |
| [agents/gemini.md](assets/agents/gemini.md) | Gemini 3.0 Pro | 도구 전문가 — 브라우저 자동화·코드 전수 조사 |
| [agents/researcher.md](assets/agents/researcher.md) | GPT-4.1 | 기술 조사 — arXiv 요약·Context7 문서 검색 |

---

## 설정 파일

| 파일 | 용도 |
|---|---|
| [configs/litellm_config.yaml](assets/configs/litellm_config.yaml) | LiteLLM Proxy 모델 라우팅 (GitHub Copilot OAuth) |
| [configs/mcp-servers.yaml](assets/configs/mcp-servers.yaml) | MCP 서버 10개 정의 |
| [configs/.env.example](assets/configs/.env.example) | 환경 변수 템플릿 (API 키·경로) |

---

## 스크립트

| 파일 | 실행 주기 | 역할 |
|---|---|---|
| [scripts/nightly_build.sh](assets/scripts/nightly_build.sh) | 매일 00:00 | Gate 실행 → 에이전트 루프 → Git 태그 |
| [scripts/guard_heartbeat.sh](assets/scripts/guard_heartbeat.sh) | 30초마다 | 시리얼·빌드 로그 에러 패턴 감시 |
| [scripts/morning_briefing.sh](assets/scripts/morning_briefing.sh) | 매일 08:00 | 빌드 결과 + arXiv 논문 요약 Telegram 전송 |
| [scripts/arxiv_fetch.sh](assets/scripts/arxiv_fetch.sh) | 매일 07:50 | arXiv API 검색 → `/tmp/arxiv_latest.json` |
| [scripts/weekly_review.sh](assets/scripts/weekly_review.sh) | 매주 월 09:00 | 주간 빌드 통계 + @architect 리뷰 |
| [scripts/pipeline_health.sh](assets/scripts/pipeline_health.sh) | 4시간마다 | LiteLLM·Nanobot·MCP 서버 상태 점검·자동 재시작 |
| [scripts/serial_capture.py](assets/scripts/serial_capture.py) | gate_runner 호출 | 시리얼 부팅 확인 (pyserial, 종료 코드 0/1/2/3) |
| [gates/gate_runner.sh](assets/gates/gate_runner.sh) | nightly_build 호출 | Gate 1~4 순차 실행기 |
| [install.sh](assets/install.sh) | 초기 1회 | 원클릭 전체 설치 |

---

## 핵심 워크플로우

### 새 에이전트 추가
1. `assets/agents/` 에 `<name>.md` 생성 (frontmatter: `name`, `model`, `mcpServers`)
2. `assets/agents/main.md` frontmatter `agents:` 목록에 추가
3. `main.md` 시나리오 섹션에 호출 조건 추가
4. 서버에 배포: `cp assets/agents/<name>.md ~/embedded-lab/agents/`
5. Nanobot 재시작: `sudo systemctl restart nanobot`

### 새 MCP 서버 추가
1. `assets/configs/mcp-servers.yaml` 에 서버 정의 추가
2. `assets/configs/.env.example` 에 필요한 환경 변수 추가
3. 사용할 에이전트 `.md` frontmatter `mcpServers:` 에 추가
4. 서버에 배포 후 Nanobot 재시작

### Gate 파이프라인 수정
```
Gate 1 (Compile)  → gate_runner.sh: run_gate1()  → 보드별 빌드 명령
Gate 2 (Static)   → gate_runner.sh: run_gate2()  → cppcheck + misra.py
Gate 3 (Sim)      → gate_runner.sh: run_gate3()  → QEMU(ESP32) / Renode(STM32)
Gate 4 (HIL)      → gate_runner.sh: run_gate4()  → 플래시 + serial_capture.py
```
- 실패 패턴 추가: `gate_runner.sh` 의 `FAIL_PATTERNS` 배열 수정
- 성공 키워드 변경: `.env` 의 `GATE4_EXPECT` 수정
- CI에서 Gate 4 스킵: `.env` 에 `GATE4_SKIP=1` 추가

### 빌드 실패 디버깅 흐름
```
gate_runner.sh 종료 코드 확인
  exit 1 → Gate 1: 컴파일 에러 → compiler 로그 확인
  exit 2 → Gate 2: cppcheck → /tmp/gate2_cppcheck_*.xml 확인
  exit 3 → Gate 3: 시뮬레이션 → /tmp/gate3_sim_*.log 에서 FAIL 패턴 확인
  exit 4 → Gate 4: 보드 부팅 → /tmp/gate4_serial_*.log 확인
```

### 에스컬레이션 체계
```
Gate 2 실패 → @misra-agent (MAX_RETRY_MISRA=2회)
                └─ 실패 → @architect

Gate 1/3/4 실패 → @developer (MAX_RETRY=4회)
                   └─ 실패 → @architect

guard_heartbeat 경보 → @guard 분류
  HardFault / 패닉  → @architect 즉시
  WDT 반복          → @developer
  빌드 에러         → nightly_build 루틴
```

---

## 설치

```bash
# 전체 설치 (Ubuntu 24.04)
bash assets/install.sh

# 옵션
bash assets/install.sh --skip-esp-idf   # ESP-IDF 이미 설치됨
bash assets/install.sh --skip-renode    # Renode 불필요
bash assets/install.sh --skip-cron      # cron 수동 등록 예정
bash assets/install.sh --dry-run        # 계획만 출력
```

---

## MCP 서버 목록

| 서버 키 | 담당 에이전트 | API 키 |
|---|---|---|
| `telegram-mcp` | @main, @reporter, @guard | `TELEGRAM_BOT_TOKEN` |
| `github-mcp` | 전체 | `GITHUB_TOKEN` |
| `n8n-mcp` | @main | `N8N_API_KEY` |
| `context7-mcp` | @architect, @developer, @researcher | 불필요 |
| `hyperbrowser-mcp` | @gemini | `HYPERBROWSER_API_KEY` |
| `brave-search-mcp` | @gemini, @researcher | `BRAVE_API_KEY` |
| `memory-mcp` | @architect, @developer, @researcher | 불필요 |
| `arm-mcp` | @architect, @developer | `ARM_API_KEY` |
| `hwpx-mcp` | @reporter | 불필요 (uv 설치만 필요) |
| `esp-idf-mcp` | @developer | `IDF_PATH` |
| `gemini-mcp` | @gemini | `GOOGLE_API_KEY` |

---

## 참고 문서

- [README.md](README.md) — 전체 시스템 설명 (아키텍처 다이어그램 포함)
- [PRD v5.2](references/PRD_v5.2.md) — 시스템 설계 원본 문서
- [PRD v5.1](references/PRD_v5.1.md) — 이전 버전
