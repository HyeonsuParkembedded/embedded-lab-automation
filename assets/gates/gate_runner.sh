#!/bin/bash
# =============================================================================
# gate_runner.sh
# Embedded Lab — 4단계 완성도 Gate 순차 실행기
#
# 사용법:
#   bash gate_runner.sh <PROJECT_PATH> <BOARD_TYPE>
#   예) bash gate_runner.sh /home/ubuntu/embedded-lab/firmware esp32
#       bash gate_runner.sh /home/ubuntu/embedded-lab/firmware stm32
#
# Gate 구조:
#   Gate 1 — Compile        : 빌드 성공 여부
#   Gate 2 — Static Analysis: cppcheck + MISRA-C 2023 위반
#   Gate 3 — Simulation     : Renode(STM32) / QEMU(ESP32) vHIL
#   Gate 4 — Integration    : 실제 보드 플래시 + 시리얼 부팅 확인
#
# 종료 코드:
#   0   — 전체 Gate 통과
#   1~4 — 해당 번호 Gate 실패
#   99  — 인수 오류
# =============================================================================

set -uo pipefail

# ── 인수 확인 ─────────────────────────────────────────────────────────────────
if [ $# -lt 2 ]; then
    echo "[ERROR] 사용법: $0 <PROJECT_PATH> <BOARD_TYPE>" >&2
    exit 99
fi

PROJECT_PATH="$1"
BOARD_TYPE="$2"   # "esp32" | "stm32"

if [ ! -d "$PROJECT_PATH" ]; then
    echo "[ERROR] 프로젝트 경로 없음: $PROJECT_PATH" >&2
    exit 99
fi

# ── 환경 변수 로드 ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/[[:space:]]*#.*//')
    set +a
fi

# ── 설정값 ────────────────────────────────────────────────────────────────────
IDF_PATH="${IDF_PATH:-/opt/esp-idf}"
RENODE_PATH="${RENODE_PATH:-/usr/bin/renode}"
SERIAL_PORT="${SERIAL_PORT:-/dev/ttyUSB0}"
BAUD_RATE="${BAUD_RATE:-115200}"
BUILD_STATUS_FILE="${BUILD_STATUS_FILE:-/tmp/build_status.json}"
SIM_SCRIPT_DIR="${SCRIPT_DIR}/../sim"
GATE3_TIMEOUT="${GATE3_TIMEOUT:-30}"    # 시뮬레이션 최대 실행 시간(초)
GATE4_TIMEOUT="${GATE4_TIMEOUT:-60}"    # 보드 부팅 대기 최대 시간(초)
GATE4_EXPECT="${GATE4_EXPECT:-SYSTEM READY}"  # Gate 4 성공 키워드
GATE4_SKIP="${GATE4_SKIP:-0}"           # 1 이면 Gate 4 스킵 (CI 환경용)

LOG_FILE="${LOG_FILE:-/tmp/gate_runner_$(date +%Y%m%d_%H%M%S).log}"

# ── Gate 실패 패턴 (시뮬레이션 / 시리얼 공통) ─────────────────────────────────
FAIL_PATTERNS=(
    "HardFault"
    "BusFault"
    "MemManage"
    "UsageFault"
    "STACK OVERFLOW"
    "vApplicationStackOverflowHook"
    "Guru Meditation"
    "abort() was called"
    "assert failed"
    "*** Error in"
    "SIGSEGV"
    "WDT reset"
)

# ── 함수: 타임스탬프 ──────────────────────────────────────────────────────────
ts() { date '+%H:%M:%S'; }

# ── 함수: 로그 출력 ───────────────────────────────────────────────────────────
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

# ── 함수: 상태 JSON 기록 ──────────────────────────────────────────────────────
write_status() {
    local state="$1"   # completed | failed
    local gate="$2"    # 0 | 1 | 2 | 3 | 4
    local reason="$3"
    jq -n \
        --arg state   "$state" \
        --argjson gate "$gate" \
        --arg reason  "$reason" \
        --arg ts      "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{state: $state, gate: $gate, reason: $reason, timestamp: $ts}' \
        > "$BUILD_STATUS_FILE"
}

# ── 함수: 로그에서 실패 패턴 탐색 ────────────────────────────────────────────
check_fail_patterns() {
    local logfile="$1"
    for pat in "${FAIL_PATTERNS[@]}"; do
        if grep -q "$pat" "$logfile" 2>/dev/null; then
            echo "$pat"
            return 0
        fi
    done
    return 1
}

# =============================================================================
# Gate 1 — Compile
# =============================================================================
run_gate1() {
    log "━━━━━ Gate 1: Compile (${BOARD_TYPE}) ━━━━━"
    local build_log="/tmp/gate1_build_$(date +%Y%m%d_%H%M%S).log"

    case "$BOARD_TYPE" in
        esp32|esp32s3|esp32c3|esp32h2)
            if [ ! -f "${IDF_PATH}/export.sh" ]; then
                log "[ERROR] IDF_PATH 가 잘못되었습니다: ${IDF_PATH}"
                write_status "failed" 1 "ESP-IDF not found at ${IDF_PATH}"
                return 1
            fi
            # ESP-IDF 환경 활성화 후 빌드
            (
                source "${IDF_PATH}/export.sh" > /dev/null 2>&1
                idf.py -C "$PROJECT_PATH" build 2>&1 | tee -a "$build_log"
            )
            local exit_code=${PIPESTATUS[0]}
            ;;
        stm32|stm32h7|stm32f4|stm32l4)
            if command -v cmake &>/dev/null && [ -f "${PROJECT_PATH}/CMakeLists.txt" ]; then
                cmake --build "${PROJECT_PATH}/build" --parallel "$(nproc)" \
                    2>&1 | tee -a "$build_log"
                local exit_code=${PIPESTATUS[0]}
            elif [ -f "${PROJECT_PATH}/Makefile" ]; then
                make -C "$PROJECT_PATH" -j"$(nproc)" \
                    2>&1 | tee -a "$build_log"
                local exit_code=${PIPESTATUS[0]}
            else
                log "[ERROR] STM32 빌드 파일(CMakeLists.txt / Makefile) 없음"
                write_status "failed" 1 "No CMakeLists.txt or Makefile found"
                return 1
            fi
            ;;
        *)
            log "[ERROR] 지원하지 않는 BOARD_TYPE: ${BOARD_TYPE}"
            write_status "failed" 1 "Unsupported BOARD_TYPE: ${BOARD_TYPE}"
            return 1
            ;;
    esac

    if [ "${exit_code:-1}" -ne 0 ]; then
        local reason
        reason=$(grep -E "error:|Error:|undefined reference" "$build_log" | tail -5 | head -3 || echo "빌드 실패")
        log "[FAIL] Gate 1 실패 — 컴파일 에러"
        write_status "failed" 1 "$reason"
        return 1
    fi

    log "[PASS] Gate 1 통과 — 빌드 성공"
    write_status "completed" 1 "Compile OK"
    return 0
}

