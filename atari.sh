#!/usr/bin/env bash

# 1. Directory on your Mac mapped to Atari's C: drive
ATARI_CDRIVE="$HOME/Atari/CDrive"
mkdir -p "$ATARI_CDRIVE"

# 2. Standard Homebrew EmuTOS path on Apple Silicon
EMUTOS_PATH="/opt/homebrew/share/hatari/emutos-us.img"

# 3. Launch Hatari with mapped C: drive
if [ -f "$EMUTOS_PATH" ]; then
    hatari --tos "$EMUTOS_PATH" --harddrive "$ATARI_CDRIVE" "$@"
else
    # Fallback to Hatari's auto-detected EmuTOS if the exact path isn't found
    hatari --harddrive "$ATARI_CDRIVE" "$@"
fi
EOF
