#!/bin/bash
###############################################################################
# sing-box 全自动一键安装脚本（6 协议版）
#
# 功能：零交互，一次装好以下 6 种协议
#   [1] VLESS + Reality (TCP)
#   [2] VMess + WebSocket (TCP)
#   [3] VMess + Argo 隧道 (Cloudflare 临时隧道，转发到 VMess-WS)
#   [4] Hysteria2 (UDP)
#   [5] TUIC v5 (UDP)
#   [6] AnyTLS (TCP)
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-auto.sh | sudo bash
#   卸载：curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- uninstall
#   管理菜单：curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- menu
#   （或下载后 sudo bash sing-box-auto.sh menu）
#   动作参数：menu | change-uuid | change-reality | change-cert | change-argo
#            | change-ports | show-links | restart | uninstall | update-script
#   快捷命令：安装时会自动装好 sbox 命令（/usr/local/bin/sbox），之后直接打
#            sbox 就进管理菜单（非 root 会自动 sudo 提权），sbox <动作> 执行对应操作
#
# 特性：
#   - 全程无交互：UUID、密码、Reality 密钥对全部自动生成
#   - 随机端口：新装时 5 个协议端口在 10000-60000 内随机分配（互不冲突，避开已占用），
#     多台服务器端口各不相同；重跑/升级保留已有端口，菜单 5 可手动改
#   - 防火墙：自动从配置提取监听端口并在 firewalld/ufw/iptables 放行，
#     配置增减协议或换端口时自动跟上
#   - 证书：自动生成 www.bing.com 自签证书（供 Hy2/TUIC/AnyTLS/VMess-WS 使用）
#   - 幂等：重复运行保留已有 UUID/端口/密钥，只重写配置并重启；也能识别原版
#     yonggekkk 脚本留下的配置并导入
#   - 安装后打印全部客户端链接，并保存到 /root/singbox-links.txt
#
# 参考原版：https://github.com/yonggekkk/sing-box-yg/blob/main/sb.sh
# 原版交互点已全部自动化，详见本仓库 README.md
###############################################################################
set -euo pipefail

#----------------------------- 0. 参数与常量 ---------------------------------
# 通过 sbox 快捷命令调用且无参数时默认进菜单；其他方式无参数默认执行安装
if [[ "$(basename "$0")" == "sbox" && $# -eq 0 ]]; then
  ACTION="menu"
else
  ACTION="${1:-install}"        # install | uninstall | menu | change-uuid | change-reality | change-cert | change-argo | change-ports | show-links | restart | update-script
fi

SB_DIR="/etc/s-box"
ENV_FILE="$SB_DIR/auto.env"    # 持久化：UUID/端口/密钥，重跑时复用
LINKS_FILE="/root/singbox-links.txt"

# 端口分配：新装时随机（10000-60000），重跑/升级保留已有端口（见 load_or_gen_identity）

SNI_REALITY="apple.com"        # Reality 伪装域名（原版默认）
SNI_SELF="www.bing.com"        # 自签证书 CN

if [[ "$EUID" -ne 0 ]]; then
  # sbox 快捷命令：非 root 时自动提权，opc 下直接打 sbox 就能进菜单
  if [[ "$(basename "$0")" == "sbox" ]]; then
    exec sudo "$0" "$@"
  fi
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
  # 包名映射（cron 在不同发行版名字不一样）
  for c in $need; do
    case "$c" in
      cron)
        case "$PKG" in
          apt) pkgs="$pkgs cron" ;;
          apk) pkgs="$pkgs dcron" ;;
          *) pkgs="$pkgs cronie" ;;
        esac ;;
      *) pkgs="$pkgs $c" ;;
    esac
  done
  echo "[信息] 安装缺失依赖：${pkgs} …"
  case "$PKG" in
    apt) apt-get update -y >/dev/null 2>&1 || true
         DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || true ;;
    dnf) dnf install -y --setopt=install_weak_deps=False $pkgs >/dev/null 2>&1 || true ;;
    yum) yum install -y $pkgs >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache $pkgs >/dev/null 2>&1 || true ;;
  esac
  command -v curl >/dev/null 2>&1 || { echo "[错误] curl 安装失败"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "[错误] jq 安装失败"; exit 1; }
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

