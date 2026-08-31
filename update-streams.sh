#!/bin/bash

# Script to fetch and merge IPTV streams from community sources
# Filters for Russian/Soviet cinema and validates links

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
NC='\033[0m' # No Color

# Spinner function
spinner() {
    local pid=$1
    local delay=0.1
    local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    while kill -0 $pid 2>/dev/null; do
        for frame in "${frames[@]}"; do
            echo -ne "\r${BLUE}${frame}${NC} $2"
            sleep $delay
        done
    done
    wait $pid
}

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

# Fetch from main IPTV repository
echo -e "${BLUE}📥 Downloading from iptv-org/iptv (Russian channels)...${NC}"
curl -s -L "https://raw.githubusercontent.com/iptv-org/iptv/master/channels/ru.m3u" -o "${TEMP_DIR}/ru.m3u" 2>&1 | while read line; do
    if [[ "$line" =~ [0-9]+ ]]; then
        echo -ne "\r${BLUE}   Downloading... $line${NC}"
    fi
done
echo -e "\r${GREEN}✓${NC} Downloaded successfully                  "

if [ ! -s "${TEMP_DIR}/ru.m3u" ]; then
    echo -e "${YELLOW}⚠️  ru.m3u is empty or failed to download${NC}"
fi

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
    echo "$line" | grep -iE "(кино|cinema|film|фильм|кинема|советск|russian cinema|классик|ностальги|домашний)" > /dev/null 2>&1
}

# Extract and add cinema channels from fetched sources
echo -e "${BLUE}🎬 Extracting Russian cinema channels...${NC}"

cinema_count=0
if [ -f "${TEMP_DIR}/ru.m3u" ]; then
    local_file="${TEMP_DIR}/ru.m3u"
    total_lines=$(wc -l < "$local_file")
    line_num=0

    # Extract relevant entries (EXTINF lines followed by URLs)
    while IFS= read -r line; do
        ((line_num++))

        # Show progress every 100 lines
        if [ $((line_num % 100)) -eq 0 ]; then
            progress $line_num $total_lines "${BLUE}   Scanning${NC}"
        fi

        if [[ "$line" =~ ^#EXTINF ]]; then
            current_extinf="$line"
            if is_cinema_related "$line"; then
                echo "$current_extinf" >> "$MERGED_FILE"
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
    done < "$local_file"

    echo -e "\r${GREEN}✓${NC} Found $cinema_count cinema-related channels         "
else
    echo -e "${YELLOW}⚠️  Source file not found${NC}"
fi
echo ""

# Remove duplicates (keep first occurrence)
echo -e "${BLUE}🧹 Removing duplicates...${NC}"
python3 << PYTHON
import re

def clean_m3u(input_file, output_file):
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()

    seen_urls = set()
    cleaned = []

    i = 0
    while i < len(lines):
        if lines[i].startswith('#EXTM3U'):
            cleaned.append(lines[i])
        elif lines[i].startswith('#EXTINF'):
            # Check if next line is a URL
            if i + 1 < len(lines) and lines[i + 1].strip().startswith(('http://', 'https://')):
                url = lines[i + 1].strip()
                if url not in seen_urls:
                    seen_urls.add(url)
                    cleaned.append(lines[i])
                    cleaned.append(lines[i + 1])
                    if i + 2 < len(lines) and lines[i + 2].strip() == '':
                        cleaned.append(lines[i + 2])
                        i += 3
                    else:
                        cleaned.append('\n')
                        i += 2
                else:
                    i += 2
            else:
                i += 1
        elif lines[i].strip():
            cleaned.append(lines[i])
            i += 1
        else:
            i += 1

    with open(output_file, 'w', encoding='utf-8') as f:
        f.writelines(cleaned)

clean_m3u('$MERGED_FILE', '${TEMP_DIR}/deduped.m3u')
PYTHON

mv "${TEMP_DIR}/deduped.m3u" "$MERGED_FILE"

# Count streams
STREAM_COUNT=$(grep -c "^https\?://" "$MERGED_FILE" || echo 0)
NEW_COUNT=$((STREAM_COUNT - EXISTING))

echo -e "${GREEN}✓${NC} Deduplication complete"
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "  Total streams in merged file: ${GREEN}$STREAM_COUNT${NC}"
echo -e "  Existing streams: ${BLUE}$EXISTING${NC}"
echo -e "  New streams: ${YELLOW}$NEW_COUNT${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "Would you like to:"
echo "  ${GREEN}1)${NC} Preview the new file"
echo "  ${GREEN}2)${NC} Test all links"
echo "  ${GREEN}3)${NC} Replace current kino.m3u"
echo "  ${GREEN}4)${NC} Cancel"
echo ""
read -p "Choose [1-4]: " choice

case $choice in
    1)
        echo ""
        echo -e "${BLUE}Preview (first 50 lines):${NC}"
        head -50 "$MERGED_FILE"
        ;;
    2)
        echo ""
        echo -e "${BLUE}Testing links (this may take a while)...${NC}"
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
        echo -e "  Results: ${GREEN}$working working${NC}, ${RED}$broken broken${NC}"
        echo -e "  Success rate: $((working * 100 / total))%"
        echo -e "${GREEN}═══════════════════════════════════════${NC}"
        ;;
    3)
        cp "$MERGED_FILE" "$M3U_FILE"
        echo -e "${GREEN}✅ kino.m3u updated!${NC}"
        echo ""
        echo -e "Run: ${YELLOW}git add kino.m3u && git commit -m 'Update streams from community IPTV sources'${NC}"
        ;;
    4)
        echo "Cancelled"
        exit 0
        ;;
esac
