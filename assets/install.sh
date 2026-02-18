#!/bin/bash
# =============================================================================
# install.sh
# Embedded Lab AI Agent System — 원클릭 설치 스크립트
#
# 사용법:
#   bash install.sh [옵션]
#
# 옵션:
#   --install-dir DIR   설치 디렉토리 (기본값: ~/embedded-lab)
#   --skip-esp-idf      ESP-IDF 설치 건너뜀 (이미 설치된 경우)
#   --skip-renode       Renode 설치 건너뜀
#   --skip-cron         cron 작업 등록 건너뜀
#   --skip-nanobot      Nanobot 설치 건너뜀
#   --dry-run           실제 설치 없이 계획만 출력
#
# 예시:
#   bash install.sh
#   bash install.sh --install-dir /opt/embedded-lab --skip-esp-idf
# =============================================================================

set -euo pipefail

# ── 색상 정의 ─────────────────────────────────────────────────────────────────
C_RESET="\033[0m"
C_GREEN="\033[92m"
C_YELLOW="\033[93m"
C_RED="\033[91m"
C_CYAN="\033[96m"
C_BOLD="\033[1m"

info()    { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
success() { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
step()    { echo -e "\n${C_BOLD}${C_CYAN}━━━ $* ━━━${C_RESET}"; }

# ── 기본값 ────────────────────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/embedded-lab"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"   # install.sh 위치 = assets/
SKIP_ESP_IDF=0
SKIP_RENODE=0
SKIP_CRON=0
SKIP_NANOBOT=0
DRY_RUN=0

# ── 인수 파싱 ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --skip-esp-idf) SKIP_ESP_IDF=1; shift ;;
        --skip-renode)  SKIP_RENODE=1;  shift ;;
        --skip-cron)    SKIP_CRON=1;    shift ;;
        --skip-nanobot) SKIP_NANOBOT=1; shift ;;
        --dry-run)      DRY_RUN=1;      shift ;;
        *) error "알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

# dry-run 래퍼: DRY_RUN=1 이면 명령을 출력만 하고 실행하지 않음
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "  ${C_YELLOW}[dry-run]${C_RESET} $*"
    else
        "$@"
    fi
}

# ── 배너 ──────────────────────────────────────────────────────────────────────
echo -e "${C_BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   Embedded Lab AI Agent System — 설치 스크립트       ║"
echo "  ║   경상국립대 전자공학과 위성 시스템 연구실             ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${C_RESET}"
info "설치 디렉토리 : ${INSTALL_DIR}"
info "스킬 소스     : ${SKILL_DIR}"
info "Dry-run 모드  : $([ "$DRY_RUN" -eq 1 ] && echo '활성' || echo '비활성')"

# ── 함수: OS 확인 ─────────────────────────────────────────────────────────────
check_os() {
    step "OS 확인"
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        warn "Ubuntu가 아닌 OS에서 실행 중입니다. 패키지 설치가 실패할 수 있습니다."
    else
        local ver
        ver=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        success "Ubuntu ${ver} 확인"
    fi

    # sudo 권한 확인
    if ! sudo -n true 2>/dev/null; then
        warn "sudo 비밀번호가 필요할 수 있습니다."
    fi
}

# ── 함수: 시스템 패키지 ───────────────────────────────────────────────────────
install_system_deps() {
    step "시스템 패키지 설치 (apt)"

    local packages=(
        # 기본 도구
        curl wget git jq
        # Python
        python3 python3-pip python3-venv
        # Node.js (LTS)
        nodejs npm
        # 빌드 도구
        build-essential cmake ninja-build
        # 정적 분석
        cppcheck
        # 시리얼 통신
        minicom
        # 문서 변환
        pandoc
        # STM32 플래시 도구
        openocd
        # PDF 유틸
        poppler-utils
        # 기타
        lsof procps
    )

    info "apt 패키지 목록 업데이트..."
    run sudo apt-get update -qq

    info "패키지 설치: ${packages[*]}"
    run sudo apt-get install -y --no-install-recommends "${packages[@]}"

    # Node.js 버전 확인 (18 이상 필요)
    if command -v node &>/dev/null; then
        local node_ver
        node_ver=$(node -e "process.stdout.write(process.version)" 2>/dev/null | sed 's/v//')
        local node_major="${node_ver%%.*}"
        if [ "${node_major:-0}" -lt 18 ]; then
            warn "Node.js ${node_ver} — v18 이상 권장. NVM으로 업그레이드를 권장합니다."
        else
            success "Node.js ${node_ver}"
        fi
    fi

    success "시스템 패키지 설치 완료"
}

