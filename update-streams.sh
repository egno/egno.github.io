#!/bin/bash

# Script to fetch and merge IPTV streams from community sources
# Filters for Russian/Soviet cinema and validates links

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M3U_FILE="${SCRIPT_DIR}/kino.m3u"
TEMP_DIR="/tmp/iptv-update-$$"
MERGED_FILE="${TEMP_DIR}/merged.m3u"
HEADER="#EXTM3U url-tvg=\"http://epg.it999.ru/edem.xml.gz\""

mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

echo "🔍 Fetching community IPTV sources..."
echo ""

# Fetch from main IPTV repository
echo "📥 Downloading from iptv-org/iptv (Russian channels)..."
curl -s -L "https://raw.githubusercontent.com/iptv-org/iptv/master/channels/ru.m3u" -o "${TEMP_DIR}/ru.m3u" || echo "⚠️  Failed to fetch ru.m3u"

# Initialize merged file with header
echo "$HEADER" > "$MERGED_FILE"
echo "" >> "$MERGED_FILE"

# Add existing streams from current file (skip header)
echo "📦 Keeping existing verified streams..."
tail -n +3 "$M3U_FILE" >> "$MERGED_FILE" 2>/dev/null || true

# Function to extract cinema-related keywords
is_cinema_related() {
    local line="$1"
    echo "$line" | grep -iE "(кино|cinema|film|фильм|кинема|советск|russian cinema|классик|ностальги|домашний)" > /dev/null 2>&1
}

# Extract and add cinema channels from fetched sources
echo "🎬 Extracting Russian cinema channels..."
if [ -f "${TEMP_DIR}/ru.m3u" ]; then
    local_file="${TEMP_DIR}/ru.m3u"

    # Extract relevant entries (EXTINF lines followed by URLs)
    while IFS= read -r line; do
        if [[ "$line" =~ ^#EXTINF ]]; then
            current_extinf="$line"
            if is_cinema_related "$line"; then
                echo "$current_extinf" >> "$MERGED_FILE"
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
fi

# Remove duplicates (keep first occurrence)
echo "🧹 Removing duplicates..."
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

echo ""
echo "✅ Total streams in merged file: $STREAM_COUNT"
echo ""
echo "Would you like to:"
echo "  1) Preview the new file"
echo "  2) Test all links"
echo "  3) Replace current kino.m3u"
echo "  4) Cancel"
echo ""
read -p "Choose [1-4]: " choice

case $choice in
    1)
        echo ""
        echo "Preview (first 50 lines):"
        head -50 "$MERGED_FILE"
        ;;
    2)
        echo ""
        echo "Testing links (this may take a while)..."
        working=0
        broken=0
        while IFS= read -r url; do
            if [[ "$url" =~ ^https?:// ]]; then
                if curl -s -m 3 -I "$url" > /dev/null 2>&1; then
                    ((working++))
                else
                    ((broken++))
                fi
            fi
        done < <(grep "^https\?://" "$MERGED_FILE")
        echo "Results: $working working, $broken broken"
        ;;
    3)
        cp "$MERGED_FILE" "$M3U_FILE"
        echo "✅ kino.m3u updated!"
        echo ""
        echo "Run: git add kino.m3u && git commit -m 'Update streams from community IPTV sources'"
        ;;
    4)
        echo "Cancelled"
        exit 0
        ;;
esac
