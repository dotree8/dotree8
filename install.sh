#!/usr/bin/env bash
# dotree8 — XRAY VLESS-REALITY 一键安装与优化脚本 v1.2
# 说明: 完全自动 / 无交互 / 适配 Ubuntu 20.04, 22.04, 24.04
# 建议: 运行前为 VPS 做快照 (snapshot)
set -euo pipefail
IFS=$'\n\t'

LOG_PREFIX="[dotree8:v1.2]"

timestamp(){ date +%F_%H%M%S; }

# 错误退出
fail_exit(){
  echo "$LOG_PREFIX 错误: $1"
  exit 1
}

# 日志信息
info(){ echo "$LOG_PREFIX $*"; }

# trap - 在错误时输出最后 100 行日志便于排查
trap 'echo "$LOG_PREFIX 脚本意外退出，最后 80 行 xray 日志："; journalctl -u xray -n 80 --no-pager || true' ERR

# 1) 必须以 root 运行
if [ "$(id -u)" -ne 0 ]; then
  fail_exit "请以 root 用户运行本脚本 (sudo -i)"
fi

# 2) 检查 /etc/os-release
if [ ! -f /etc/os-release ]; then
  fail_exit "/etc/os-release 不存在，无法判断系统"
fi
. /etc/os-release
if [ "$ID" != "ubuntu" ]; then
  fail_exit "本脚本仅支持 Ubuntu，检测到: $ID"
fi
if [[ "$VERSION_ID" != "20.04" && "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
  fail_exit "当前 Ubuntu 版本 $VERSION_ID 未在支持列表 (20.04/22.04/24.04) 中"
fi
info "系统检测通过: Ubuntu $VERSION_ID"

# 3) 基础依赖 (noninteractive)
export DEBIAN_FRONTEND=noninteractive
info "apt update && 安装基础依赖 (curl jq openssl iproute2 iputils-ping)..."
apt update -y
apt install -y curl ca-certificates wget gnupg lsb-release jq openssl iproute2 iputils-ping net-tools || true

# 4) 检测默认出口网卡 (回退 eth0)
DEV=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || true)
if [ -z "$DEV" ]; then
  DEV="eth0"
  info "未检测到默认网卡，使用回退: $DEV"
else
  info "检测到默认网卡: $DEV"
fi

TS=$(timestamp)

# 5) 备份关键文件（存在则备份）
backup_if_exists(){
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bak.$TS"
    info "备份 $f -> ${f}.bak.$TS"
  fi
}
backup_if_exists /etc/sysctl.conf
backup_if_exists /etc/security/limits.conf
backup_if_exists /usr/local/etc/xray/config.json

# 6) DNS 修复 options use-vc（避免 DNS UDP 问题）
if ! grep -q "options use-vc" /etc/resolv.conf 2>/dev/null; then
  echo "options use-vc" >> /etc/resolv.conf
  info "已追加 options use-vc 到 /etc/resolv.conf"
fi

# 7) 下载并执行 yahuisme 的 Reality 安装脚本（官方常用）
info "下载并执行 yahuisme xray-vless-reality 安装脚本..."
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) || fail_exit "yahuisme 安装脚本失败"

sleep 2

# 8) 确认 xray 已启动
if ! systemctl is-active --quiet xray; then
  info "xray 未处于 active 状态，显示 journal 最后 120 行供排查："
  journalctl -u xray -n 120 --no-pager || true
  fail_exit "xray 未成功启动"
fi
info "xray 服务已启动"

# 检查 443 是否被监听
if ss -ntlp 2>/dev/null | grep -E ':443\b' >/dev/null 2>&1; then
  info "检测到 443 端口已监听"
else
  info "警告: 未检测到 443 端口被监听，伪装/回源可能失败，请检查 xray 配置"
fi

