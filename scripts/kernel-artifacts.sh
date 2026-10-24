#!/usr/bin/env bash
# 重新导出 CachyOS 内核产物到 dist/，并打成一个 tar.xz 方便分发。
# 用法：./scripts/kernel-artifacts.sh [输出目录]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
mkdir -p "$OUT"

nix build --no-link --print-out-paths .#cachyos-kernel-artifacts > /tmp/kart.path
P=$(cat /tmp/kart.path)
VER=$(cat "$P/MODULE_VERSION")
DEST="$OUT/linux-cachyos-bore-${VER}"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -L "$P"/bzImage "$P"/System.map "$P"/config-* "$P"/MODULE_VERSION "$DEST"/

# 模块目录：从当前系统里取（必须是同一版本，否则 insmod 会失败）
MODDIR="/run/current-system/kernel-modules/lib/modules/${VER}"
if [ -d "$MODDIR" ]; then
  tar -C "$(dirname "$MODDIR")" -cf - "$VER" | xz -T0 -1 > "$DEST/modules-${VER}.tar.xz"
  echo "模块已打包：$DEST/modules-${VER}.tar.xz"
else
  echo "跳过模块打包：$MODDIR 不存在（当前系统不是这个内核版本）" >&2
fi

tar -C "$OUT" -cf - "$(basename "$DEST")" | xz -T0 -1 > "$OUT/linux-cachyos-bore-${VER}.tar.xz"
echo "完成：$OUT/linux-cachyos-bore-${VER}.tar.xz"
ls -lh "$DEST"
