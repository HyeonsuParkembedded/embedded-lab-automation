#!/usr/bin/env python3
"""
serial_capture.py
Embedded Lab — 시리얼 포트 캡처 및 부팅 확인 도구

사용법:
    python3 serial_capture.py --port /dev/ttyUSB0 --baud 115200 \
        --output /tmp/boot.log --expect "SYSTEM READY"

종료 코드:
    0  — expect 키워드 수신 (부팅 성공)
    1  — 타임아웃 (expect 미수신)
    2  — 실패 패턴 탐지 (HardFault 등 런타임 에러)
    3  — 포트 열기 실패 (장치 없음 / 권한 없음)
    4  — 인수 오류
"""

import argparse
import sys
import time
import re
import signal
from datetime import datetime
from pathlib import Path

# pyserial 임포트 (없으면 안내 후 종료)
try:
    import serial
except ImportError:
    print("[ERROR] pyserial 미설치. 다음 명령으로 설치하세요:", file=sys.stderr)
    print("        pip install pyserial", file=sys.stderr)
    sys.exit(3)

# ── ANSI 색상 ─────────────────────────────────────────────────────────────────
class Color:
    GREEN  = "\033[92m"
    RED    = "\033[91m"
    YELLOW = "\033[93m"
    CYAN   = "\033[96m"
    RESET  = "\033[0m"

def colorize(text: str, color: str, use_color: bool) -> str:
    return f"{color}{text}{Color.RESET}" if use_color else text

# ── 기본 실패 패턴 ────────────────────────────────────────────────────────────
DEFAULT_FAIL_PATTERNS = [
    r"HardFault",
    r"BusFault",
    r"MemManage",
    r"UsageFault",
    r"STACK OVERFLOW",
    r"vApplicationStackOverflowHook",
    r"Guru Meditation Error",
    r"abort\(\) was called",
    r"assert failed",
    r"\*\*\* Error in",
    r"WDT reset",
    r"Backtrace:",                   # ESP-IDF 패닉 스택 트레이스
    r"panic_abort",
    r"rtos_int_lock",                # FreeRTOS 단언 실패
    r"configASSERT",
]

# ── 인수 파싱 ─────────────────────────────────────────────────────────────────
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="임베디드 보드 시리얼 출력 캡처 및 부팅 상태 확인",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--port", "-p",
        required=True,
        help="시리얼 포트 (예: /dev/ttyUSB0, /dev/ttyACM0)",
    )
    parser.add_argument(
        "--baud", "-b",
        type=int,
        default=115200,
        help="보드레이트 (기본값: 115200)",
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="로그 저장 파일 경로 (미지정 시 저장 안 함)",
    )
    parser.add_argument(
        "--expect", "-e",
        default="SYSTEM READY",
        help="부팅 성공 판정 키워드 (기본값: 'SYSTEM READY')",
    )
    parser.add_argument(
        "--timeout", "-t",
        type=float,
        default=60.0,
        help="최대 대기 시간(초) (기본값: 60)",
    )
    parser.add_argument(
        "--fail-pattern",
        action="append",
        dest="extra_fail_patterns",
        metavar="PATTERN",
        help="추가 실패 패턴 (정규식, 여러 번 지정 가능)",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="ANSI 색상 출력 비활성화 (CI 환경용)",
    )
    parser.add_argument(
        "--timestamp",
        action="store_true",
        help="각 줄에 타임스탬프 추가",
    )
    parser.add_argument(
        "--reset-dtr",
        action="store_true",
        help="포트 열 때 DTR 토글로 보드 리셋 (ESP32 등)",
    )
    return parser.parse_args()


