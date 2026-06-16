#!/bin/zsh
cd "$(dirname "$0")"

APP="./SnapFrame"
SRC="./SnapFrame.swift"
CACHE="./.snapframe-build-cache"
mkdir -p "$CACHE"
export CLANG_MODULE_CACHE_PATH="$PWD/$CACHE"
export MODULE_CACHE_DIR="$PWD/$CACHE"

if [ ! -x "$APP" ] || [ "$SRC" -nt "$APP" ]; then
  /usr/bin/swiftc "$SRC" -o "$APP" -framework AppKit -framework ScreenCaptureKit
fi

"$APP"