#----------------------------- 2. 端口分配 -----------------------------------
# 端口是否被占用（TCP/UDP 一起查）
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -tunlp 2>/dev/null | grep -Eo ':[0-9]+' | grep -qw ":$p"; then
      return 0
    fi
  fi
  return 1
}

# 从默认端口开始，被占用就 +1，直到找到空闲端口
rand_port() {
  # 在 10000-60000 内随机取一个空闲端口
  # 参数 $1：已分配端口列表（空格分隔，如 " 29821 20867 "），避免 5 个协议互相冲突
  local allocated="$1" p tries=0
  while (( tries < 100 )); do
    p=$(( (RANDOM * 32768 + RANDOM) % 50001 + 10000 ))
    if [[ "$allocated" != *" $p "* ]] && ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  echo "[错误] 无法分配随机空闲端口" >&2
  exit 1
}

#----------------------------- 3. 防火墙放行 ---------------------------------
# 自适应放行：从已生成的 sing-box 配置里提取所有 inbound 监听端口，
# TCP+UDP 双开。以后脚本增减协议、换端口，这里自动跟上，无需维护端口列表。
# 必须在 write_config 之后调用。云厂商安全组/安全列表需在控制台另行放行。
open_firewall() {
  local ports=""
  if [[ -f "$SB_DIR/sb.json" ]] && command -v jq >/dev/null 2>&1; then
    ports=$(jq -r '.inbounds[].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null | sort -un | tr '\n' ' ' || true)
  fi
  # 回退：配置文件不存在或 jq 不可用时，用 PORT_* 变量
  if [[ -z "${ports// }" ]]; then
    ports="${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-}"
  fi
  if [[ -z "${ports// }" ]]; then
    echo "[警告] 未找到需要放行的端口，跳过防火墙设置"
    return 0
  fi
  echo "[信息] 放行防火墙端口：${ports}（TCP+UDP）…"
  local p
  # firewalld：仅当正在运行时加规则，不擅自启停它
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in $ports; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
      firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  # ufw：仅当已启用时加规则
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $ports; do
      ufw allow "${p}/tcp" >/dev/null 2>&1
      ufw allow "${p}/udp" >/dev/null 2>&1
    done
  fi
  # iptables：显式加 ACCEPT 规则（已存在则跳过，不动其他规则）
  if command -v iptables >/dev/null 2>&1; then
    for p in $ports; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    # 持久化（尽力而为）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    service iptables save >/dev/null 2>&1 || true
  fi
  command -v setenforce >/dev/null 2>&1 && setenforce 0 >/dev/null 2>&1 || true
  echo "[信息] 防火墙已放行"
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
  # 对应原版 inssb 选"1"（最新正式版）：优先 GitHub API，失败回退到 releases 页面解析
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

#----------------------------- 4.1 快捷命令 ----------------------------------
# 把本脚本安装为 sbox 系统命令：sudo sbox 进菜单，sudo sbox <动作> 直达操作
# 从 GitHub 拉取最新脚本（带防缓存 + 备用源），成功返回 0
fetch_latest_script() {
  local dest="$1"
  local ts url
  ts=$(date +%s)
  local urls=(
    "https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-auto.sh?t=${ts}"
    "https://cdn.jsdelivr.net/gh/tobaye/sing-box-auto@main/sing-box-auto.sh"
  )
  for url in "${urls[@]}"; do
    if curl -fsSL --max-time 60 --retry 2 "$url" -o "$dest" \
       && grep -q "sing-box 全自动一键安装脚本" "$dest" \
       && bash -n "$dest"; then
      return 0
    fi
    echo "[警告] 从 ${url%%\?*} 获取失败，尝试备用源…"
  done
  return 1
}

setup_shortcut() {
  echo "[信息] 安装 sbox 快捷命令…"
  if fetch_latest_script /usr/local/bin/sbox; then
    chmod +x /usr/local/bin/sbox
    # 部分系统 root 的 PATH（sudo secure_path）不含 /usr/local/bin，加个软链接兜底
    ln -sf /usr/local/bin/sbox /usr/bin/sbox 2>/dev/null || true
    echo "[信息] 快捷命令已安装：直接打 sbox 进管理菜单（自动提权）"
  else
    echo "[警告] sbox 快捷命令安装失败，可手动下载脚本使用"
  fi
}

#----------------------------- 5. 自签证书 -----------------------------------
# 对应原版 inscertificate：默认选"1"（不申请 Acme，直接用自签证书）
gen_certs() {
  if [[ -f "$SB_DIR/cert.pem" && -f "$SB_DIR/private.key" ]]; then
    echo "[信息] 自签证书已存在，跳过生成"
    return 0
  fi
  echo "[信息] 生成自签证书（CN=$SNI_SELF，含 SAN）…"
  openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/private.key" 2>/dev/null
  # 必须带 SAN：现代 TLS 会拒绝只有 CN 的证书
  # （x509: certificate relies on legacy Common Name field）
  if ! openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
      -out "$SB_DIR/cert.pem" -subj "/CN=$SNI_SELF" \
      -addext "subjectAltName=DNS:$SNI_SELF" 2>/dev/null; then
    # 老版本 OpenSSL 不支持 -addext，回退到配置文件方式
    local _cnf
    _cnf=$(mktemp)
    cat > "$_cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SNI_SELF
[ext]
subjectAltName = DNS:$SNI_SELF
EOF
    openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
      -out "$SB_DIR/cert.pem" -config "$_cnf" 2>/dev/null
    rm -f "$_cnf"
  fi
  [[ -f "$SB_DIR/cert.pem" ]] || { echo "[错误] 证书生成失败"; exit 1; }
  echo "[信息] 自签证书生成成功"
}

#----------------------------- 6. 身份与端口 ----------------------------------
save_env() {
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_VLESS="$PORT_VLESS"
PORT_VMESS="$PORT_VMESS"
PORT_HY2="$PORT_HY2"
PORT_TUIC="$PORT_TUIC"
PORT_ANYTLS="$PORT_ANYTLS"
EOF
  chmod 600 "$ENV_FILE"
}

# 三级取值：①本脚本上次运行的 env → ②原版脚本残留配置 → ③全新生成
load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    # 兼容精简版写下的 env：缺失的协议端口随机分配
    local used=" ${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-} "
    [[ -z "${PORT_VLESS:-}" ]] && PORT_VLESS=$(rand_port "$used") && used+=" $PORT_VLESS "
    [[ -z "${PORT_VMESS:-}" ]] && PORT_VMESS=$(rand_port "$used") && used+=" $PORT_VMESS "
    [[ -z "${PORT_HY2:-}" ]] && PORT_HY2=$(rand_port "$used") && used+=" $PORT_HY2 "
    [[ -z "${PORT_TUIC:-}" ]] && PORT_TUIC=$(rand_port "$used") && used+=" $PORT_TUIC "
    [[ -z "${PORT_ANYTLS:-}" ]] && PORT_ANYTLS=$(rand_port "$used") && used+=" $PORT_ANYTLS "
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" ]]; then
      echo "[信息] 检测到已有配置，UUID/端口/密钥保持不变（幂等重跑）"
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
      PORT_VMESS=$(jq -r '.inbounds[1].listen_port' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_HY2=$(jq -r '.inbounds[2].listen_port' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_TUIC=$(jq -r '.inbounds[3].listen_port' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_ANYTLS=$(jq -r '.inbounds[4].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      [[ -z "$PORT_ANYTLS" || "$PORT_ANYTLS" == "null" ]] && PORT_ANYTLS=$(rand_port " $PORT_VLESS $PORT_VMESS $PORT_HY2 $PORT_TUIC ")
      PRIVKEY=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      SHORTID=$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PUBKEY="$(cat "$SB_DIR/public.key" 2>/dev/null || true)"
      if [[ -n "$PRIVKEY" && -n "$PUBKEY" && -n "$SHORTID" ]]; then
        echo "[信息] 从原版脚本残留配置导入 UUID/端口/密钥，客户端链接保持不变"
        save_env
        return 0
      fi
    fi
  fi
  echo "[信息] 生成 UUID 与 Reality 密钥对…"
  # 对应原版：uuid=$(sing-box generate uuid)；用系统 uuid 亦可，这里优先用 sing-box
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
  local used=" "
  PORT_VLESS=$(rand_port "$used"); used+=" $PORT_VLESS "
  PORT_VMESS=$(rand_port "$used"); used+=" $PORT_VMESS "
  PORT_HY2=$(rand_port "$used"); used+=" $PORT_HY2 "
  PORT_TUIC=$(rand_port "$used"); used+=" $PORT_TUIC "
  PORT_ANYTLS=$(rand_port "$used"); used+=" $PORT_ANYTLS "
  echo "[信息] 端口分配：VLESS=$PORT_VLESS VMess-WS=$PORT_VMESS Hy2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS"
  save_env
}

#----------------------------- 7. 写 sing-box 配置 ---------------------------
write_config() {
  echo "[信息] 写入 sing-box 配置…"
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
    },
    {
      "type": "vmess", "tag": "vmess-ws",
      "listen": "::", "listen_port": $PORT_VMESS,
      "users": [{"uuid": "$UUID", "alterId": 0}],
      "transport": {
        "type": "ws", "path": "${UUID}-vm",
        "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {"enabled": false}
    },
    {
      "type": "hysteria2", "tag": "hysteria2",
      "listen": "::", "listen_port": $PORT_HY2,
      "users": [{"password": "$UUID"}],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "tuic", "tag": "tuic",
      "listen": "::", "listen_port": $PORT_TUIC,
      "users": [{"uuid": "$UUID", "password": "$UUID"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "anytls", "tag": "anytls",
      "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [{"password": "$UUID"}],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
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

#----------------------------- 8. 系统服务 ------------------------------------
# SELinux：Enforcing 会拦截 sing-box 的出站连接（avc denied name_connect），切为 permissive
fix_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    echo "[信息] 检测到 SELinux 为 Enforcing，切换为 Permissive（否则代理出站会被拦截）…"
    setenforce 0 2>/dev/null || true
    [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "[信息] SELinux 已切换为 Permissive（重启后依然有效）"
  fi
}

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

#----------------------------- 9. Argo 临时隧道 -------------------------------
# 原版 cfargo→菜单1：cloudflared 临时隧道无需 Cloudflare 账号授权；
# 固定隧道需要手动在 CF 官网创建并填 token，无法自动化，本脚本只做临时隧道。
# 隧道失败不阻塞：拿不到域名就跳过，只是不输出第 3 条链接。
start_argo() {
  # 如果配置了固定隧道，优先使用固定隧道
  if [[ -f "$SB_DIR/argo.env" ]]; then
    local _am
    _am=$(grep '^ARGO_MODE=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2)
    if [[ "$_am" == "fixed" ]]; then
      # shellcheck disable=SC1090
      . "$SB_DIR/argo.env"
      start_argo_fixed
      return 0
    fi
  fi
  echo "[信息] 启动 Argo 临时隧道…"
  local cf="$SB_DIR/cloudflared"
  if [[ ! -x "$cf" ]]; then
    echo "[信息] 下载 cloudflared…"
    if ! curl -fSL --retry 2 -o "$cf" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"; then
      echo "[警告] cloudflared 下载失败，跳过 Argo（不影响其他 5 种协议）"
      ARGO_DOMAIN=""
      return 0
    fi
    chmod +x "$cf"
  fi
  pkill -f "cloudflared.*tunnel.*--url" >/dev/null 2>&1 || true
  sleep 1
  nohup "$cf" tunnel --url "http://localhost:${PORT_VMESS}" \
    --edge-ip-version auto --no-autoupdate --protocol http2 \
    > "$SB_DIR/argo.log" 2>&1 &
  echo "[信息] 等待 Cloudflare 分配临时域名（最多约 60 秒）…"
  ARGO_DOMAIN=""
  local _i
  for _i in $(seq 1 20); do
    sleep 3
    ARGO_DOMAIN="$(grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true)"
    [[ -n "$ARGO_DOMAIN" ]] && break
  done
  if [[ -n "${ARGO_DOMAIN:-}" ]]; then
    echo "[信息] Argo 临时域名：$ARGO_DOMAIN（重启后会变化）"
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "cloudflared tunnel --url"
       echo "@reboot sleep 15 && $cf tunnel --url http://localhost:${PORT_VMESS} --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  else
    echo "[警告] 未能获取 Argo 域名，跳过 VMess+Argo（不影响其他 5 种协议）"
    echo "[提示] 隧道日志最后几行："
    tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
    ARGO_DOMAIN=""
  fi
}

#----------------------------- 10. 输出客户端链接 ----------------------------
get_ip() {
  local ip=""
  ip=$(curl -fsSL --max-time 8 -4 icanhazip.com 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(curl -fsSL --max-time 8 -6 icanhazip.com 2>/dev/null || true)
  fi
  if [[ "$ip" == *:* ]]; then ip="[$ip]"; fi   # IPv6 加方括号
  echo "$ip"
}

# base64 不换行（兼容 busybox）
b64() { base64 -w 0 2>/dev/null || base64 | tr -d '\n'; }

print_links() {
  local ip host shasum_v
  ip="$(get_ip)"
  host="$(hostname)"
  # 自签证书 SHA256 pin（对应原版 reshy2 的 pinSHA256 做法）
  shasum_v=$(openssl x509 -in "$SB_DIR/cert.pem" -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')

  local vl_link vm_link hy2_link tuic_link an_link
  vl_link="vless://${UUID}@${ip}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#vl-reality-${host}"

  vm_link="vmess://$(printf '{"add":"%s","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"%s","ps":"vm-ws-%s","tls":"","type":"none","v":"2"}' \
    "$ip" "$SNI_SELF" "$UUID" "$UUID" "$PORT_VMESS" "$host" | b64)"

  hy2_link="hysteria2://${UUID}@${ip}:${PORT_HY2}?security=tls&alpn=h3&insecure=1&allowInsecure=1&sni=${SNI_SELF}#hy2-${host}"

  tuic_link="tuic://${UUID}:${UUID}@${ip}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_SELF}&insecure=1&allowInsecure=1&allow_insecure=1#tu5-${host}"

  an_link="anytls://${UUID}@${ip}:${PORT_ANYTLS}?&sni=${SNI_SELF}&allowInsecure=1&insecure=1#anytls-${host}"

  {
    echo "================ sing-box 节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "[1] VLESS + Reality (TCP/${PORT_VLESS})"
    echo "$vl_link"
    echo
    echo "[2] VMess + WS (TCP/${PORT_VMESS})"
    echo "$vm_link"
    echo
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
      local argo_link
      argo_link="vmess://$(printf '{"add":"cloudflare-ech.com","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"443","ps":"vm-argo-%s","tls":"tls","sni":"%s","fp":"chrome","type":"none","v":"2"}' \
        "$ARGO_DOMAIN" "$UUID" "$UUID" "$host" "$ARGO_DOMAIN" | b64)"
      echo "[3] VMess + Argo 隧道（${ARGO_DOMAIN}，重启后会变）"
      echo "$argo_link"
    else
      echo "[3] VMess + Argo：本次未能建立隧道，已跳过"
    fi
    echo
    echo "[4] Hysteria2 (UDP/${PORT_HY2})"
    echo "$hy2_link"
    echo
    echo "[5] TUIC v5 (UDP/${PORT_TUIC})"
    echo "$tuic_link"
    echo
    echo "[6] AnyTLS (TCP/${PORT_ANYTLS})"
    echo "$an_link"
    echo
    echo "==================================================="
    echo "提示：链接已保存到 $LINKS_FILE"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 11. 卸载 --------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box…"
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  pkill -f "cloudflared.*tunnel" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "sing-box run" | grep -v "cloudflared tunnel --url") | crontab - >/dev/null 2>&1 || true
  fi
  rm -rf "$SB_DIR" "$LINKS_FILE"
  rm -f /usr/local/bin/sbox /usr/bin/sbox
  echo "[信息] 卸载完成"
}

#----------------------------- 12. 管理菜单 ------------------------------------
# 加载已保存的配置，不存在则报错退出
load_env_or_exit() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[错误] 未找到配置文件 $ENV_FILE，请先运行安装"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  if [[ -f "$SB_DIR/argo.env" ]]; then
    # shellcheck disable=SC1090
    . "$SB_DIR/argo.env"
  fi
  if [[ -z "${ARGO_DOMAIN:-}" && "${ARGO_MODE:-}" != "fixed" ]]; then
    ARGO_DOMAIN="$(grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true)"
  fi
}

# 1. 更换 UUID（全协议）
do_change_uuid() {
  load_env_or_exit
  echo "[信息] 正在生成新 UUID…"
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  echo "[信息] 新 UUID：$UUID"
  save_env
  write_config
  setup_service
  start_argo
  print_links
  echo
  echo "[完成] UUID 已更换，全协议链接已更新"
}

# 2. 更新 Reality 密钥对
do_change_reality() {
  load_env_or_exit
  echo "[信息] 正在生成新 Reality 密钥对…"
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  echo "$PUBKEY" > "$SB_DIR/public.key"
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" ]]; then
    echo "[错误] Reality 密钥生成失败"; exit 1
  fi
  save_env
  write_config
  setup_service
  print_links
  echo
  echo "[完成] Reality 密钥对已更新"
}

# 3. 更新自签证书
do_change_cert() {
  load_env_or_exit
  echo "[信息] 正在重新生成自签证书…"
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
  gen_certs
  write_config
  setup_service
  print_links
  echo
  echo "[完成] 自签证书已更新（Hy2/TUIC/AnyTLS/VMess-WS 已切换新证书）"
}

# 启动 Argo 固定隧道
start_argo_fixed() {
  local cf="$SB_DIR/cloudflared"
  if [[ ! -x "$cf" ]]; then
    echo "[错误] cloudflared 未安装，请先运行一次安装"
    return 1
  fi
  if [[ -z "${ARGO_TOKEN:-}" ]]; then
    echo "[错误] 未配置 Argo Token"
    return 1
  fi
  pkill -f "cloudflared.*tunnel" >/dev/null 2>&1 || true
  sleep 1
  nohup "$cf" tunnel --no-autoupdate run --token "$ARGO_TOKEN" > "$SB_DIR/argo.log" 2>&1 &
  echo "[信息] 固定隧道启动中…"
  sleep 5
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "cloudflared.*tunnel"
     echo "@reboot sleep 15 && $cf tunnel --no-autoupdate run --token $ARGO_TOKEN > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
  fi
  echo "[信息] 固定隧道域名：${ARGO_DOMAIN:-（未知）}"
}

# 4. Argo 隧道管理子菜单
do_argo_menu() {
  load_env_or_exit
  # 载入 Argo 状态用于显示：固定隧道读 argo.env，临时隧道从日志恢复当前域名
  if [[ -f "$SB_DIR/argo.env" ]]; then
    # shellcheck disable=SC1090
    . "$SB_DIR/argo.env" 2>/dev/null || true
  elif [[ -z "${ARGO_DOMAIN:-}" ]]; then
    ARGO_DOMAIN="$(grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true)"
  fi
  while true; do
    echo
    echo "---------- Argo 隧道管理 ----------"
    if [[ "${ARGO_MODE:-}" == "fixed" ]]; then
      echo "当前模式：固定隧道（${ARGO_DOMAIN:-未知域名}）"
    else
      echo "当前模式：临时隧道（${ARGO_DOMAIN:-未建立}）"
    fi
    echo "1. 重启临时隧道（获取新域名）"
    echo "2. 设置固定隧道（需 Cloudflare Token）"
    echo "3. 切换回临时隧道"
    echo "4. 重新抓取隧道域名（隧道在跑但没显示域名时用）"
    echo "0. 返回上级"
    read -rp "请选择 [0-4]: " c
    case "$c" in
      1)
        rm -f "$SB_DIR/argo.env"
        unset ARGO_MODE ARGO_TOKEN ARGO_DOMAIN
        start_argo
        print_links
        ;;
      2)
        local token domain
        read -rp "输入 Argo Tunnel Token: " token
        read -rp "输入固定隧道域名: " domain
        if [[ -z "$token" || -z "$domain" ]]; then
          echo "[错误] Token 和域名不能为空"
          continue
        fi
        cat > "$SB_DIR/argo.env" <<EOF
ARGO_MODE="fixed"
ARGO_TOKEN="$token"
ARGO_DOMAIN="$domain"
EOF
        chmod 600 "$SB_DIR/argo.env"
        # shellcheck disable=SC1090
        . "$SB_DIR/argo.env"
        start_argo_fixed
        print_links
        echo
        echo "[完成] 已切换到固定隧道：$domain"
        ;;
      3)
        rm -f "$SB_DIR/argo.env"
        unset ARGO_MODE ARGO_TOKEN ARGO_DOMAIN
        start_argo
        print_links
        ;;
      4)
        ARGO_DOMAIN="$(grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true)"
        if [[ -n "$ARGO_DOMAIN" ]]; then
          echo "[信息] 抓到域名：$ARGO_DOMAIN"
          print_links
        else
          echo "[警告] 日志里还没有域名，隧道可能仍在启动中，稍后再试"
          tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
        fi
        ;;
      0) break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}

# 5. 更换端口
do_change_ports() {
  load_env_or_exit
  echo "当前端口：VLESS=$PORT_VLESS VMess-WS=$PORT_VMESS Hy2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS"
  echo "输入新端口（直接回车保持不变）："
  local p
  read -rp "VLESS [$PORT_VLESS]: " p; [[ -n "$p" ]] && PORT_VLESS="$p"
  read -rp "VMess-WS [$PORT_VMESS]: " p; [[ -n "$p" ]] && PORT_VMESS="$p"
  read -rp "Hysteria2 [$PORT_HY2]: " p; [[ -n "$p" ]] && PORT_HY2="$p"
  read -rp "TUIC [$PORT_TUIC]: " p; [[ -n "$p" ]] && PORT_TUIC="$p"
  read -rp "AnyTLS [$PORT_ANYTLS]: " p; [[ -n "$p" ]] && PORT_ANYTLS="$p"
  save_env
  write_config
  open_firewall
  setup_service
  start_argo
  print_links
  echo
  echo "[完成] 端口已更新"
}

# 9. 更新脚本到最新版（从 GitHub 拉取）
do_update_script() {
  echo "[信息] 正在从 GitHub 拉取最新脚本…"
  local tmpfile
  tmpfile=$(mktemp)
  if fetch_latest_script "$tmpfile"; then
    cp -f "$tmpfile" /usr/local/bin/sbox
    chmod +x /usr/local/bin/sbox
    rm -f "$tmpfile"
    echo "[完成] 脚本已更新到最新版"
    return 0
  fi
  rm -f "$tmpfile"
  echo "[错误] 下载失败，请检查网络后重试"
  return 1
}

# 主管理菜单
# 检查端口是否在监听：$1=tcp|udp  $2=端口
port_listening() {
  case "$1" in
    tcp) command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE "[:.]$2[[:space:]]" ;;
    udp) command -v ss >/dev/null 2>&1 && ss -uln 2>/dev/null | grep -qE "[:.]$2[[:space:]]" ;;
    *) return 1 ;;
  esac
}

# 菜单端口状态（排版仿甬哥 showprotocol）
show_port_status() {
  local _d argo_st="未开启"
  if [[ -f "$SB_DIR/argo.env" ]] && grep -q '^ARGO_MODE="fixed"' "$SB_DIR/argo.env" 2>/dev/null; then
    argo_st="固定隧道：$(grep '^ARGO_DOMAIN=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2)"
  else
    _d="$(grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true)"
    [[ -n "$_d" ]] && argo_st="临时隧道：$_d"
  fi
  echo "Sing-box节点端口状态如下："
  local item name proto port st
  for item in \
    "Vless-reality|tcp|$PORT_VLESS" \
    "Vmess-ws|tcp|$PORT_VMESS" \
    "Hysteria-2|udp|$PORT_HY2" \
    "Tuic-v5|udp|$PORT_TUIC" \
    "Anytls|tcp|$PORT_ANYTLS"; do
    name="${item%%|*}"; proto="${item#*|}"; proto="${proto%%|*}"; port="${item##*|}"
    if port_listening "$proto" "$port"; then st="监听中"; else st="未监听"; fi
    if [[ "$name" == "Vmess-ws" ]]; then
      printf '🚀【 %-13s 】端口:%-5s  状态:%s  Argo:%s\n' "$name" "$port" "$st" "$argo_st"
    else
      printf '🚀【 %-13s 】端口:%-5s  状态:%s\n' "$name" "$port" "$st"
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    echo "Sing-box状态：$(systemctl is-active sing-box 2>/dev/null || echo '未知')"
  fi
}

show_menu() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "[错误] 请以 root 运行，例如：sudo bash $0 menu"
    exit 1
  fi
  load_env_or_exit
  while true; do
    echo
    echo "================ sing-box 管理菜单 ================"
    show_port_status
    echo
    echo "1. 更换 UUID（全协议）"
    echo "2. 更新 Reality 密钥对"
    echo "3. 更新自签证书"
    echo "4. Argo 隧道管理"
    echo "5. 更换端口"
    echo "6. 查看节点链接"
    echo "7. 重启 sing-box 服务"
    echo "8. 卸载"
    echo "9. 更新脚本到最新版"
    echo "0. 退出"
    echo "==================================================="
    read -rp "请选择 [0-9]: " choice
    case "$choice" in
      1) do_change_uuid ;;
      2) do_change_reality ;;
      3) do_change_cert ;;
      4) do_argo_menu ;;
      5) do_change_ports ;;
      6) load_env_or_exit; print_links ;;
      7) load_env_or_exit; setup_service; echo "[完成] 服务已重启" ;;
      8) do_uninstall; break ;;
      9) if do_update_script; then exec /usr/local/bin/sbox menu; fi ;;
      0) echo "退出"; break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}


#----------------------------- 主流程 ----------------------------------------
case "$ACTION" in
  install)
    detect_os
    detect_arch
    check_memory
    install_deps
    disable_dnf_makecache
    install_singbox
    setup_shortcut
    gen_certs
    load_or_gen_identity
    write_config
    open_firewall
    fix_selinux
    setup_service
    start_argo
    print_links
    echo
    echo "[完成] 6 种协议已就绪，链接见上 / $LINKS_FILE"
    ;;
  uninstall)
    do_uninstall
    ;;
  menu)
    show_menu
    ;;
  change-uuid)
    do_change_uuid
    ;;
  change-reality)
    do_change_reality
    ;;
  change-cert)
    do_change_cert
    ;;
  change-argo)
    do_argo_menu
    ;;
  change-ports)
    do_change_ports
    ;;
  show-links)
    load_env_or_exit; print_links
    ;;
  restart)
    load_env_or_exit; setup_service; echo "[完成] 服务已重启"
    ;;
  update-script)
    do_update_script
    ;;
  *)
    echo "用法：$0 [install|uninstall|menu|change-uuid|change-reality|change-cert|change-argo|change-ports|show-links|restart|update-script]"
    exit 1
    ;;
esac