# ── 메인 ─────────────────────────────────────────────────────────────────────
def main() -> int:
    args = parse_args()
    use_color = not args.no_color and sys.stdout.isatty()

    # 실패 패턴 컴파일
    fail_patterns_raw = DEFAULT_FAIL_PATTERNS + (args.extra_fail_patterns or [])
    try:
        fail_regexes = [re.compile(p) for p in fail_patterns_raw]
    except re.error as e:
        print(f"[ERROR] 잘못된 정규식 패턴: {e}", file=sys.stderr)
        return 4

    # 출력 파일 준비
    log_file = None
    if args.output:
        try:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            log_file = open(args.output, "w", encoding="utf-8", buffering=1)
        except OSError as e:
            print(f"[ERROR] 로그 파일 열기 실패: {e}", file=sys.stderr)
            return 4

    def write_line(raw: str, decorated: str) -> None:
        """stdout(장식됨) + 파일(원본) 동시 출력"""
        print(decorated)
        if log_file:
            log_file.write(raw + "\n")
            log_file.flush()

    # 헤더 출력
    header = (
        f"[serial_capture] 포트={args.port}  보드레이트={args.baud}  "
        f"타임아웃={args.timeout}s  기대메시지='{args.expect}'"
    )
    write_line(header, colorize(header, Color.CYAN, use_color))
    write_line("-" * 60, "-" * 60)

    # 시리얼 포트 열기
    try:
        ser = serial.Serial(
            port=args.port,
            baudrate=args.baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=1.0,
        )
    except serial.SerialException as e:
        msg = f"[ERROR] 시리얼 포트 열기 실패: {e}"
        print(colorize(msg, Color.RED, use_color), file=sys.stderr)
        if log_file:
            log_file.write(msg + "\n")
            log_file.close()
        return 3

    # DTR 토글로 보드 리셋 (ESP32 자동 리셋 회로 활용)
    if args.reset_dtr:
        ser.dtr = False
        time.sleep(0.1)
        ser.dtr = True
        msg = "[INFO] DTR 토글 — 보드 리셋 신호 전송"
        write_line(msg, colorize(msg, Color.YELLOW, use_color))

    # Ctrl+C 처리
    interrupted = False
    def handle_sigint(sig, frame):
        nonlocal interrupted
        interrupted = True
    signal.signal(signal.SIGINT, handle_sigint)

    # ── 캡처 루프 ─────────────────────────────────────────────────────────────
    start_time   = time.monotonic()
    result_code  = 1        # 기본: 타임아웃
    found_expect = False
    found_fail   = None
    line_count   = 0

    while not interrupted:
        elapsed = time.monotonic() - start_time
        if elapsed >= args.timeout:
            break

        try:
            raw_bytes = ser.readline()
        except serial.SerialException as e:
            msg = f"[ERROR] 시리얼 읽기 오류: {e}"
            write_line(msg, colorize(msg, Color.RED, use_color))
            result_code = 3
            break

        if not raw_bytes:
            continue

        # 디코딩 (깨진 바이트 대체)
        line = raw_bytes.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            continue

        line_count += 1

        # 타임스탬프 prefix
        ts_prefix = f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] " if args.timestamp else ""
        raw_out   = ts_prefix + line

        # 실패 패턴 검사
        matched_fail = next((r.pattern for r in fail_regexes if r.search(line)), None)
        if matched_fail:
            decorated = colorize(raw_out, Color.RED, use_color)
            write_line(raw_out, decorated)
            found_fail  = line
            result_code = 2
            break

        # 성공 키워드 검사
        if args.expect in line:
            decorated = colorize(raw_out, Color.GREEN, use_color)
            write_line(raw_out, decorated)
            found_expect = True
            result_code  = 0
            break

        # 일반 줄
        write_line(raw_out, raw_out)

    # ── 종료 처리 ─────────────────────────────────────────────────────────────
    ser.close()

    elapsed_total = time.monotonic() - start_time
    write_line("-" * 60, "-" * 60)

    if interrupted:
        msg = "[INTERRUPTED] 사용자 중단"
        write_line(msg, colorize(msg, Color.YELLOW, use_color))
        result_code = 1

    elif result_code == 0:
        msg = (
            f"[SUCCESS] '{args.expect}' 수신 — 부팅 성공 "
            f"({elapsed_total:.1f}초, {line_count}줄)"
        )
        write_line(msg, colorize(msg, Color.GREEN, use_color))

    elif result_code == 2:
        msg = f"[FAIL] 런타임 에러 탐지: {found_fail}"
        write_line(msg, colorize(msg, Color.RED, use_color))

    else:  # 타임아웃
        msg = (
            f"[TIMEOUT] {args.timeout}초 내 '{args.expect}' 미수신 "
            f"({line_count}줄 수신)"
        )
        write_line(msg, colorize(msg, Color.YELLOW, use_color))

    if log_file:
        log_file.close()

    return result_code


if __name__ == "__main__":
    sys.exit(main())
