#!/bin/bash
###############################################################################
# sing-box 精简版一键安装脚本（VLESS + Reality 专用）
#
# 功能：零交互，只安装 VLESS + Reality（TCP），无证书依赖、无 Argo
#   VLESS + Reality 是穿透能力最强、配置最简单的一个协议，适合只想快速
#   搭一个能用节点、不想折腾的用户。
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-vless.sh | sudo bash
#   卸载：curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-vless.sh | sudo bash -s -- uninstall
#
# 特性：
#   - 全程无交互：UUID、Reality 密钥对自动生成
#   - 新装时端口在 10000-60000 随机分配（避开占用）；重跑保持原端口
#   - 与 6 协议全自动版共用 /etc/s-box/auto.env，同机切换版本时 UUID/密钥/端口保持不变
#   - 幂等：重复运行只重写配置并重启，不改变客户端链接
#   - 小内存保护：<1G 无 swap 时预警；<2G 的 dnf/yum 系统禁用 dnf-makecache 定时器
#   - SELinux Enforcing 自动切 Permissive（Oracle Linux）；防火墙含 ip6tables（纯 IPv6）
#   - 安装后打印 vless:// 链接，并保存到 /root/singbox-links.txt
#
# 参考互联网上知名的相关 sing-box 一键脚本
###############################################################################
set -euo pipefail

#----------------------------- 0. 参数与常量 ---------------------------------
ACTION="${1:-install}"

SB_DIR="/etc/s-box"
ENV_FILE="$SB_DIR/auto.env"    # 与全自动版共用：UUID/端口/密钥
LINKS_FILE="/root/singbox-links.txt"

DEF_PORT_VLESS=29821            # 兜底默认端口（仅旧 env 缺端口时用；新装走随机）

SNI_REALITY="apple.com"        # Reality 伪装域名（常见默认值）

if [[ "$EUID" -ne 0 ]]; then
  echo "[错误] 请以 root 运行，例如：sudo bash $0"
  exit 1
fi

#----------------------------- 1. 系统识别 -----------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi
  if command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  elif command -v apk >/dev/null 2>&1; then PKG="apk"
  else echo "[错误] 不支持的系统：找不到 apt/dnf/yum/apk"; exit 1; fi
  echo "[信息] 系统：${OS_ID}，包管理器：${PKG}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *) echo "[错误] 不支持的架构：$(uname -m)"; exit 1 ;;
  esac
  echo "[信息] 架构：${ARCH}"
}

check_memory() {
  # 小内存机器预警：dnf 单次可占 350M+，无 swap 时易 OOM 卡死整机（实测 498M 机器被顶爆过）
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 1048576 ] && [ "$swap_kb" -eq 0 ]; then
    echo "[警告] 内存较小 ($((mem_kb / 1024))M) 且无 swap，装依赖时 dnf 可能 OOM 导致卡死"
    echo "[警告] 建议先加 swap：fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    echo "[警告] 继续安装…"
  fi
}

disable_dnf_makecache() {
  # 小内存机器（<2G）禁用 dnf-makecache 定时器：后台自动跑 dnf 易致 OOM
  # 只影响软件源缓存的自动更新，手动 dnf 不受影响
  case "$PKG" in
    dnf|yum) ;;
    *) return 0 ;;
  esac
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files 2>/dev/null | grep -q "^dnf-makecache\.timer" || return 0
  local mem_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 2097152 ]; then
    if systemctl is-enabled --quiet dnf-makecache.timer 2>/dev/null; then
      systemctl disable --now dnf-makecache.timer >/dev/null 2>&1 || true
      echo "[信息] 已禁用 dnf-makecache 定时器（小内存机器，后台自动 dnf 易致 OOM）"
    fi
  fi
}

install_deps() {
  # 先检查缺什么：齐了就直接跳过，dnf 在小内存机器上又慢又吃内存
  local need="" pkgs="" c
  command -v curl >/dev/null 2>&1 || need="$need curl"
  command -v jq >/dev/null 2>&1 || need="$need jq"
  command -v openssl >/dev/null 2>&1 || need="$need openssl"
  command -v tar >/dev/null 2>&1 || need="$need tar"
  { command -v ss >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; } || need="$need iproute"
  command -v crontab >/dev/null 2>&1 || need="$need cron"
  if [[ -z "${need// }" ]]; then
    echo "[信息] 依赖已齐全，跳过安装"
    return 0
  fi
  echo "[信息] 安装缺失依赖：$need …"
  case "$PKG" in
    apt) apt-get update -y >/dev/null 2>&1 || true
         pkgs=""
         for c in $need; do
           case "$c" in
             curl) pkgs="$pkgs curl" ;;
             jq) pkgs="$pkgs jq" ;;
             openssl) pkgs="$pkgs openssl" ;;
             tar) pkgs="$pkgs tar" ;;
             iproute) pkgs="$pkgs iproute2" ;;
             cron) pkgs="$pkgs cron" ;;
           esac
         done
         pkgs="$pkgs ca-certificates"
         # shellcheck disable=SC2086
         DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || true ;;
    dnf) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute" ;;
             cron) pkgs="$pkgs cronie" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         # shellcheck disable=SC2086
         dnf install -y --setopt=install_weak_deps=False $pkgs >/dev/null 2>&1 || true ;;
    yum) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute" ;;
             cron) pkgs="$pkgs cronie" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         # shellcheck disable=SC2086
         yum install -y $pkgs >/dev/null 2>&1 || true ;;
    apk) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute2" ;;
             cron) pkgs="$pkgs dcron" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         pkgs="$pkgs ca-certificates"
         # shellcheck disable=SC2086
         apk add --no-cache $pkgs >/dev/null 2>&1 || true ;;
  esac
  command -v curl >/dev/null 2>&1 || { echo "[错误] curl 安装失败"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "[错误] jq 安装失败"; exit 1; }
}

