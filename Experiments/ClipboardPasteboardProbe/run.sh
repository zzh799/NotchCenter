#!/bin/sh
# ClipboardPasteboardProbe 构建 / 运行脚本
#
#   ./run.sh watch [秒]             只观察，自己去别的 App 复制
#   ./run.sh copy <图片路径> [秒]    先把该图片写进剪贴板（fileURL + PNG 数据），再观察
#
# 单文件、独立编译、不参与 NotchCenter 的 Tuist 构建，只依赖系统 SDK，
# 产物落在本目录 .build/。

set -e
cd "$(dirname "$0")"

ARCH="$(uname -m)"
OUT=".build/probe"

mkdir -p .build

xcrun swiftc \
  -swift-version 5 \
  -target "${ARCH}-apple-macos14.0" \
  -O \
  -o "$OUT" \
  main.swift

exec "./$OUT" "$@"