# =============================================================================
# Gate 2 — Static Analysis (cppcheck + MISRA-C 2023)
# =============================================================================
run_gate2() {
    log "━━━━━ Gate 2: Static Analysis (cppcheck + MISRA) ━━━━━"

    if ! command -v cppcheck &>/dev/null; then
        log "[WARN] cppcheck 미설치 — Gate 2 스킵"
        write_status "completed" 2 "cppcheck not installed — skipped"
        return 0
    fi

    local cppcheck_xml="/tmp/gate2_cppcheck_$(date +%Y%m%d_%H%M%S).xml"
    local src_dir="${PROJECT_PATH}/src"
    [ ! -d "$src_dir" ] && src_dir="$PROJECT_PATH"

    # cppcheck 설정 파일 우선 사용
    local cppcheck_opts=(
        "--enable=all"
        "--error-exitcode=1"
        "--suppress=missingIncludeSystem"
        "--suppress=unmatchedSuppression"
        "--xml"
        "--output-file=${cppcheck_xml}"
    )

    # MISRA 애드온이 있으면 활성화
    if python3 -c "import cppcheckdata" &>/dev/null 2>&1; then
        cppcheck_opts+=("--addon=misra.py")
    else
        log "[WARN] misra.py 애드온 없음 — MISRA 규칙 검사 제외"
    fi

    # 프로젝트 설정 파일 있으면 사용
    if [ -f "${PROJECT_PATH}/.cppcheck" ]; then
        cppcheck_opts+=("--project=${PROJECT_PATH}/.cppcheck")
    else
        cppcheck_opts+=("$src_dir")
    fi

    cppcheck "${cppcheck_opts[@]}" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        # 에러 건수 추출
        local error_count
        error_count=$(grep -c 'severity="error"' "$cppcheck_xml" 2>/dev/null || echo "?")
        log "[FAIL] Gate 2 실패 — cppcheck 에러 ${error_count}건"
        write_status "failed" 2 "cppcheck errors: ${error_count} — see ${cppcheck_xml}"
        return 1
    fi

    log "[PASS] Gate 2 통과 — 정적 분석 클리어"
    write_status "completed" 2 "Static analysis OK"
    return 0
}