# ── 함수: Python 패키지 ───────────────────────────────────────────────────────
install_python_deps() {
    step "Python 패키지 설치 (pip)"

    local packages=(
        # 시리얼 통신 (serial_capture.py)
        pyserial
        # MCP Python SDK (esp-idf-mcp)
        mcp
        # PDF 생성 (reporter.md)
        reportlab
        # PDF 읽기
        pypdf pdfplumber
        # HTTP 요청 (arxiv_fetch.sh 내 Python 사용)
        requests
        # LiteLLM Proxy
        "litellm[proxy]"
        # MISRA cppcheck 애드온
        cppcheckdata
    )

    info "pip 업그레이드..."
    run pip3 install --quiet --upgrade pip

    info "Python 패키지: ${packages[*]}"
    run pip3 install --quiet "${packages[@]}"

    success "Python 패키지 설치 완료"
}

# ── 함수: Node.js 패키지 ──────────────────────────────────────────────────────
install_node_deps() {
    step "Node.js 전역 패키지 설치 (npm)"

    local packages=(
        # Word 문서 생성 (reporter.md)
        docx
        # PowerPoint 생성 (reporter.md)
        pptxgenjs
    )

    info "npm 전역 패키지: ${packages[*]}"
    run sudo npm install -g --quiet "${packages[@]}"

    success "Node.js 패키지 설치 완료"
}

# ── 함수: ESP-IDF 설치 ────────────────────────────────────────────────────────
install_esp_idf() {
    step "ESP-IDF 설치"

    if [ "$SKIP_ESP_IDF" -eq 1 ]; then
        warn "ESP-IDF 설치 건너뜀 (--skip-esp-idf)"
        return 0
    fi

    local idf_dir="${HOME}/esp/esp-idf"
    local idf_target="/opt/esp-idf"

    if [ -d "$idf_target" ]; then
        success "ESP-IDF 이미 설치됨: ${idf_target}"
        return 0
    fi

    info "ESP-IDF v5.x 클론 중..."
    run git clone --depth=1 --branch release/v5.3 \
        https://github.com/espressif/esp-idf.git "$idf_dir"

    info "ESP-IDF 의존성 설치 중 (5~10분 소요)..."
    run bash "${idf_dir}/install.sh" esp32,esp32s3,esp32c3

    # 심볼릭 링크 생성 (표준 경로)
    run sudo ln -sfn "$idf_dir" "$idf_target"

    success "ESP-IDF 설치 완료: ${idf_target}"
    info "사용하려면: source ${idf_target}/export.sh"
}

