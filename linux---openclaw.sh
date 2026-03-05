#!/usr/bin/env bash
# ============================================================================
# OpenClaw VPS 一键部署脚本
# 
# 功能：安装 OpenClaw → 修复已知问题 → onboard 向导 → doctor --fix 标准化
#
# 一键安装（在 VPS 上运行）：
#   curl -fsSL https://raw.githubusercontent.com/2Wgmqra4ZuDMex/personal-script-repository/main/linux---openclaw.sh -o /tmp/openclaw-deploy.sh && bash /tmp/openclaw-deploy.sh
#
# 使用方式：
#   bash deploy.sh                 # 完整部署（含交互式 onboard）
#   bash deploy.sh --skip-onboard  # 只安装+修复（跳过 onboard 向导）
#
# 已修复的已知问题：
#   1. PATH: ~/.npm-global/bin 不在 PATH 中
#   2. Bug #14845: SSH 环境下 systemd 服务文件不会被自动创建
#   3. systemd user 会话延迟初始化
#   4. Dashboard 版本显示 "dev"（通过 doctor --fix 修复）
#
# 项目地址：https://github.com/2Wgmqra4ZuDMex/personal-script-repository
# ============================================================================

set -euo pipefail

# ===== 颜色和输出函数 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✅]${NC} $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC} $*"; }
error()   { echo -e "${RED}[❌]${NC} $*"; }
step()    { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

# ===== 参数解析 =====
SKIP_ONBOARD=false
for arg in "$@"; do
  case "$arg" in
    --skip-onboard) SKIP_ONBOARD=true ;;
    --help|-h)
      echo "用法: bash deploy.sh [选项]"
      echo "选项:"
      echo "  --skip-onboard  跳过 onboard 向导（只安装+修复）"
      echo "  --help          显示帮助"
      exit 0
      ;;
  esac
done

# ===== 环境变量 =====
NPM_GLOBAL_BIN="$HOME/.npm-global/bin"
OPENCLAW_BIN="$NPM_GLOBAL_BIN/openclaw"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/openclaw-gateway.service"

# ============================================================================
# Step 1: 安装 OpenClaw（使用官方脚本）
# ============================================================================
step "Step 1/4: 安装 OpenClaw"

if command -v openclaw &>/dev/null || [ -x "$OPENCLAW_BIN" ]; then
  EXISTING_VER=$("$OPENCLAW_BIN" --version 2>/dev/null || openclaw --version 2>/dev/null || echo "unknown")
  success "OpenClaw 已安装 (v$EXISTING_VER)，跳过安装"
else
  info "运行官方安装脚本 (--no-onboard)..."
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
  success "官方安装脚本执行完成"
fi

# ============================================================================
# Step 2: 修复已知问题
# ============================================================================
step "Step 2/4: 修复已知问题"

# ----- 2a. 修复 PATH -----
info "检查 PATH..."
if echo "$PATH" | tr ':' '\n' | grep -q "$NPM_GLOBAL_BIN"; then
  success "PATH 已包含 $NPM_GLOBAL_BIN"
else
  warn "PATH 缺少 $NPM_GLOBAL_BIN，正在修复..."
  export PATH="$NPM_GLOBAL_BIN:$PATH"
  
  # 写入 shell 配置文件
  SHELL_RC="$HOME/.bashrc"
  [ -n "${ZSH_VERSION:-}" ] && SHELL_RC="$HOME/.zshrc"
  
  if ! grep -q "npm-global/bin" "$SHELL_RC" 2>/dev/null; then
    echo "export PATH=\"$NPM_GLOBAL_BIN:\$PATH\"" >> "$SHELL_RC"
    success "已写入 $SHELL_RC"
  else
    success "$SHELL_RC 中已有 PATH 设置"
  fi
fi

# 验证 openclaw 可执行
if ! command -v openclaw &>/dev/null; then
  error "openclaw 命令仍然找不到，安装可能有问题"
  exit 1
fi
INSTALLED_VER=$(openclaw --version 2>/dev/null || echo "unknown")
success "openclaw v$INSTALLED_VER 可正常调用"

# ----- 2b. 启用 systemd lingering -----
info "检查 systemd lingering..."
if [ -f "/var/lib/systemd/linger/$USER" ]; then
  success "lingering 已启用"
else
  info "启用 lingering..."
  loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER" 2>/dev/null || warn "无法启用 lingering（可能需要 sudo）"
  if [ -f "/var/lib/systemd/linger/$USER" ]; then
    success "lingering 已启用"
  else
    warn "lingering 设置未确认，onboard 可能会处理"
  fi
fi

# ----- 2c. 等待 systemd --user 就绪 -----
info "等待 systemd 用户会话就绪..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  STATE=$(systemctl --user show --property=SystemState 2>/dev/null | cut -d= -f2 || echo "unknown")
  if [ "$STATE" = "running" ]; then
    success "systemd 用户会话已就绪 (State: $STATE)"
    break
  fi
  sleep 2
  WAITED=$((WAITED + 2))
  info "等待中... ($WAITED/${MAX_WAIT}s, State: $STATE)"
done

if [ $WAITED -ge $MAX_WAIT ]; then
  warn "systemd 用户会话等待超时 (State: $STATE)，继续执行"
fi

