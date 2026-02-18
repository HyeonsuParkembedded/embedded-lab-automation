#!/bin/bash
# =============================================================================
# arxiv_fetch.sh
# Embedded Lab - 매일 07:50 arXiv 논문 크롤링
#
# 역할:
#   1. arXiv API로 임베디드/위성 관련 최신 논문 검색
#   2. /tmp/arxiv_latest.json 저장 (morning_briefing.sh가 읽음)
#
# cron: 50 7 * * * /embedded-lab/scripts/arxiv_fetch.sh
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
ARXIV_CACHE="${ARXIV_CACHE:-/tmp/arxiv_latest.json}"
ARXIV_LOG="/tmp/arxiv_fetch.log"
MAX_RESULTS="${ARXIV_MAX_RESULTS:-10}"

# 검색 키워드 (현수님 관심 분야: 임베디드, 위성, RTOS, AUTOSAR, cFS)
SEARCH_QUERIES=(
    "embedded+systems+RTOS"
    "satellite+onboard+software+cFS"
    "AUTOSAR+automotive+embedded"
    "Zephyr+RTOS+firmware"
    "CubeSat+flight+software"
)

# ── 함수: arXiv API 쿼리 ──────────────────────────────────────────────────────
fetch_arxiv() {
    local query="$1"
    local max_results="$2"

    curl -s --max-time 30 \
        "https://export.arxiv.org/api/query?search_query=all:${query}&sortBy=submittedDate&sortOrder=descending&max_results=${max_results}" \
        || echo ""
}

# ── 함수: XML 파싱 → JSON 변환 ────────────────────────────────────────────────
parse_arxiv_xml() {
    local xml="$1"

    if [ -z "$xml" ]; then
        echo "[]"
        return
    fi

    # Python으로 XML → JSON 파싱 (bash에서 XML 파싱은 한계가 있음)
    python3 - <<EOF
import sys
import json
import xml.etree.ElementTree as ET

xml_data = """${xml}"""

try:
    root = ET.fromstring(xml_data)
    ns = {'atom': 'http://www.w3.org/2005/Atom'}
    papers = []

    for entry in root.findall('atom:entry', ns):
        title_el   = entry.find('atom:title', ns)
        summary_el = entry.find('atom:summary', ns)
        id_el      = entry.find('atom:id', ns)
        published_el = entry.find('atom:published', ns)
        authors = [a.find('atom:name', ns).text
                   for a in entry.findall('atom:author', ns)
                   if a.find('atom:name', ns) is not None]

        papers.append({
            'title':     title_el.text.strip()     if title_el     else '',
            'abstract':  summary_el.text.strip()   if summary_el   else '',
            'url':       id_el.text.strip()         if id_el        else '',
            'published': published_el.text[:10]     if published_el else '',
            'authors':   authors[:3],
        })

    print(json.dumps(papers, ensure_ascii=False, indent=2))
except Exception as e:
    print('[]', file=sys.stderr)
    print(f'파싱 오류: {e}', file=sys.stderr)
    print('[]')
EOF
}

# ── 메인: 각 키워드로 크롤링 후 병합 ─────────────────────────────────────────
echo "[$(date '+%H:%M:%S')] arXiv 크롤링 시작..." | tee -a "$ARXIV_LOG"

ALL_PAPERS="[]"

for QUERY in "${SEARCH_QUERIES[@]}"; do
    echo "[$(date '+%H:%M:%S')] 검색: ${QUERY}" | tee -a "$ARXIV_LOG"

    XML=$(fetch_arxiv "$QUERY" 3)   # 키워드당 최대 3편
    PARSED=$(parse_arxiv_xml "$XML")

    # jq로 배열 병합 (중복 URL 제거)
    ALL_PAPERS=$(echo "${ALL_PAPERS} ${PARSED}" | \
        python3 -c "
import sys, json
data = sys.stdin.read().split(']')[:-1]
merged = []
seen = set()
for chunk in data:
    chunk = chunk.lstrip().lstrip('[')
    if not chunk.strip():
        continue
    try:
        items = json.loads('[' + chunk + ']')
        for item in items:
            if item.get('url') not in seen:
                seen.add(item.get('url'))
                merged.append(item)
    except:
        pass
print(json.dumps(merged[:${MAX_RESULTS}], ensure_ascii=False, indent=2))
")

    sleep 3   # arXiv API 속도 제한 준수
done

# ── 결과 저장 ─────────────────────────────────────────────────────────────────
echo "$ALL_PAPERS" > "$ARXIV_CACHE"

PAPER_COUNT=$(echo "$ALL_PAPERS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "[$(date '+%H:%M:%S')] 완료 — ${PAPER_COUNT}편 저장: ${ARXIV_CACHE}" | tee -a "$ARXIV_LOG"

exit 0