# =============================================================================
# Gate 3 — Simulation (Renode / QEMU vHIL)
# =============================================================================
run_gate3() {
    log "━━━━━ Gate 3: Simulation (${BOARD_TYPE}) ━━━━━"
    local sim_log="/tmp/gate3_sim_$(date +%Y%m%d_%H%M%S).log"

    case "$BOARD_TYPE" in
        # ── ESP32 계열 → QEMU ────────────────────────────────────────────────
        esp32|esp32s3|esp32c3|esp32h2)
            if ! command -v qemu-system-xtensa &>/dev/null; then
                log "[WARN] qemu-system-xtensa 미설치 — Gate 3 스킵"
                write_status "completed" 3 "QEMU not installed — skipped"
                return 0
            fi

            local firmware_bin
            firmware_bin=$(find "${PROJECT_PATH}/build" -name "*.bin" -not -name "bootloader*" | head -1)
            if [ -z "$firmware_bin" ]; then
                log "[FAIL] Gate 3 — 펌웨어 .bin 파일 없음"
                write_status "failed" 3 "Firmware .bin not found in ${PROJECT_PATH}/build"
                return 1
            fi

            log "  시뮬레이션 파일: ${firmware_bin}"
            timeout "$GATE3_TIMEOUT" qemu-system-xtensa \
                -nographic \
                -machine esp32 \
                -drive "file=${firmware_bin},if=mtd,format=raw" \
                -serial mon:stdio \
                2>&1 | tee "$sim_log" || true
            ;;

        # ── STM32 계열 → Renode ──────────────────────────────────────────────
        stm32|stm32h7|stm32f4|stm32l4)
            if [ ! -x "$RENODE_PATH" ]; then
                log "[WARN] Renode 미설치 (${RENODE_PATH}) — Gate 3 스킵"
                write_status "completed" 3 "Renode not found — skipped"
                return 0
            fi

            local firmware_elf
            firmware_elf=$(find "${PROJECT_PATH}/build" -name "*.elf" | head -1)
            if [ -z "$firmware_elf" ]; then
                log "[FAIL] Gate 3 — 펌웨어 .elf 파일 없음"
                write_status "failed" 3 "Firmware .elf not found in ${PROJECT_PATH}/build"
                return 1
            fi

            # Renode 스크립트 (프로젝트별 커스텀 또는 기본값 사용)
            local resc_file="${SIM_SCRIPT_DIR}/${BOARD_TYPE}_test.resc"
            if [ ! -f "$resc_file" ]; then
                # 기본 인라인 스크립트 생성
                resc_file="/tmp/gate3_default.resc"
                cat > "$resc_file" <<RESC
\$bin=@${firmware_elf}
mach create
machine LoadPlatformDescription @platforms/boards/${BOARD_TYPE/stm32/stm32f4}_discovery.repl
sysbus LoadELF \$bin
machine RunFor "00:00:${GATE3_TIMEOUT}"
quit
RESC
                log "  [INFO] 기본 Renode 스크립트 사용: ${resc_file}"
            fi

            log "  시뮬레이션 파일: ${firmware_elf}"
            timeout "$((GATE3_TIMEOUT + 10))" \
                "$RENODE_PATH" --disable-xwt --console --script "$resc_file" \
                2>&1 | tee "$sim_log" || true
            ;;
    esac

    # 실패 패턴 탐색
    local found_pattern
    if found_pattern=$(check_fail_patterns "$sim_log"); then
        log "[FAIL] Gate 3 실패 — 런타임 에러 탐지: ${found_pattern}"
        # 해당 로그 라인 발췌
        local log_line
        log_line=$(grep "$found_pattern" "$sim_log" | head -1)
        write_status "failed" 3 "${found_pattern}: ${log_line}"
        return 1
    fi

    log "[PASS] Gate 3 통과 — 시뮬레이션 이상 없음"
    write_status "completed" 3 "Simulation OK — no fault patterns detected"
    return 0
}

