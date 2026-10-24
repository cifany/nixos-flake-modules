#!/usr/bin/env bash
# 把本目录推到 GitHub。用法：./scripts/push.sh [commit-message]
# 需要环境变量 GITHUB_TOKEN（或事先 git config 好凭据）。
set -euo pipefail

cd "$(dirname "$0")/.."
MSG="${1:-update}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "缺 GITHUB_TOKEN：export GITHUB_TOKEN=ghp_xxx 再跑" >&2
  exit 1
fi

REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/cifany/nixos-flake-modules.git"

# ntfs 上 git 的 index 会带奇怪权限位，统一压掉
git config core.fileMode false
git config core.autocrlf false

if [ ! -d .git ]; then
  git init -q -b main
fi
git config user.name  "${GIT_NAME:-cifany}"
git config user.email "${GIT_EMAIL:-cifany@users.noreply.github.com}"

git add -A
if git diff --cached --quiet; then
  echo "没有变更"
else
  git commit -q -m "$MSG"
fi

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi

git push -q -u origin main
echo "已推送：https://github.com/cifany/nixos-flake-modules"