#----------------------------- 2. 端口分配 -----------------------------------
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -tunlp 2>/dev/null | grep -Eo ':[0-9]+' | grep -qw ":$p"; then
      return 0
    fi
  fi
  return 1
}

rand_port() {
  # 在 10000-60000 内随机取一个空闲端口
  local p tries=0
  while (( tries < 100 )); do
    p=$(( (RANDOM * 32768 + RANDOM) % 50001 + 10000 ))
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  echo "[错误] 无法分配随机空闲端口" >&2
  exit 1
}

#----------------------------- 3. 防火墙放行 ---------------------------------
open_firewall() {
  echo "[信息] 放行防火墙…"
  # 用配置里的实际端口（TCP+UDP 双开）
  local ports="$PORT_VLESS"
  systemctl stop firewalld >/dev/null 2>&1 || true
  systemctl disable firewalld >/dev/null 2>&1 || true
  ufw disable >/dev/null 2>&1 || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -P INPUT ACCEPT >/dev/null 2>&1 || true
    iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
    iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
    iptables -F >/dev/null 2>&1 || true
    iptables -X >/dev/null 2>&1 || true
    for p in $ports; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    service iptables save >/dev/null 2>&1 || true
  fi
  # ip6tables：纯 IPv6 机器上 iptables 管不到 v6，需单独放行
  if command -v ip6tables >/dev/null 2>&1; then
    for p in $ports; do
      ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    service ip6tables save >/dev/null 2>&1 || true
  fi
  echo "[信息] 防火墙已放行"
}

fix_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    echo "[信息] 检测到 SELinux 为 Enforcing，切换为 Permissive（否则代理出站会被拦截）…"
    setenforce 0 2>/dev/null || true
    [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "[信息] SELinux 已切换为 Permissive（重启后依然有效）"
  fi
}

#----------------------------- 4. 安装 sing-box ------------------------------
install_singbox() {
  mkdir -p "$SB_DIR"
  if [[ -x "$SB_DIR/sing-box" ]]; then
    echo "[信息] sing-box 已安装：$("$SB_DIR/sing-box" version 2>/dev/null | awk '/version/{print $NF}')"
    return 0
  fi
  echo "[信息] 获取 sing-box 最新版本…"
  local ver=""
  ver=$(curl -fsSL --max-time 15 --retry 2 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true)
  if [[ -z "$ver" ]]; then
    ver=$(curl -fsSL --max-time 15 --retry 2 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -n 1 || true)
  fi
  [[ -z "$ver" ]] && { echo "[错误] 获取 sing-box 版本失败，请检查网络"; exit 1; }
  echo "[信息] 最新版本：v$ver，开始下载…"
  local name="sing-box-${ver}-linux-${ARCH}"
  curl -fSL --retry 2 -o "$SB_DIR/sing-box.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${name}.tar.gz" \
    || { echo "[错误] sing-box 下载失败"; exit 1; }
  tar xzf "$SB_DIR/sing-box.tar.gz" -C "$SB_DIR"
  mv -f "$SB_DIR/$name/sing-box" "$SB_DIR/sing-box"
  rm -rf "$SB_DIR/sing-box.tar.gz" "$SB_DIR/$name"
  chmod +x "$SB_DIR/sing-box"
  echo "[信息] sing-box 安装成功：$("$SB_DIR/sing-box" version | awk '/version/{print $NF}')"
}

#----------------------------- 5. 身份与端口 ----------------------------------
save_env() {
  # 与全自动版共用同一 env 文件；本脚本只用其中 UUID/密钥/VLESS 端口
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_VLESS="$PORT_VLESS"
PORT_VMESS="${PORT_VMESS:-}"
PORT_HY2="${PORT_HY2:-}"
PORT_TUIC="${PORT_TUIC:-}"
PORT_ANYTLS="${PORT_ANYTLS:-}"
EOF
  chmod 600 "$ENV_FILE"
}