# =============================================================================
# Gate 4 — Integration (실제 보드 플래시 + 부팅 확인)
# =============================================================================
run_gate4() {
    log "━━━━━ Gate 4: Integration (${BOARD_TYPE}) ━━━━━"

    # CI 환경에서는 Gate 4 스킵 가능
    if [ "${GATE4_SKIP}" = "1" ]; then
        log "[SKIP] GATE4_SKIP=1 — Gate 4 건너뜀 (CI 환경)"
        write_status "completed" 4 "Integration skipped (CI mode)"
        return 0
    fi

    # 시리얼 포트 존재 확인
    if [ ! -e "$SERIAL_PORT" ]; then
        log "[WARN] 시리얼 포트 없음 (${SERIAL_PORT}) — Gate 4 스킵"
        write_status "completed" 4 "No serial device — skipped"
        return 0
    fi

    local flash_log="/tmp/gate4_flash_$(date +%Y%m%d_%H%M%S).log"
    local serial_log="/tmp/gate4_serial_$(date +%Y%m%d_%H%M%S).log"

    # ── 플래시 ────────────────────────────────────────────────────────────────
    log "  플래시 쓰기 시작 → ${SERIAL_PORT}"
    case "$BOARD_TYPE" in
        esp32|esp32s3|esp32c3|esp32h2)
            (
                source "${IDF_PATH}/export.sh" > /dev/null 2>&1
                idf.py -C "$PROJECT_PATH" flash \
                    -p "$SERIAL_PORT" -b "$BAUD_RATE" \
                    2>&1 | tee "$flash_log"
            )
            local flash_exit=${PIPESTATUS[0]}
            ;;
        stm32|stm32h7|stm32f4|stm32l4)
            local firmware_bin
            firmware_bin=$(find "${PROJECT_PATH}/build" -name "*.bin" | head -1)
            if command -v st-flash &>/dev/null; then
                st-flash write "$firmware_bin" 0x08000000 \
                    2>&1 | tee "$flash_log"
                local flash_exit=${PIPESTATUS[0]}
            elif command -v openocd &>/dev/null; then
                openocd -f "interface/stlink.cfg" \
                    -f "target/${BOARD_TYPE}.cfg" \
                    -c "program ${firmware_bin} verify reset exit 0x08000000" \
                    2>&1 | tee "$flash_log"
                local flash_exit=${PIPESTATUS[0]}
            else
                log "[WARN] st-flash / openocd 미설치 — Gate 4 스킵"
                write_status "completed" 4 "Flash tool not found — skipped"
                return 0
            fi
            ;;
    esac

    if [ "${flash_exit:-1}" -ne 0 ]; then
        log "[FAIL] Gate 4 실패 — 플래시 쓰기 오류"
        write_status "failed" 4 "Flash failed — see ${flash_log}"
        return 1
    fi
    log "  플래시 완료"

    # ── 시리얼 부팅 확인 ──────────────────────────────────────────────────────
    log "  시리얼 모니터 대기 (${GATE4_TIMEOUT}초, 기대 메시지: '${GATE4_EXPECT}')"

    local SERIAL_CAPTURE="${SCRIPT_DIR}/../scripts/serial_capture.py"
    if [ ! -f "$SERIAL_CAPTURE" ]; then
        log "[ERROR] serial_capture.py 없음: ${SERIAL_CAPTURE}"
        write_status "failed" 4 "serial_capture.py not found"
        return 1
    fi

    python3 "$SERIAL_CAPTURE" \
        --port    "$SERIAL_PORT" \
        --baud    "$BAUD_RATE" \
        --output  "$serial_log" \
        --expect  "$GATE4_EXPECT" \
        --timeout "$GATE4_TIMEOUT" \
        --timestamp \
        --no-color \
        2>&1 | tee -a "$LOG_FILE"

    local serial_exit=${PIPESTATUS[0]}

    if [ "$serial_exit" -eq 0 ]; then
        log "[PASS] Gate 4 통과 — 보드 부팅 정상 확인"
        write_status "completed" 4 "Integration OK — '${GATE4_EXPECT}' received"
        return 0
    elif [ "$serial_exit" -eq 2 ]; then
        local fail_line
        fail_line=$(grep -E "HardFault|Guru Meditation|STACK OVERFLOW|WDT reset|assert failed" "$serial_log" | head -1)
        log "[FAIL] Gate 4 실패 — 런타임 에러: ${fail_line}"
        write_status "failed" 4 "Runtime error on board: ${fail_line}"
        return 1
    elif [ "$serial_exit" -eq 3 ]; then
        log "[FAIL] Gate 4 실패 — 시리얼 포트 열기 오류 (${SERIAL_PORT})"
        write_status "failed" 4 "Serial port open failed: ${SERIAL_PORT}"
        return 1
    else
        log "[FAIL] Gate 4 실패 — 부팅 타임아웃 (${GATE4_TIMEOUT}초 내 '${GATE4_EXPECT}' 미수신)"
        write_status "failed" 4 "Boot timeout — '${GATE4_EXPECT}' not received in ${GATE4_TIMEOUT}s"
        return 1
    fi
}

# =============================================================================
# 메인 실행
# =============================================================================
log "================================================================"
log " Embedded Lab Gate Runner"
log "  PROJECT : ${PROJECT_PATH}"
log "  BOARD   : ${BOARD_TYPE}"
log "  LOG     : ${LOG_FILE}"
log "================================================================"

# Gate 순차 실행 — 실패 시 즉시 해당 Gate 번호로 종료
run_gate1 || exit 1
run_gate2 || exit 2
run_gate3 || exit 3
run_gate4 || exit 4

log "================================================================"
log " 전체 Gate 통과 — 빌드 성공!"
log "================================================================"
write_status "completed" 4 "All gates passed"
exit 0