# 9) 启用 BBR (teddysun 脚本，选项 2)
info "启用 BBR (teddysun脚本) ..."
bash <(curl -fsSL https://raw.githubusercontent.com/teddysun/across/master/bbr.sh) <<< "2" || info "启用 BBR 脚本返回非 0，但继续"

# 10) 配置 UFW（保留备份）
info "安装并配置 UFW..."
apt install -y ufw || true
ufw status verbose > "/root/ufw_status_$TS.txt" 2>/dev/null || true
ufw default deny incoming || true
ufw default allow outgoing || true
ufw allow 22/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true
info "UFW 已配置 (允许 22,443)"

# 11) 文件句柄优化 limits.conf（覆盖写入）
cat > /etc/security/limits.conf <<'EOF'
* soft nofile 512000
* hard nofile 512000
root soft nofile 512000
root hard nofile 512000
EOF
info "已写入 /etc/security/limits.conf"

# 12) sysctl 优化：使用标记块，避免重复追加
START_TAG="# >>> dotree8 sysctl start"
END_TAG="# <<< dotree8 sysctl end"

# 删除旧块（如果存在）
if grep -qF "$START_TAG" /etc/sysctl.conf 2>/dev/null; then
  awk -v s="$START_TAG" -v e="$END_TAG" 'BEGIN{del=0} { if(index($0,s)) {del=1; next} if(index($0,e)) {del=0; next} if(!del) print }' /etc/sysctl.conf > /tmp/sysctl.clean.$$ && mv /tmp/sysctl.clean.$$ /etc/sysctl.conf
  info "移除旧的 dotree8 sysctl 块"
fi

cat >> /etc/sysctl.conf <<'EOF'

# >>> dotree8 sysctl start
fs.file-max = 1024000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.ipv4.tcp_rmem = 4096 87380 6291456
net.ipv4.tcp_wmem = 4096 65536 6291456
net.ipv4.tcp_fastopen = 3
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
# <<< dotree8 sysctl end

EOF

sysctl -p || info "sysctl -p 报错，但继续执行"

# 13) 安装 openssl jq net-tools（如果缺失）
apt install -y openssl jq net-tools || true

# 14) 安全修改 xray config.json 的 shortIds（使用 jq；兼容多 inbound）
CONFIG="/usr/local/etc/xray/config.json"
if [ ! -f "$CONFIG" ]; then
  info "配置文件 $CONFIG 不存在，跳过 shortId 更新"
else
  NEW_SID=$(openssl rand -hex 4)
  info "准备写入 shortId: $NEW_SID"

  TMPFILE=$(mktemp)
  # 对每个包含 streamSettings.reality 的 inbound 节点，设置 shortIds
  if jq -e '.[].streamSettings? | select(.reality != null)' "$CONFIG" >/dev/null 2>&1; then
    if jq --arg sid "$NEW_SID" '(.inbounds[] | select(.streamSettings?.reality?) ) |= (.streamSettings.reality.shortIds = [$sid])' "$CONFIG" > "$TMPFILE" 2>/dev/null; then
      mv "$TMPFILE" "$CONFIG"
      info "jq 已写入 shortId: $NEW_SID"
    else
      rm -f "$TMPFILE"
      info "jq 更新 shortId 失败，尝试 sed 回退方式"
      sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$NEW_SID\"],/g" "$CONFIG" || info "sed 替换 shortIds 也失败"
    fi
  else
    # config 中没有 streamSettings.reality 结构（非标准或布局不同），尝试用 sed 替换
    sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$NEW_SID\"],/g" "$CONFIG" || info "未能设置 shortIds（config 布局异常）"
  fi

  # 重启 xray 以应用 shortId
  if systemctl restart xray; then
    info "xray 已重启，shortId 可能已生效"
  else
    info "重启 xray 失败，请手动检查 xray 状态"
  fi
fi

# 15) 自动探测 MTU（1200..1500），使用检测到的网卡 DEV
info "开始自动检测最佳 MTU (1200..1500) ..."
best=0
for mtu in $(seq 1500 -1 1200); do
  if ping -c1 -W1 -s $((mtu - 28)) -M do 8.8.8.8 >/dev/null 2>&1; then
    best=$mtu
    break
  fi
done
if [ "$best" -eq 0 ]; then
  best=1400
  info "未探测到更高 MTU，使用默认安全值 $best"
else
  info "检测到最佳 MTU: $best"
fi

if ip link set mtu "$best" dev "$DEV" 2>/dev/null; then
  info "已将 $DEV 的 MTU 设置为 $best"
else
  info "设置 MTU 失败 (设备 $DEV)，请手动检查"
fi

# 16) 提取 UUID / publicKey / serverName (兼容 serverName 或 serverNames)
UUID=""
PUB_KEY=""
SNI=""

if [ -f "$CONFIG" ]; then
  # 尝试使用 jq 提取
  UUID=$(jq -r '(.inbounds[]?.settings?.clients[]?.id // .inbounds[0].settings.clients[0].id) // empty' "$CONFIG" 2>/dev/null || true)
  PUB_KEY=$(jq -r '(.inbounds[]?.streamSettings?.reality?.publicKey // .inbounds[0].streamSettings.reality.publicKey) // empty' "$CONFIG" 2>/dev/null || true)

  # 兼容 serverNames (数组) 或 serverName (字符串)
  SNI=$(jq -r '(.inbounds[]?.streamSettings?.reality?.serverNames[0] // .inbounds[]?.streamSettings?.reality?.serverName // .inbounds[0].streamSettings.reality.serverNames[0] // .inbounds[0].streamSettings.reality.serverName) // empty' "$CONFIG" 2>/dev/null || true)
fi

# 回退 grep 提取（以防 jq 未能覆盖）
if [ -z "$UUID" ] && [ -f "$CONFIG" ]; then
  UUID=$(grep -oP '(?<="id":\s*")[^"]+' "$CONFIG" | head -n1 || true)
fi
if [ -z "$PUB_KEY" ] && [ -f "$CONFIG" ]; then
  PUB_KEY=$(grep -oP '(?<="publicKey":\s*")[^"]+' "$CONFIG" | head -n1 || true)
fi
if [ -z "$SNI" ] && [ -f "$CONFIG" ]; then
  SNI=$(grep -oP '(?<="serverName":\s*")[^"]+' "$CONFIG" | head -n1 || true)
  if [ -z "$SNI" ]; then
    SNI=$(grep -oP '(?<="serverNames":\s*\[\s*")[^"]+' "$CONFIG" | head -n1 || true)
  fi
fi

# 17) 生成 VLESS-Reality 链接 (尽量填充 pbk, sid, sni)
if [ -n "$UUID" ] && [ -n "$PUB_KEY" ] && [ -n "$SNI" ]; then
  VLESS_LINK="vless://${UUID}@${SNI}:443?encryption=none&security=reality&sni=${SNI}&pbk=${PUB_KEY}&sid=${NEW_SID}&fp=chrome#dotree8"
else
  VLESS_LINK=""
fi

# 18) 最终输出
echo
echo "============================================"
echo " dotree8: Reality 安装/优化 完成 (v1.2)"
echo "============================================"
echo " 系统: Ubuntu $VERSION_ID"
echo " 默认网卡: $DEV"
echo " MTU: $best"
echo " xray 服务: $(systemctl is-active xray || echo 'unknown')"
echo " 443 监听: $(ss -ntlp 2>/dev/null | grep -E ':443\b' >/dev/null && echo '已监听' || echo '未检测到')"
echo
echo " 配置文件: $CONFIG"
echo " 备份时间戳: $TS （如需回滚请使用 .bak.$TS 文件）"
echo
[ -n "$UUID" ] && echo " UUID: $UUID"
[ -n "$PUB_KEY" ] && echo " PublicKey: $PUB_KEY"
[ -n "$NEW_SID" ] && echo " shortId: $NEW_SID"
echo
if [ -n "$VLESS_LINK" ]; then
  echo " 客户端链接 (复制)："
  echo "$VLESS_LINK"
else
  echo " 未能自动生成完整 VLESS-Reality 链接。请打开 $CONFIG 手动查看 publicKey / id / serverNames 并组装。"
fi
echo
echo "============================================"
info "完成。如需帮助请把上述输出贴给我。"
