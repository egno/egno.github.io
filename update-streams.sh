#!/bin/bash

# Script to fetch and merge IPTV streams from community sources
# Improved with robust timeout and error handling

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M3U_FILE="${SCRIPT_DIR}/kino.m3u"
TEMP_DIR="/tmp/iptv-update-$$"
MERGED_FILE="${TEMP_DIR}/merged.m3u"
HEADER="#EXTM3U url-tvg=\"http://epg.it999.ru/edem.xml.gz\""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Progress function
progress() {
    local current=$1
    local total=$2
    local prefix=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 5))
    local empty=$((20 - filled))

    printf "\r${prefix} [${GREEN}"
    printf "%${filled}s" | tr ' ' '='
    printf "${NC}"
    printf "%${empty}s" | tr ' ' '-'
    printf "] ${YELLOW}%3d%%${NC}" $percent
}

mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${BLUE}🔍 Fetching community IPTV sources...${NC}"
echo ""

# Fetch from main IPTV repository with timeout
echo -e "${BLUE}📥 Downloading Russian channels list (timeout: 15s)...${NC}"

if curl -m 15 -L --connect-timeout 5 "https://raw.githubusercontent.com/iptv-org/iptv/master/channels/ru.m3u" -o "${TEMP_DIR}/ru.m3u" 2>/dev/null; then
    if [ -s "${TEMP_DIR}/ru.m3u" ]; then
        echo -e "\r${GREEN}✓${NC} Downloaded successfully ($(wc -l < "${TEMP_DIR}/ru.m3u") lines)             "
    else
        echo -e "\r${YELLOW}⚠️  Downloaded but file is empty${NC}                    "
        echo "" > "${TEMP_DIR}/ru.m3u"
    fi
else
    echo -e "\r${YELLOW}⚠️  Download timed out or failed${NC}                    "
    echo "" > "${TEMP_DIR}/ru.m3u"
fi

echo ""

# Initialize merged file with header
echo "$HEADER" > "$MERGED_FILE"
echo "" >> "$MERGED_FILE"

# Add existing streams from current file (skip header)
echo -e "${BLUE}📦 Keeping existing verified streams...${NC}"
EXISTING=$(grep -c "^https\?://" "$M3U_FILE" 2>/dev/null || echo 0)
tail -n +3 "$M3U_FILE" >> "$MERGED_FILE" 2>/dev/null || true
echo -e "${GREEN}✓${NC} Added $EXISTING existing streams"
echo ""

# Function to extract cinema-related keywords
is_cinema_related() {
    local line="$1"
    echo "$line" | grep -iE "(кино|cinema|film|фильм|советск|russian cinema|классик|ностальги|домашний)" > /dev/null 2>&1
}

# Extract and add cinema channels from fetched sources
if [ -s "${TEMP_DIR}/ru.m3u" ]; then
    echo -e "${BLUE}🎬 Extracting Russian cinema channels...${NC}"

    cinema_count=0
    total_lines=$(wc -l < "${TEMP_DIR}/ru.m3u")
    line_num=0

    while IFS= read -r line; do
        ((line_num++))

        # Show progress every 100 lines
        if [ $((line_num % 100)) -eq 0 ]; then
            progress $line_num $total_lines "${BLUE}   Scanning${NC}"
        fi

        if [[ "$line" =~ ^#EXTINF ]]; then
            if is_cinema_related "$line"; then
                echo "$line" >> "$MERGED_FILE"
                ((cinema_count++))
                # Read next line (should be the URL)
                if IFS= read -r url_line; then
                    if [[ "$url_line" =~ ^https?:// ]]; then
                        echo "$url_line" >> "$MERGED_FILE"
                        echo "" >> "$MERGED_FILE"
                    fi
                fi
            fi
        fi
    done < "${TEMP_DIR}/ru.m3u"

    echo -e "\r${GREEN}✓${NC} Found $cinema_count cinema channels                    "
else
    echo -e "${YELLOW}⚠️  No source file available${NC}"
    cinema_count=0
fi
echo ""

# Remove duplicates
echo -e "${BLUE}🧹 Removing duplicates...${NC}"
export MERGED_FILE_PATH="$MERGED_FILE"
python3 << 'PYTHON'
import sys
import os

def clean_m3u(input_file, output_file):
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()

    seen_urls = set()
    cleaned = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        if line.startswith('#EXTM3U'):
            cleaned.append(line)
            i += 1
        elif line.startswith('#EXTINF'):
            if i + 1 < n and lines[i + 1].strip().startswith(('http://', 'https://')):
                url = lines[i + 1].strip()
                if url not in seen_urls:
                    seen_urls.add(url)
                    cleaned.append(line)
                    cleaned.append(lines[i + 1])
                    cleaned.append('\n')
                i += 2
                if i < n and lines[i].strip() == '':
                    i += 1
            else:
                i += 1
        else:
            if line.strip():
                cleaned.append(line)
            i += 1

    with open(output_file, 'w', encoding='utf-8') as f:
        f.writelines(cleaned)

try:
    input_path = os.environ['MERGED_FILE_PATH']
    clean_m3u(input_path, input_path + '.clean')
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON

if [ -f "${TEMP_DIR}/merged.m3u.clean" ]; then
    mv "${TEMP_DIR}/merged.m3u.clean" "$MERGED_FILE"
fi

echo -e "${GREEN}✓${NC} Deduplication complete"
echo ""

# Count final streams
STREAM_COUNT=$(grep -c "^https\?://" "$MERGED_FILE" || echo 0)
NEW_COUNT=$((STREAM_COUNT - EXISTING))

echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "  Total streams: ${GREEN}$STREAM_COUNT${NC}"
echo -e "  Existing: ${BLUE}$EXISTING${NC}  |  New: ${YELLOW}$NEW_COUNT${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "Choose action:"
echo -e "  ${GREEN}1)${NC} Preview new file"
echo -e "  ${GREEN}2)${NC} Test all links (slow!)"
echo -e "  ${GREEN}3)${NC} Replace kino.m3u"
echo -e "  ${GREEN}4)${NC} Cancel"
echo ""
read -p "Choice [1-4]: " choice

case $choice in
    1)
        echo ""
        echo -e "${BLUE}Preview (first 40 entries):${NC}"
        head -n 40 "$MERGED_FILE"
        ;;
    2)
        echo ""
        echo -e "${BLUE}Testing links (max 3s each)...${NC}"
        working=0
        broken=0
        total=$(grep -c "^https\?://" "$MERGED_FILE" || echo 0)
        tested=0

        while IFS= read -r url; do
            if [[ "$url" =~ ^https?:// ]]; then
                ((tested++))
                progress $tested $total "  Testing"

                if curl -s -m 3 -I "$url" > /dev/null 2>&1; then
                    ((working++))
                else
                    ((broken++))
                fi
            fi
        done < <(grep "^https\?://" "$MERGED_FILE")

        echo ""
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        echo -e "  ${GREEN}✓ Working${NC}: $working  |  ${RED}✗ Broken${NC}: $broken"
        if [ $total -gt 0 ]; then
            echo -e "  Success rate: $((working * 100 / total))%"
        fi
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        ;;
    3)
        cp "$MERGED_FILE" "$M3U_FILE"
        echo -e "${GREEN}✅ kino.m3u updated!${NC}"
        echo ""
        echo -e "Next: ${YELLOW}git add kino.m3u && git commit -m 'Update: add X new streams'${NC}"
        ;;
    4)
        echo "Cancelled"
        exit 0
        ;;
esac
