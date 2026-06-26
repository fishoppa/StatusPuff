#!/usr/bin/env bash
#
# realm.sh — 一键安装 / 更新 realm 并拉取配置
#   - 未安装: 下载最新 realm + 创建 systemd 服务 + 拉取配置 + 启动
#   - 已安装: 仅拉取最新配置并重启(自动校验, 失败回滚)
#
set -euo pipefail

# ===================== 可配置项 =====================
CONFIG_URL="https://raw.githubusercontent.com/fishoppa/StatusPuff/refs/heads/master/config.toml"
REALM_BIN="/usr/local/bin/realm"
CONFIG_DIR="/etc/realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
# ===================================================

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '>> %s\n' "$*"; }

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || { red "请用 root 运行: sudo bash realm.sh"; exit 1; }
command -v curl >/dev/null 2>&1 || { red "缺少 curl, 请先安装"; exit 1; }
command -v tar  >/dev/null 2>&1 || { red "缺少 tar, 请先安装";  exit 1; }

# ---------- 安装 realm 二进制 ----------
install_binary() {
  local arch tmp bin
  case "$(uname -m)" in
    x86_64)  arch="x86_64-unknown-linux-gnu"  ;;
    aarch64) arch="aarch64-unknown-linux-gnu" ;;
    *) red "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
  info "下载 realm (${arch}) ..."
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/zhboner/realm/releases/latest/download/realm-${arch}.tar.gz" \
       -o "${tmp}/realm.tar.gz"
  tar -xzf "${tmp}/realm.tar.gz" -C "$tmp"
  bin="$(find "$tmp" -type f -name realm -print -quit)"
  [ -n "$bin" ] || { red "解压后未找到 realm 二进制"; rm -rf "$tmp"; exit 1; }
  install -m 0755 "$bin" "$REALM_BIN"
  rm -rf "$tmp"
  green "realm 已安装: $("$REALM_BIN" -v 2>/dev/null || echo realm)"
}

# ---------- 确保 systemd 服务存在 ----------
ensure_service() {
  [ -f "$SERVICE_FILE" ] && return 0
  info "创建 systemd 服务 ..."
  cat > "$SERVICE_FILE" <<'SVC'
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC
  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1 || true
}

# ---------- 下载配置(校验通过才覆盖, 自动备份) ----------
download_config() {
  info "从 ${CONFIG_URL} 拉取配置 ..."
  mkdir -p "$CONFIG_DIR"
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL "$CONFIG_URL" -o "$tmp"; then
    red "配置下载失败(网络/URL), 保留现有配置"; rm -f "$tmp"; exit 1
  fi
  if [ ! -s "$tmp" ] || ! grep -qE '\[\[endpoints\]\]|\[network\]' "$tmp"; then
    red "下载内容不像 realm 配置(可能是错误页), 保留现有配置"; rm -f "$tmp"; exit 1
  fi
  [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  mv "$tmp" "$CONFIG_FILE"
  green "配置已更新: $CONFIG_FILE"
}

# ---------- 重启 + 健康检查 + 失败回滚 ----------
restart_realm() {
  info "重启 realm ..."
  systemctl restart realm
  sleep 2
  if systemctl is-active --quiet realm; then
    green "realm 运行正常"
  else
    red "realm 启动失败!"
    if [ -f "${CONFIG_FILE}.bak" ]; then
      red "回滚到上一份配置 ..."
      mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
      systemctl restart realm || true
    fi
    red "请排查: journalctl -u realm -n 50 --no-pager"
    exit 1
  fi
}

# ===================== 主流程 =====================
if [ -x "$REALM_BIN" ]; then
  green "检测到已安装 realm —— 仅更新配置"
else
  green "未检测到 realm —— 执行全新安装"
  install_binary
fi
ensure_service
download_config
restart_realm
green "全部完成 ✓"