# 三级取值：①已有 env（任一版本上次运行）→ ②残留 sb.json → ③全新生成
load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    [[ -z "${PORT_VLESS:-}" ]] && PORT_VLESS=$(rand_port)
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" ]]; then
      echo "[信息] 检测到已有配置，UUID/密钥/端口保持不变（幂等重跑）"
      save_env
      return 0
    fi
    echo "[警告] 已有配置不完整，将重新生成身份信息"
  fi
  if [[ -f "$SB_DIR/sb.json" ]]; then
    local old_uuid=""
    old_uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
    if [[ -n "$old_uuid" ]]; then
      UUID="$old_uuid"
      PORT_VLESS=$(jq -r '.inbounds[0].listen_port' "$SB_DIR/sb.json" 2>/dev/null || true)
      PRIVKEY=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      SHORTID=$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PUBKEY="$(cat "$SB_DIR/public.key" 2>/dev/null || true)"
      if [[ -n "$PRIVKEY" && -n "$PUBKEY" && -n "$SHORTID" ]]; then
        echo "[信息] 从残留配置导入 UUID/端口/密钥，客户端链接保持不变"
        PORT_VMESS=""; PORT_HY2=""; PORT_TUIC=""; PORT_ANYTLS=""
        save_env
        return 0
      fi
    fi
  fi
  echo "[信息] 生成 UUID 与 Reality 密钥对…"
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  echo "$PUBKEY" > "$SB_DIR/public.key"
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" ]]; then
    echo "[错误] Reality 密钥生成失败"; exit 1
  fi
  PORT_VLESS=$(rand_port)
  PORT_VMESS=""; PORT_HY2=""; PORT_TUIC=""; PORT_ANYTLS=""
  echo "[信息] 端口分配：VLESS=$PORT_VLESS"
  save_env
}

#----------------------------- 6. 写 sing-box 配置 ----------------------------
write_config() {
  echo "[信息] 写入 sing-box 配置（仅 VLESS + Reality）…"
  cat > "$SB_DIR/sb.json" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality",
      "listen": "::", "listen_port": $PORT_VLESS,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "$SNI_REALITY",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$SNI_REALITY", "server_port": 443},
          "private_key": "$PRIVKEY",
          "short_id": ["$SHORTID"]
        }
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
  "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1 \
    || { echo "[错误] 配置校验失败"; exit 1; }
  echo "[信息] 配置校验通过"
}

#----------------------------- 7. 系统服务 ------------------------------------
setup_service() {
  echo "[信息] 配置并启动 sing-box 服务…"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_DIR/sing-box run -c $SB_DIR/sb.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
      echo "[信息] sing-box 运行中"
    else
      echo "[错误] sing-box 启动失败，日志如下："
      journalctl -u sing-box --no-pager -n 20 2>/dev/null || true
      exit 1
    fi
  else
    echo "[警告] 未检测到 systemd，改用后台方式启动"
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" >/var/log/sing-box.log 2>&1 &
    sleep 2
    pgrep -f "$SB_DIR/sing-box run" >/dev/null || { echo "[错误] sing-box 启动失败"; exit 1; }
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "sing-box run"; echo "@reboot sleep 10 && $SB_DIR/sing-box run -c $SB_DIR/sb.json >/var/log/sing-box.log 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    echo "[信息] sing-box 已在后台启动"
  fi
}

#----------------------------- 8. 输出客户端链接 ------------------------------
get_ip() {
  local ip=""
  ip=$(curl -fsSL --max-time 8 -4 icanhazip.com 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(curl -fsSL --max-time 8 -6 icanhazip.com 2>/dev/null || true)
  fi
  if [[ "$ip" == *:* ]]; then ip="[$ip]"; fi   # IPv6 加方括号
  echo "$ip"
}

print_links() {
  local ip host vl_link
  ip="$(get_ip)"
  host="$(hostname)"
  vl_link="vless://${UUID}@${ip}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#vl-reality-${host}"

  {
    echo "================ sing-box 节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "VLESS + Reality (TCP/${PORT_VLESS})"
    echo "$vl_link"
    echo
    echo "==================================================="
    echo "提示：链接已保存到 $LINKS_FILE"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 9. 卸载 ----------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box…"
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "sing-box run") | crontab - >/dev/null 2>&1 || true
  fi
  rm -rf "$SB_DIR" "$LINKS_FILE"
  echo "[信息] 卸载完成"
}

#----------------------------- 主流程 ------------------------------------------
case "$ACTION" in
  install)
    detect_os
    detect_arch
    check_memory
    disable_dnf_makecache
    install_deps
    install_singbox
    load_or_gen_identity
    write_config
    open_firewall
    fix_selinux
    setup_service
    print_links
    echo
    echo "[完成] VLESS + Reality 已就绪，链接见上 / $LINKS_FILE"
    ;;
  uninstall)
    do_uninstall
    ;;
  *)
    echo "用法：$0 [install|uninstall]"
    exit 1
    ;;
esac
