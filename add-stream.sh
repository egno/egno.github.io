#!/bin/bash

# Manual stream addition with validation
# Usage: ./add-stream.sh "Channel Name" "http://stream.url/playlist.m3u8"

if [ $# -lt 2 ]; then
    echo "Usage: $0 \"Channel Name\" \"http://url.to.stream\""
    echo ""
    echo "Example: $0 \"Кино Канал\" \"http://example.com/stream.m3u8\""
    exit 1
fi

CHANNEL_NAME="$1"
STREAM_URL="$2"
M3U_FILE="$(dirname "$0")/kino.m3u"

echo "Validating stream..."
HTTP_CODE=$(curl -s -m 5 -I -L "$STREAM_URL" 2>/dev/null | head -1 | grep -o "[0-9]\{3\}" | head -1)

if [ -z "$HTTP_CODE" ]; then
    echo "❌ Stream not accessible (timeout or no response)"
    exit 1
fi

if [ "$HTTP_CODE" == "200" ]; then
    echo "✅ Stream working (HTTP $HTTP_CODE)"

    # Add to M3U
    echo "" >> "$M3U_FILE"
    echo "#EXTINF:-1,${CHANNEL_NAME}" >> "$M3U_FILE"
    echo "$STREAM_URL" >> "$M3U_FILE"

    echo ""
    echo "✅ Added to kino.m3u"
    echo ""
    echo "Run: git add kino.m3u && git commit -m 'Add $CHANNEL_NAME'"
else
    echo "⚠️  Stream returned HTTP $HTTP_CODE (may still work)"
    read -p "Add anyway? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        echo "" >> "$M3U_FILE"
        echo "#EXTINF:-1,${CHANNEL_NAME}" >> "$M3U_FILE"
        echo "$STREAM_URL" >> "$M3U_FILE"
        echo "✅ Added"
    fi
fi
