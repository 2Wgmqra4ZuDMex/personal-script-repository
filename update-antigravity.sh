#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }

log "更新 APT 索引..."
sudo apt update

log "升级 antigravity..."
# 仅升级已安装包（未安装会报错）
if dpkg -s antigravity >/dev/null 2>&1; then
  sudo apt install --only-upgrade -y antigravity
else
  log "未检测到 antigravity，执行安装..."
  sudo apt install -y antigravity
fi

log "当前版本信息："
apt policy antigravity | sed -n '1,20p'

log "完成 ✅"
