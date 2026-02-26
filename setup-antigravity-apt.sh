#!/usr/bin/env bash
set -euo pipefail

KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/antigravity-repo-key.gpg"
LIST_FILE="/etc/apt/sources.list.d/antigravity.list"
KEY_URL="https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg"
REPO_LINE="deb [signed-by=${KEYRING_FILE}] https://us-central1-apt.pkg.dev/projects/antigravity-auto-updater-dev/ antigravity-debian main"

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

# 必须是 Debian/Ubuntu 系 apt 系统
if ! command -v apt >/dev/null 2>&1; then
  err "当前系统不支持 apt，脚本仅适用于 Debian/Ubuntu。"
  exit 1
fi

# 检查依赖
for cmd in curl gpg sudo tee; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "缺少依赖命令: $cmd"
    exit 1
  fi
done

log "创建 keyrings 目录..."
sudo mkdir -p "$KEYRING_DIR"

log "下载并安装仓库签名密钥..."
curl -fsSL "$KEY_URL" | sudo gpg --dearmor --yes -o "$KEYRING_FILE"

log "写入 APT 源..."
echo "$REPO_LINE" | sudo tee "$LIST_FILE" >/dev/null

log "更新 APT 索引..."
sudo apt update

log "完成 ✅"
echo "你现在可以安装相关包了。"