# ── 함수: Renode 설치 ─────────────────────────────────────────────────────────
install_renode() {
    step "Renode 설치 (STM32 시뮬레이션)"

    if [ "$SKIP_RENODE" -eq 1 ]; then
        warn "Renode 설치 건너뜀 (--skip-renode)"
        return 0
    fi

    if command -v renode &>/dev/null; then
        success "Renode 이미 설치됨: $(renode --version 2>/dev/null | head -1)"
        return 0
    fi

    info "Renode 최신 릴리스 다운로드 중..."
    local renode_deb="/tmp/renode_latest.deb"
    local renode_url
    renode_url=$(curl -s https://api.github.com/repos/renode/renode/releases/latest \
        | jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url' \
        | head -1)

    if [ -z "$renode_url" ]; then
        warn "Renode 다운로드 URL 조회 실패 — 수동 설치 필요: https://github.com/renode/renode/releases"
        return 0
    fi

    run curl -sL "$renode_url" -o "$renode_deb"
    run sudo apt-get install -y "$renode_deb"

    success "Renode 설치 완료"
}

# ── 함수: Nanobot 설치 ────────────────────────────────────────────────────────
install_nanobot() {
    step "Nanobot 설치"

    if [ "$SKIP_NANOBOT" -eq 1 ]; then
        warn "Nanobot 설치 건너뜀 (--skip-nanobot)"
        return 0
    fi

    if command -v nanobot &>/dev/null; then
        success "Nanobot 이미 설치됨"
        return 0
    fi

    # Nanobot은 Go 바이너리 또는 npm 패키지로 배포됨
    if command -v npm &>/dev/null; then
        info "Nanobot 설치 중 (npm)..."
        run sudo npm install -g --quiet nanobot 2>/dev/null || {
            warn "npm 설치 실패 — Go 바이너리로 시도..."
            install_nanobot_go
        }
    else
        install_nanobot_go
    fi
}

install_nanobot_go() {
    if ! command -v go &>/dev/null; then
        warn "Go 미설치 — Nanobot 수동 설치 필요"
        warn "설치 방법: https://github.com/nanobot-ai/nanobot#installation"
        return 0
    fi
    info "Nanobot 설치 중 (go install)..."
    run go install github.com/nanobot-ai/nanobot@latest
    success "Nanobot 설치 완료"
}

# ── 함수: uv 설치 (hwpx-mcp 실행 필요) ───────────────────────────────────────
install_uv() {
    step "uv 설치 (Python 패키지 실행기 — hwpx-mcp 필요)"

    if command -v uv &>/dev/null; then
        success "uv 이미 설치됨: $(uv --version)"
        return 0
    fi

    info "uv 설치 중..."
    run curl -LsSf https://astral.sh/uv/install.sh | sh

    # PATH 갱신 (현재 세션)
    export PATH="${HOME}/.cargo/bin:${PATH}"

    if command -v uv &>/dev/null; then
        success "uv 설치 완료: $(uv --version)"
        info "hwpx-mcp 서버는 Nanobot이 처음 실행 시 uvx로 자동 설치됩니다."
    else
        warn "uv 설치 후 PATH 갱신이 필요합니다: source ~/.bashrc"
    fi
}

# ── 함수: st-flash 설치 (STM32) ───────────────────────────────────────────────
install_stlink() {
    step "st-flash 설치 (STM32 플래시)"

    if command -v st-flash &>/dev/null; then
        success "st-flash 이미 설치됨"
        return 0
    fi

    info "stlink-tools 설치 중..."
    run sudo apt-get install -y --no-install-recommends stlink-tools 2>/dev/null || {
        warn "stlink-tools apt 설치 실패 — 소스 빌드 시도..."
        run sudo apt-get install -y cmake libusb-1.0-0-dev
        run git clone --depth=1 https://github.com/stlink-org/stlink /tmp/stlink
        run cmake -B /tmp/stlink/build /tmp/stlink
        run make -C /tmp/stlink/build -j"$(nproc)"
        run sudo make -C /tmp/stlink/build install
    }

    success "st-flash 설치 완료"
}

# ── 함수: 디렉토리 구조 생성 ──────────────────────────────────────────────────
setup_directories() {
    step "디렉토리 구조 생성"

    local dirs=(
        "${INSTALL_DIR}"
        "${INSTALL_DIR}/scripts"
        "${INSTALL_DIR}/gates"
        "${INSTALL_DIR}/agents"
        "${INSTALL_DIR}/configs"
        "${INSTALL_DIR}/sim"
        "${INSTALL_DIR}/reports"
        "${INSTALL_DIR}/firmware"
        "${INSTALL_DIR}/mcp-servers"
        "${INSTALL_DIR}/.memory"
        "${INSTALL_DIR}/logs"
    )

    for dir in "${dirs[@]}"; do
        run mkdir -p "$dir"
        info "  생성: ${dir}"
    done

    success "디렉토리 구조 생성 완료"
}

# ── 함수: 파일 배포 ───────────────────────────────────────────────────────────
deploy_files() {
    step "파일 배포"

    # 스크립트
    local scripts=(
        guard_heartbeat.sh
        morning_briefing.sh
        nightly_build.sh
        arxiv_fetch.sh
        weekly_review.sh
        pipeline_health.sh
        serial_capture.py
    )
    for f in "${scripts[@]}"; do
        if [ -f "${SKILL_DIR}/scripts/${f}" ]; then
            run cp "${SKILL_DIR}/scripts/${f}" "${INSTALL_DIR}/scripts/${f}"
            run chmod +x "${INSTALL_DIR}/scripts/${f}"
            info "  배포: scripts/${f}"
        else
            warn "  누락: scripts/${f}"
        fi
    done

    # Gate runner
    if [ -f "${SKILL_DIR}/gates/gate_runner.sh" ]; then
        run cp "${SKILL_DIR}/gates/gate_runner.sh" "${INSTALL_DIR}/gates/gate_runner.sh"
        run chmod +x "${INSTALL_DIR}/gates/gate_runner.sh"
        info "  배포: gates/gate_runner.sh"
    fi

    # 에이전트 정의 파일
    local agents=(
        main.md architect.md developer.md misra-agent.md
        reporter.md gemini.md researcher.md guard.md
    )
    for f in "${agents[@]}"; do
        if [ -f "${SKILL_DIR}/agents/${f}" ]; then
            run cp "${SKILL_DIR}/agents/${f}" "${INSTALL_DIR}/agents/${f}"
            info "  배포: agents/${f}"
        else
            warn "  누락: agents/${f}"
        fi
    done

    # 설정 파일
    local configs=(litellm_config.yaml mcp-servers.yaml)
    for f in "${configs[@]}"; do
        if [ -f "${SKILL_DIR}/configs/${f}" ]; then
            run cp "${SKILL_DIR}/configs/${f}" "${INSTALL_DIR}/configs/${f}"
            info "  배포: configs/${f}"
        fi
    done

    # 커스텀 MCP 서버
    if [ -d "${SKILL_DIR}/mcp-servers" ]; then
        run cp -r "${SKILL_DIR}/mcp-servers/." "${INSTALL_DIR}/mcp-servers/"
        info "  배포: mcp-servers/*"
    fi

    # 시뮬레이션 스크립트
    if [ -d "${SKILL_DIR}/sim" ]; then
        run cp -r "${SKILL_DIR}/sim/." "${INSTALL_DIR}/sim/"
        info "  배포: sim/*"
    fi

    success "파일 배포 완료"
}

# ── 함수: 환경 파일 설정 ──────────────────────────────────────────────────────
setup_env() {
    step ".env 환경 파일 설정"

    local env_file="${INSTALL_DIR}/.env"
    local env_example="${SKILL_DIR}/configs/.env.example"

    if [ -f "$env_file" ]; then
        warn ".env 이미 존재 — 덮어쓰기 건너뜀: ${env_file}"
        return 0
    fi

    if [ ! -f "$env_example" ]; then
        warn ".env.example 없음 — .env 수동 생성 필요"
        return 0
    fi

    run cp "$env_example" "$env_file"
    run chmod 600 "$env_file"   # API 키 보호

    success ".env 파일 생성: ${env_file}"
    echo ""
    echo -e "  ${C_YELLOW}▶ 다음 값을 .env 에 입력하세요:${C_RESET}"
    echo "    GOOGLE_API_KEY      — Gemini API 키"
    echo "    TELEGRAM_BOT_TOKEN  — Telegram 봇 토큰"
    echo "    TELEGRAM_CHAT_ID    — Telegram 채팅 ID"
    echo "    GITHUB_TOKEN        — GitHub Personal Access Token"
    echo "    BRAVE_API_KEY       — Brave Search API 키"
    echo "    HYPERBROWSER_API_KEY — Hyperbrowser API 키"
    echo "    N8N_API_KEY         — n8n API 키 (선택)"
    echo "    ARM_API_KEY         — ARM Developer API 키 (선택)"
    echo ""
    echo -e "  ${C_CYAN}편집 명령: nano ${env_file}${C_RESET}"
}

# ── 함수: Nanobot 설정 파일 생성 ──────────────────────────────────────────────
setup_nanobot_config() {
    step "Nanobot 설정 파일 생성"

    local nanobot_config="${INSTALL_DIR}/nanobot.yaml"

    if [ -f "$nanobot_config" ]; then
        warn "nanobot.yaml 이미 존재 — 건너뜀"
        return 0
    fi

    run cat > "$nanobot_config" <<'EOF'
# ~/embedded-lab/nanobot.yaml
agents_dir: ./agents
mcp_servers_file: ./configs/mcp-servers.yaml
env_file: ./.env

server:
  port: 8080
  host: 127.0.0.1

log:
  level: info
  file: ./logs/nanobot.log
EOF

    success "nanobot.yaml 생성: ${nanobot_config}"
}

# ── 함수: cron 작업 등록 ──────────────────────────────────────────────────────
setup_cron() {
    step "cron 작업 등록"

    if [ "$SKIP_CRON" -eq 1 ]; then
        warn "cron 등록 건너뜀 (--skip-cron)"
        print_cron_schedule
        return 0
    fi

    local s="${INSTALL_DIR}/scripts"

    # 기존 crontab 백업
    local cron_backup="/tmp/crontab_backup_$(date +%Y%m%d_%H%M%S).txt"
    run crontab -l > "$cron_backup" 2>/dev/null || true
    info "기존 crontab 백업: ${cron_backup}"

    # embedded-lab 블록이 이미 있으면 건너뜀
    if crontab -l 2>/dev/null | grep -q "embedded-lab"; then
        warn "embedded-lab cron 작업이 이미 등록되어 있습니다. 건너뜀."
        return 0
    fi

    # 새 cron 항목 추가
    local new_cron
    new_cron=$(cat <<EOF

# ── Embedded Lab AI Agent System ──────────────────────────
# 야간 빌드 (00:00)
0 0 * * * bash ${s}/nightly_build.sh >> ${INSTALL_DIR}/logs/nightly.log 2>&1

# arXiv 논문 수집 (07:50 — 브리핑 10분 전)
50 7 * * * bash ${s}/arxiv_fetch.sh >> ${INSTALL_DIR}/logs/arxiv.log 2>&1

# 아침 브리핑 (08:00)
0 8 * * * bash ${s}/morning_briefing.sh >> ${INSTALL_DIR}/logs/briefing.log 2>&1

# 주간 아키텍처 리뷰 (매주 월요일 09:00)
0 9 * * 1 bash ${s}/weekly_review.sh >> ${INSTALL_DIR}/logs/weekly.log 2>&1

# 파이프라인 헬스 체크 (4시간마다)
0 4,8,12,16,20 * * * bash ${s}/pipeline_health.sh >> ${INSTALL_DIR}/logs/health.log 2>&1

# Guard 하트비트 (매분 — 30초 오프셋 포함)
* * * * * bash ${s}/guard_heartbeat.sh >> ${INSTALL_DIR}/logs/heartbeat.log 2>&1
* * * * * sleep 30 && bash ${s}/guard_heartbeat.sh >> ${INSTALL_DIR}/logs/heartbeat.log 2>&1
# ────────────────────────────────────────────────────────────
EOF
)

    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${C_YELLOW}[dry-run]${C_RESET} crontab에 추가될 내용:"
        echo "$new_cron"
    else
        (crontab -l 2>/dev/null; echo "$new_cron") | crontab -
        success "cron 작업 등록 완료"
    fi

    print_cron_schedule
}

print_cron_schedule() {
    echo ""
    echo "  등록된 cron 스케줄:"
    echo "    00:00       nightly_build.sh    — Gate 1~4 + 에이전트 루프"
    echo "    07:50       arxiv_fetch.sh      — arXiv 논문 수집"
    echo "    08:00       morning_briefing.sh — 아침 브리핑 Telegram"
    echo "    09:00 (Mon) weekly_review.sh    — 주간 아키텍처 리뷰"
    echo "    4시간마다    pipeline_health.sh  — 서비스 상태 점검"
    echo "    30초마다     guard_heartbeat.sh  — 런타임 에러 감시"
    echo ""
}

# ── 함수: LiteLLM Proxy 서비스 등록 ──────────────────────────────────────────
setup_litellm_service() {
    step "LiteLLM Proxy systemd 서비스 등록"

    local service_file="/etc/systemd/system/litellm-proxy.service"

    if [ -f "$service_file" ]; then
        warn "litellm-proxy.service 이미 존재 — 건너뜀"
        return 0
    fi

    run sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=LiteLLM Proxy (GitHub Copilot OAuth Router)
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=$(command -v litellm) --config ${INSTALL_DIR}/configs/litellm_config.yaml --port 4000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    run sudo systemctl daemon-reload
    run sudo systemctl enable litellm-proxy
    success "litellm-proxy.service 등록 완료"
    info "시작: sudo systemctl start litellm-proxy"
}

# ── 함수: Nanobot 서비스 등록 ─────────────────────────────────────────────────
setup_nanobot_service() {
    step "Nanobot systemd 서비스 등록"

    if [ "$SKIP_NANOBOT" -eq 1 ]; then
        warn "Nanobot 서비스 등록 건너뜀 (--skip-nanobot)"
        return 0
    fi

    local service_file="/etc/systemd/system/nanobot.service"

    if [ -f "$service_file" ]; then
        warn "nanobot.service 이미 존재 — 건너뜀"
        return 0
    fi

    local nanobot_bin
    nanobot_bin=$(command -v nanobot 2>/dev/null || echo "nanobot")

    run sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Nanobot AI Agent Host
After=network.target litellm-proxy.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${nanobot_bin} serve --config ${INSTALL_DIR}/nanobot.yaml
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    run sudo systemctl daemon-reload
    run sudo systemctl enable nanobot
    success "nanobot.service 등록 완료"
    info "시작: sudo systemctl start nanobot"
}

# ── 함수: MCP 서버 사전 다운로드 ─────────────────────────────────────────────
prefetch_mcp_servers() {
    step "MCP 서버 npx 캐시 (선택)"

    local mcp_packages=(
        "@modelcontextprotocol/server-telegram"
        "@modelcontextprotocol/server-github"
        "@n8n/mcp-server"
        "@upstash/context7-mcp"
        "@modelcontextprotocol/server-brave-search"
        "@modelcontextprotocol/server-memory"
    )

    info "MCP 서버 패키지 npx 캐시 중..."
    for pkg in "${mcp_packages[@]}"; do
        run npx --yes "$pkg" --help > /dev/null 2>&1 || true
        info "  캐시: ${pkg}"
    done

    success "MCP 서버 사전 다운로드 완료"
}

# ── 함수: 설치 검증 ───────────────────────────────────────────────────────────
verify_install() {
    step "설치 검증"

    local ok=1

    check_cmd() {
        local cmd="$1" label="$2"
        if command -v "$cmd" &>/dev/null; then
            success "  ${label}: $(command -v "$cmd")"
        else
            warn "  ${label}: 미설치 또는 PATH 없음"
            ok=0
        fi
    }

    check_file() {
        local path="$1" label="$2"
        if [ -e "$path" ]; then
            success "  ${label}: ${path}"
        else
            warn "  ${label}: 없음 (${path})"
            ok=0
        fi
    }

    echo "  [명령어]"
    check_cmd python3      "Python3"
    check_cmd pip3         "pip3"
    check_cmd node         "Node.js"
    check_cmd npm          "npm"
    check_cmd git          "git"
    check_cmd jq           "jq"
    check_cmd curl         "curl"
    check_cmd cppcheck     "cppcheck"
    check_cmd uv           "uv (hwpx-mcp)"
    check_cmd litellm      "LiteLLM"
    command -v nanobot &>/dev/null && success "  Nanobot: $(command -v nanobot)" || warn "  Nanobot: 미설치"
    command -v renode  &>/dev/null && success "  Renode: $(command -v renode)"   || warn "  Renode: 미설치 (Gate 3 STM32 스킵)"
    command -v st-flash &>/dev/null && success "  st-flash: $(command -v st-flash)" || warn "  st-flash: 미설치 (Gate 4 STM32 수동 플래시 불가)"

    echo ""
    echo "  [Python 패키지]"
    for pkg in serial reportlab pypdf requests; do
        python3 -c "import ${pkg}" 2>/dev/null \
            && success "  ${pkg}" \
            || warn "  ${pkg}: 미설치"
    done

    echo ""
    echo "  [파일]"
    check_file "${INSTALL_DIR}/.env"                         ".env"
    check_file "${INSTALL_DIR}/scripts/nightly_build.sh"    "nightly_build.sh"
    check_file "${INSTALL_DIR}/scripts/guard_heartbeat.sh"  "guard_heartbeat.sh"
    check_file "${INSTALL_DIR}/gates/gate_runner.sh"        "gate_runner.sh"
    check_file "${INSTALL_DIR}/scripts/serial_capture.py"  "serial_capture.py"
    check_file "${INSTALL_DIR}/configs/litellm_config.yaml" "litellm_config.yaml"
    check_file "${INSTALL_DIR}/configs/mcp-servers.yaml"    "mcp-servers.yaml"
    check_file "${INSTALL_DIR}/agents/main.md"              "agents/main.md"

    echo ""
    if [ "$ok" -eq 1 ]; then
        success "모든 핵심 구성 요소가 정상입니다."
    else
        warn "일부 구성 요소가 누락되었습니다. 위 경고를 확인하세요."
    fi
}

# ── 함수: 다음 단계 안내 ──────────────────────────────────────────────────────
print_next_steps() {
    echo ""
    echo -e "${C_BOLD}${C_GREEN}━━━ 설치 완료 — 다음 단계 ━━━${C_RESET}"
    echo ""
    echo "  1. API 키 설정"
    echo -e "     ${C_CYAN}nano ${INSTALL_DIR}/.env${C_RESET}"
    echo ""
    echo "  2. LiteLLM Proxy 시작"
    echo -e "     ${C_CYAN}sudo systemctl start litellm-proxy${C_RESET}"
    echo -e "     ${C_CYAN}curl http://localhost:4000/health${C_RESET}  # 확인"
    echo ""
    echo "  3. Nanobot 시작"
    echo -e "     ${C_CYAN}sudo systemctl start nanobot${C_RESET}"
    echo -e "     ${C_CYAN}curl http://localhost:8080/v1/models${C_RESET}  # 확인"
    echo ""
    echo "  4. 수동 테스트"
    echo -e "     ${C_CYAN}bash ${INSTALL_DIR}/gates/gate_runner.sh ${INSTALL_DIR}/firmware esp32${C_RESET}"
    echo ""
    echo "  5. 서비스 상태 확인"
    echo -e "     ${C_CYAN}bash ${INSTALL_DIR}/scripts/pipeline_health.sh${C_RESET}"
    echo ""
}

# ── 메인 실행 순서 ────────────────────────────────────────────────────────────
check_os
install_system_deps
install_python_deps
install_node_deps
install_esp_idf
install_renode
install_uv
install_stlink
install_nanobot
setup_directories
deploy_files
setup_env
setup_nanobot_config
setup_litellm_service
setup_nanobot_service
prefetch_mcp_servers
setup_cron
verify_install
print_next_steps
