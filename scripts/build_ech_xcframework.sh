#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ECH_DIR="$ROOT/Vendor/NoveliaECH/ech"
OUT="$ROOT/Vendor/NoveliaECH/NoveliaECH.xcframework"

export PATH="/opt/homebrew/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"

if ! command -v go >/dev/null 2>&1; then
    echo "error: go toolchain not found (install Go 1.27+ first)" >&2
    exit 1
fi

echo "==> Running Go unit tests in $ECH_DIR"
(
    cd "$ECH_DIR"
    go test ./...
    go test github.com/inqadh/jissr-bypass
)

echo "==> Building NoveliaECH.xcframework (iOS 15.0+ device & simulator)"
rm -rf "$OUT"
(
    # 在无开发者主目录路径的临时工作区中构建，配合 -trimpath 避免将本机路径写入二进制。
    WORK_DIR="$(mktemp -d "/tmp/novelia-ech-build.XXXXXX")"
    trap 'rm -rf "$WORK_DIR"' EXIT
    TOOL_BIN="$WORK_DIR/bin"
    SRC_COPY="$WORK_DIR/ech"
    mkdir -p "$TOOL_BIN"
    cp -R "$ECH_DIR" "$SRC_COPY"
    cd "$SRC_COPY"
    go build -o "$TOOL_BIN/gobind" golang.org/x/mobile/cmd/gobind
    go build -o "$TOOL_BIN/gomobile" golang.org/x/mobile/cmd/gomobile
    export PATH="$TOOL_BIN:$PATH"
    export GOFLAGS="-trimpath"
    export CGO_CFLAGS="-ffile-prefix-map=$WORK_DIR=."
    gomobile bind \
        -trimpath \
        -target=ios,iossimulator \
        -iosversion=15.0 \
        -ldflags="-s -w" \
        -o "$OUT" \
        .
)

echo "==> Built $OUT"
du -sh "$OUT"