# ----- 2d. 预创建 systemd 服务文件（绕过 Bug #14845） -----
# Bug #14845: SSH 环境下 onboard 无法自动创建服务文件
# 策略：预创建最小占位文件 + enable，让 onboard 的 is-enabled 检查通过
# onboard 完成后用 doctor --fix 生成标准服务文件（含版本号、端口、token 等）
info "检查 systemd 服务文件..."

# 检测 openclaw 的实际路径
OPENCLAW_PATH=$(command -v openclaw 2>/dev/null || echo "$OPENCLAW_BIN")

if [ -f "$SERVICE_FILE" ]; then
  success "服务文件已存在: $SERVICE_FILE"
else
  info "预创建占位服务文件（绕过 Bug #14845）..."
  mkdir -p "$SERVICE_DIR"
  cat > "$SERVICE_FILE" << EOFSERVICE
[Unit]
Description=OpenClaw Gateway (placeholder)
After=network.target

[Service]
Type=simple
ExecStart=$OPENCLAW_PATH gateway
Restart=on-failure
RestartSec=5
Environment=HOME=$HOME
Environment=PATH=$NPM_GLOBAL_BIN:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOFSERVICE

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable openclaw-gateway.service 2>/dev/null || true
  success "占位服务文件已创建并启用（onboard 后 doctor --fix 会替换为标准版）"
fi

# ----- 2e. 运行 doctor 诊断 -----
info "运行 openclaw doctor 诊断..."
openclaw doctor --non-interactive 2>&1 | tail -5 || true
success "doctor 诊断完成"

# ============================================================================
# Step 3: 启动 onboard 向导
# ============================================================================
step "Step 3/4: 运行安装向导"

if [ "$SKIP_ONBOARD" = true ]; then
  warn "已跳过 onboard 向导 (--skip-onboard)"
  echo ""
  echo -e "${CYAN}请稍后手动运行：${NC}"
  echo -e "  ${GREEN}openclaw onboard --install-daemon${NC}"
  echo ""
else
  info "启动 openclaw onboard 向导..."
  echo ""
  echo -e "${YELLOW}┌──────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  接下来进入 OpenClaw 交互式向导                   │${NC}"
  echo -e "${YELLOW}│  向导将引导你完成：                                │${NC}"
  echo -e "${YELLOW}│    · 模型认证（API Key 设置）                      │${NC}"
  echo -e "${YELLOW}│    · Gateway 网关配置                              │${NC}"
  echo -e "${YELLOW}│    · systemd 守护服务安装                          │${NC}"
  echo -e "${YELLOW}│    · 渠道配置（Discord/Telegram 等）               │${NC}"
  echo -e "${YELLOW}│    · Skills 和 Hooks 配置                          │${NC}"
  echo -e "${YELLOW}│                                                  │${NC}"
  echo -e "${YELLOW}│  ⚠️  Gateway 步骤：选 Keep 或 Restart              │${NC}"
  echo -e "${YELLOW}│     不要选 Reinstall（会触发 Bug #14845）          │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────┘${NC}"
  echo ""
  
  openclaw onboard --install-daemon
fi

# ============================================================================
# Step 4: 修复服务文件（doctor --fix）
# ============================================================================
step "Step 4/4: 修复服务配置"

info "运行 openclaw doctor --fix 生成标准服务文件..."
echo -e "${CYAN}（此步骤会修复版本显示、环境变量、网络依赖等配置）${NC}"
openclaw doctor --fix 2>&1 || true

# ----- 4a. 修复 tools.profile -----
# onboard 默认设置 tools.profile="messaging"，导致文件/执行/Web 等工具不可用
CURRENT_PROFILE=$(openclaw config get tools.profile 2>/dev/null || echo "unknown")
if [ "$CURRENT_PROFILE" != "full" ]; then
  info "修复工具配置：tools.profile '$CURRENT_PROFILE' → 'full'"
  openclaw config set tools.profile full 2>/dev/null || true
  success "已启用全部工具（文件读写、命令执行、Web 搜索等）"
else
  success "tools.profile 已经是 'full'"
fi

# ----- 4b. 重启 Gateway -----
# doctor --fix 后需要重启服务以加载新配置
if systemctl --user is-active openclaw-gateway.service &>/dev/null; then
  info "重启 Gateway 以加载新配置..."
  systemctl --user restart openclaw-gateway.service 2>/dev/null || true
  sleep 3
  if systemctl --user is-active openclaw-gateway.service &>/dev/null; then
    success "Gateway 已重启，新配置已生效"
  else
    warn "Gateway 重启后未运行，请手动检查: systemctl --user status openclaw-gateway.service"
  fi
else
  info "Gateway 未运行，跳过重启"
fi

success "服务配置修复完成"

# ============================================================================
# 完成
# ============================================================================
step "部署完成"

echo -e "${GREEN}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  🦞 OpenClaw 部署完成！                           │${NC}"
echo -e "${GREEN}│                                                  │${NC}"
echo -e "${GREEN}│  常用命令：                                       │${NC}"
echo -e "${GREEN}│    openclaw status        查看状态                │${NC}"
echo -e "${GREEN}│    openclaw gateway status 查看 Gateway           │${NC}"
echo -e "${GREEN}│    openclaw doctor        诊断问题                │${NC}"
echo -e "${GREEN}│    openclaw agent --message \"你好\"  发消息       │${NC}"
echo -e "${GREEN}│    openclaw dashboard     打开仪表板              │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────┘${NC}"
