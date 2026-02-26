#!/usr/bin/env bash
set -euo pipefail

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

# 需要 sudo
if ! command -v sudo >/dev/null 2>&1; then
  err "未找到 sudo，请先安装 sudo 或使用 root 用户运行。"
  exit 1
fi

install_git() {
  if command -v git >/dev/null 2>&1; then
    log "Git 已安装：$(git --version)"
    return
  fi

  log "未检测到 Git，开始安装..."
  if command -v apt >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y git
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y git
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm git
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y git
  else
    err "未识别的包管理器，无法自动安装 Git。"
    exit 1
  fi

  log "Git 安装完成：$(git --version)"
}

configure_git_user() {
  local name="${1:-}"
  local email="${2:-}"

  # 若未传参则交互输入
  if [[ -z "$name" ]]; then
    read -rp "请输入 Git 用户名 (user.name): " name
  fi
  if [[ -z "$email" ]]; then
    read -rp "请输入 Git 邮箱 (user.email): " email
  fi

  if [[ -z "$name" || -z "$email" ]]; then
    err "用户名和邮箱不能为空。"
    exit 1
  fi

  git config --global user.name "$name"
  git config --global user.email "$email"

  # 可选：默认分支为 main
  git config --global init.defaultBranch main

  log "Git 全局用户信息已配置完成。"
  echo "user.name  = $(git config --global user.name)"
  echo "user.email = $(git config --global user.email)"
}

main() {
  # 支持命令行参数：
  # ./setup-git-user.sh "Your Name" "you@example.com"
  local name="${1:-}"
  local email="${2:-}"

  install_git
  configure_git_user "$name" "$email"

  log "完成 ✅"
}

main "$@"
