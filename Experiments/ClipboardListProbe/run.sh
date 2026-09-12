#!/bin/sh
# ClipboardListProbe 构建 / 运行脚本
#
#   ./run.sh                     编译并开窗口
#   PROBE_SELFTEST=1 ./run.sh    无窗口自检（只验数据层与不变量），失败退出码 1
#
# 单文件、独立编译、不参与 NotchCenter 的 Tuist 构建，也不需要 assemble_app。
# 只依赖系统 SDK，产物落在本目录 .build/。

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

exec "./$OUT"
