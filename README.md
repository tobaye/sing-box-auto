# sing-box-auto

sing-box 一键安装脚本，**全程零交互**，复制一条命令即可装好。参考互联网上
知名的相关 sing-box 一键脚本，去掉了所有交互式提问（端口、证书、内核版本、
防火墙确认等），全部用合理默认值或自动生成的值代替。

## 两个版本（二选一）

| | `sing-box-auto.sh`（全自动版） | `sing-box-vless.sh`（精简版） |
|---|---|---|
| 用途 | 一次装好全部 6 种协议 | 只装 VLESS + Reality，最省心 |
| 协议 | VLESS+Reality、VMess+WS、VMess+Argo、Hysteria2、TUIC、AnyTLS | VLESS+Reality |
| 适合 | 想多条线路备用 | 只要一个能用的节点 |

## 一键安装

```bash
# 全自动版（6 协议）
curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-auto.sh | sudo bash

# 精简版（仅 VLESS + Reality）
curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-vless.sh | sudo bash
```

要求：Linux 服务器（Debian / Ubuntu / CentOS / Oracle Linux 等），**root 权限**，
x86_64 / arm64 / armv7 架构。

## 端口（随机分配）

新装时 5 个协议的端口在 **10000–60000** 范围内随机分配，互不冲突，自动避开已占用的端口。
多台服务器各跑一次，端口各不相同。重复运行脚本不会改变已有端口（幂等）。

| 协议 | 传输 | 说明 |
|---|---|---|
| VLESS + Reality | TCP | 随机端口 |
| VMess + WS | TCP | 随机端口 |
| VMess + Argo | 经 Cloudflare 隧道，无需本机端口 | 临时域名，重启后会变 |
| Hysteria2 | UDP | 随机端口 |
| TUIC v5 | UDP | 随机端口 |
| AnyTLS | TCP | 随机端口，需要较新 sing-box 内核（脚本自动装最新版） |

想固定端口：装完后用管理菜单 5（更换端口）手动指定。

## 安装后

- 终端会直接打印全部客户端链接（`vless://`、`vmess://`、`hysteria2://`、
  `tuic://`、`anytls://`），复制到客户端即可使用。
- 链接同时保存到 **`/root/singbox-links.txt`**，随时 `cat` 查看。
- UUID、Reality 密钥对、端口保存在 `/etc/s-box/auto.env`，配置文件在
  `/etc/s-box/sb.json`，服务名为 `sing-box`（systemd）。

## 自动化说明

同类脚本常见的交互点及本脚本的处理：

| 常见交互 | 本脚本做法 |
|---|---|
| 是否关闭防火墙（默认是） | 直接执行：停 firewalld / ufw，iptables 全放行 |
| 内核版本选择（默认最新正式版） | 直接装最新正式版（支持 AnyTLS） |
| 证书选择（默认自签） | 自动生成 `www.bing.com` 自签证书，不申请 Acme |
| 端口设置（默认随机） | 新装时 10000–60000 随机分配，互不冲突 |
| UUID / Reality 密钥 | `sing-box generate` 自动生成 |
| 双栈 VPS 选 IPv4/IPv6 输出（默认 IPv4） | 优先 IPv4 |
| Argo 隧道 | 自动尝试 cloudflared **临时隧道**（无需授权）；失败则跳过，不阻塞安装 |

另外精简掉了同类脚本常见的 Warp 分流、订阅、Telegram 推送等附加功能，只保留核心代理能力。

## 管理菜单与快捷命令

全自动版安装时会自动装好 `sbox` 快捷命令，之后管理不需要再下载脚本：

```bash
sbox            # 进入管理菜单（opc 下打会自动 sudo 提权）
sbox <动作>     # 直接执行：change-uuid | change-reality | change-cert
                #   | change-argo | change-ports | show-links | restart | uninstall
```

管理菜单（`sbox`）：更换 UUID、更新 Reality 密钥对、更新自签证书、
Argo 隧道管理、更换端口、查看节点链接、重启服务、卸载、更新脚本到最新版。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/tobaye/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- uninstall
```

（精简版把 URL 换成 `sing-box-vless.sh` 即可。）

## 注意事项

1. **两个版本二选一**，不要在同一台机器上混装——后装的会覆盖 `/etc/s-box/sb.json`。
   共用 `/etc/s-box/auto.env`，切换版本时 UUID 和 VLESS 端口保持不变，旧链接继续有效。
2. **Oracle Cloud / 其他云厂商**：脚本只放行系统防火墙，云控制台的安全组/安全列表
   里也需要放行对应端口，否则外网连不上。
3. 重复运行脚本是**幂等**的：保留 UUID、端口、密钥，只重写配置并重启服务。
   之前跑过互联网上知名同类脚本的机器，首次运行会自动导入原有 UUID/端口/密钥。
4. Argo 是**临时隧道**，域名每次启动都可能变化，且重启服务器后需等待约 15 秒
   重建；对稳定性要求高请以 VLESS + Reality 为主力。
5. 自签证书的客户端（Hysteria2/TUIC/AnyTLS/VMess-WS）已在链接里带好
   `insecure=1` 或 `pinSHA256` 参数，导入即用，无需手动信任证书。
6. **纯 IPv6 服务器**可用：sing-box 监听 `::` 双栈，防火墙自动放行 ip6tables，
   客户端链接里的 IPv6 地址会自动加方括号。注意客户端那边也得有 IPv6 网络才能连上。
