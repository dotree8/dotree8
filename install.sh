#!/usr/bin/env bash
# dotree8 — XRAY VLESS-REALITY 一键安装与优化脚本 v1.3
# 说明: 完全自动 / 无交互 / 适配 Ubuntu 20.04, 22.04, 24.04
# 建议: 运行前为 VPS 做快照 (snapshot)
set -euo pipefail
IFS=$'\n\t'

LOG_PREFIX="[dotree8:v1.3]"
timestamp(){ date +%F_%H%M%S; }
TS=$(timestamp)

# -------------------------
# 可配置项（按需修改）
# -------------------------
AUTO_APPLY_MTU=false        # true = 自动设置 MTU（有断线风险），false = 只输出建议
ENABLE_BBR=true             # true = 尝试通过 teddysun 脚本启用 BBR（可能重启/重载网络）
BBR_OPTION=2                # teddysun 脚本选项（2 为仅启用 bbr，不强制重启）
GENERATE_QR=false           # true = 生成 VLESS 链接的 QR（需要 qrencode）
SHORTID_COUNT=5             # 生成 shortIds 数量（>=1）
# -------------------------

info(){ echo -e "$LOG_PREFIX $*"; }
fail_exit(){
  echo "$LOG_PREFIX 错误: $1"
  exit 1
}

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

export DEBIAN_FRONTEND=noninteractive

# 3) 安装基础依赖（包可能已经存在）
info "apt update && 安装基础依赖 (curl jq openssl iproute2 iputils-ping net-tools)..."
apt update -y
apt install -y curl ca-certificates wget gnupg lsb-release jq openssl iproute2 iputils-ping net-tools ufw || true

# 4) 检测默认出口网卡 (回退 eth0)
DEV=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || true)
if [ -z "$DEV" ]; then
  DEV="eth0"
  info "未检测到默认网卡，使用回退: $DEV"
else
  info "检测到默认网卡: $DEV"
fi

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
backup_if_exists /etc/systemd/resolved.conf
backup_if_exists /etc/resolv.conf

# 6) DNS: 优先使用 systemd-resolved 配置（更持久）
if systemctl is-enabled --quiet systemd-resolved 2>/dev/null || [ -f /etc/systemd/resolved.conf ]; then
  info "配置 systemd-resolved（如果启用）以避免直接修改 /etc/resolv.conf..."
  if [ -f /etc/systemd/resolved.conf ]; then
    # 保留已有内容为备份（已备份上面）
    # 只追加一行 options use-vc 到 /etc/systemd/resolved.conf 的 DNSStubListener 相关位置并重启
    if ! grep -q "DNS=" /etc/systemd/resolved.conf 2>/dev/null; then
      sed -i "s/#DNS=/DNS=/g" /etc/systemd/resolved.conf || true
    fi
    # 不强行改动 DNS IP，主要确保 resolver 使用 TCP 时 option 可用（use-vc 实际影响有限）
    # systemd-resolved 不使用 options use-vc；为兼容性，仅在 /etc/resolv.conf 非 symlink 时才追加
    if [ ! -L /etc/resolv.conf ]; then
      if ! grep -q "options use-vc" /etc/resolv.conf 2>/dev/null; then
        echo "options use-vc" >> /etc/resolv.conf || true
        info "已在 /etc/resolv.conf 中追加 options use-vc（文件非 symlink）"
      fi
    else
      info "/etc/resolv.conf 为 symlink（systemd-resolved 管理），已跳过直接写入"
    fi
    systemctl restart systemd-resolved || info "systemd-resolved restart 返回非 0，但继续"
  fi
else
  info "systemd-resolved 未启用，若 /etc/resolv.conf 非 symlink 将追加 options use-vc"
  if [ ! -L /etc/resolv.conf ]; then
    if ! grep -q "options use-vc" /etc/resolv.conf 2>/dev/null; then
      echo "options use-vc" >> /etc/resolv.conf || true
      info "已追加 options use-vc 到 /etc/resolv.conf"
    fi
  else
    info "/etc/resolv.conf 为 symlink，跳过修改"
  fi
fi

# 7) 下载并执行 yahuisme 的 Reality 安装脚本（更安全的下载与校验）
YAHUISME_URL="https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh"
info "下载 yahuisme xray-vless-reality 安装脚本到临时文件..."
TMP_SCRIPT="/tmp/yahuisme_install_${TS}.sh"
if curl -fsSL "$YAHUISME_URL" -o "$TMP_SCRIPT"; then
  if [ -s "$TMP_SCRIPT" ]; then
    chmod +x "$TMP_SCRIPT"
    info "脚本下载成功，准备执行：$TMP_SCRIPT"
    # 执行并捕获返回码
    if bash "$TMP_SCRIPT"; then
      info "yahuisme 安装脚本执行完成"
    else
      info "yahuisme 安装脚本执行返回非 0，继续后续步骤以便人工排查"
    fi
  else
    info "下载的脚本为空，跳过执行"
  fi
else
  info "无法下载 yahuisme 脚本，跳过此步骤（请检查网络）"
fi

sleep 2

# 8) 确认 xray 已启动（非致命）
if systemctl is-active --quiet xray; then
  info "xray 服务已启动"
else
  info "xray 未处于 active 状态，输出 journal 最后 120 行供排查："
  journalctl -u xray -n 120 --no-pager || true
  info "继续执行（可能需要你手动修复 xray）"
fi

# 检查 443 是否被监听
if ss -ntlp 2>/dev/null | grep -E ':443\b' >/dev/null 2>&1; then
  info "检测到 443 端口已监听"
else
  info "警告: 未检测到 443 端口被监听，伪装/回源可能失败，请检查 xray 配置"
fi

# 9) 启用 BBR（可选且带提示）
if [ "$ENABLE_BBR" = true ]; then
  info "将尝试运行 teddysun 的 BBR 脚本（注意：此操作可能修改内核参数或触发重启）"
  TEDD_URL="https://raw.githubusercontent.com/teddysun/across/master/bbr.sh"
  TMP_BBR="/tmp/teddysun_bbr_${TS}.sh"
  if curl -fsSL "$TEDD_URL" -o "$TMP_BBR"; then
    chmod +x "$TMP_BBR"
    # 在非交互环境中传入选项（使用 heredoc）
    if bash "$TMP_BBR" <<EOF
$BBR_OPTION
EOF
    then
      info "BBR 脚本执行完成（可能需要重启或后续验证）"
    else
      info "BBR 脚本返回非 0，继续执行脚本其余步骤"
    fi
  else
    info "无法下载 BBR 脚本，跳过"
  fi
else
  info "已禁用 BBR（ENABLE_BBR=false）"
fi

# 10) 安全配置 UFW（在启用前确保 SSH 端口已放行）
info "安装并配置 UFW（会先探测 SSH 端口以避免被锁外）..."
apt install -y ufw || true

# 检测 SSH 端口（优先读取 sshd 配置）
SSH_PORT=""
if [ -f /etc/ssh/sshd_config ]; then
  SSH_PORT=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config | awk '{print $2}' | head -n1 || true)
fi
if [ -z "$SSH_PORT" ]; then
  # fallback 从监听端口探测
  SSH_PORT=$(ss -ntlp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: '{print $NF}' | sort -u | head -n1 || true)
fi
if [ -z "$SSH_PORT" ]; then
  SSH_PORT=22
  info "未能探测到 SSH 端口，默认使用 22"
else
  info "检测到 SSH 端口: $SSH_PORT"
fi

# UFW 配置（先允许 ssh 再启用）
ufw allow "${SSH_PORT}/tcp" || true
ufw allow 443/tcp || true
ufw default deny incoming || true
ufw default allow outgoing || true
ufw --force enable || true
ufw status verbose > "/root/ufw_status_$TS.txt" 2>/dev/null || true
info "UFW 已配置 (允许 SSH:$SSH_PORT,443)"

# 11) 文件句柄优化 limits.conf（覆盖写入）
cat > /etc/security/limits.conf <<'EOF'
* soft nofile 512000
* hard nofile 512000
root soft nofile 512000
root hard nofile 512000
EOF
info "已写入 /etc/security/limits.conf"

# 12) sysctl 优化：使用标记块，避免重复追加，保留关键参数
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
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.ipv4.tcp_rmem = 4096 87380 6291456
net.ipv4.tcp_wmem = 4096 65536 6291456
net.ipv4.ip_local_port_range = 10000 65000
# <<< dotree8 sysctl end

EOF

if sysctl -p >/dev/null 2>&1; then
  info "sysctl 已加载"
else
  info "sysctl -p 返回非 0，继续执行（请手动检查）"
fi

# 13) 再次确保依赖
apt install -y openssl jq net-tools iputils-ping || true

# 14) 安全修改 xray config.json 的 shortIds（使用 jq；兼容多 inbound）
CONFIG="/usr/local/etc/xray/config.json"
NEW_SIDS_JSON=""
if [ -f "$CONFIG" ]; then
  # 生成 shortIds 数组
  gen_shortids(){
    local n=$1
    local arr=()
    for i in $(seq 1 $n); do
      arr+=("$(openssl rand -hex 4)")
    done
    printf '%s\n' "${arr[@]}"
  }
  SIDS=$(gen_shortids "$SHORTID_COUNT")
  # 转为 jq 可用数组文字
  NEW_SIDS_JSON=$(printf '%s\n' $SIDS | jq -R . | jq -s .)

  info "准备写入 shortIds: $NEW_SIDS_JSON 到 $CONFIG"

  TMPFILE=$(mktemp)
  # 如果配置包含 reality 结构则更新
  if jq -e '(.inbounds[]? | select(.streamSettings?.reality?))' "$CONFIG" >/dev/null 2>&1; then
    if jq --argjson sids "$NEW_SIDS_JSON" '(.inbounds[] | select(.streamSettings?.reality?) ) |= (.streamSettings.reality.shortIds = $sids)' "$CONFIG" > "$TMPFILE" 2>/dev/null; then
      mv "$TMPFILE" "$CONFIG"
      info "jq 已写入 shortIds"
    else
      rm -f "$TMPFILE"
      info "jq 更新 shortIds 失败，尝试 sed 回退方式"
      sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$(echo $SIDS | awk '{print $1}')\"],/g" "$CONFIG" || info "sed 替换 shortIds 也失败"
    fi
  else
    info "配置中未检测到 streamSettings.reality 结构，跳过 shortIds 写入"
  fi

  # 重启 xray 以应用 shortId（如果可用）
  if systemctl restart xray; then
    info "xray 已重启，shortIds 可能已生效"
  else
    info "重启 xray 失败，请手动检查 xray 状态"
  fi
else
  info "配置文件 $CONFIG 不存在，跳过 shortId 更新"
fi

# 15) 自动探测 MTU（1200..1500），只给出建议，默认不自动应用
info "开始自动检测最佳 MTU (1200..1500) ..."
best=0
for mtu in $(seq 1500 -1 1200); do
  # 使用 ping 到 8.8.8.8 的简单方法（注意分片）
  if ping -c1 -W1 -s $((mtu - 28)) -M do 8.8.8.8 >/dev/null 2>&1; then
    best=$mtu
    break
  fi
done
if [ "$best" -eq 0 ]; then
  best=1400
  info "未探测到更高 MTU，建议使用安全值 $best"
else
  info "检测到建议 MTU: $best"
fi

if [ "$AUTO_APPLY_MTU" = true ]; then
  info "AUTO_APPLY_MTU=true，准备将 $DEV 的 MTU 设置为 $best（注意：此操作可能导致当前 SSH 中断）"
  if ip link set mtu "$best" dev "$DEV" 2>/dev/null; then
    info "已将 $DEV 的 MTU 设置为 $best"
  else
    info "设置 MTU 失败 (设备 $DEV)，请手动检查"
  fi
else
  info "未自动应用 MTU（AUTO_APPLY_MTU=false）。如需应用，请在云面板或重连后手动运行：ip link set mtu $best dev $DEV"
fi

# 16) 提取 UUID / publicKey / serverName (兼容 serverName 或 serverNames)
UUID=""
PUB_KEY=""
SNI=""
if [ -f "$CONFIG" ]; then
  # 尝试使用 jq 提取
  UUID=$(jq -r 'try (.[].settings.clients[]?.id) catch empty' "$CONFIG" 2>/dev/null | head -n1 || true)
  if [ -z "$UUID" ]; then
    UUID=$(jq -r 'try .inbounds[0].settings.clients[0].id catch empty' "$CONFIG" 2>/dev/null || true)
  fi
  PUB_KEY=$(jq -r 'try (.[].streamSettings.reality.publicKey) catch empty' "$CONFIG" 2>/dev/null | head -n1 || true)
  if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(jq -r 'try .inbounds[0].streamSettings.reality.publicKey catch empty' "$CONFIG" 2>/dev/null || true)
  fi
  # serverName 或 serverNames
  SNI=$(jq -r 'try (.[].streamSettings.reality.serverNames[0]) catch empty' "$CONFIG" 2>/dev/null | head -n1 || true)
  if [ -z "$SNI" ]; then
    SNI=$(jq -r 'try .inbounds[0].streamSettings.reality.serverName catch empty' "$CONFIG" 2>/dev/null || true)
  fi
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
VLESS_LINK=""
if [ -n "$UUID" ] && [ -n "$PUB_KEY" ] && [ -n "$SNI" ]; then
  # 取第一个 short id（如果存在）
  FIRST_SID=""
  if [ -n "$SIDS" ]; then
    FIRST_SID=$(echo "$SIDS" | head -n1)
  fi
  VLESS_LINK="vless://${UUID}@${SNI}:443?encryption=none&security=reality&sni=${SNI}&pbk=${PUB_KEY}&sid=${FIRST_SID}&fp=chrome#dotree8"
fi

# 18) 可选：生成二维码（需要 qrencode）
QR_FILE="/root/dotree8_vless_qr_${TS}.png"
if [ "$GENERATE_QR" = true ] && [ -n "$VLESS_LINK" ]; then
  if ! command -v qrencode >/dev/null 2>&1; then
    info "qrencode 未安装，正在安装..."
    apt install -y qrencode || true
  fi
  if command -v qrencode >/dev/null 2>&1; then
    echo -n "$VLESS_LINK" | qrencode -o "$QR_FILE" -s 6 || info "生成二维码失败"
    if [ -f "$QR_FILE" ]; then
      info "已生成二维码: $QR_FILE"
    fi
  else
    info "qrencode 安装失败，跳过二维码生成"
  fi
fi

# 19) 最终输出
echo
echo "============================================"
echo " dotree8: Reality 安装/优化 完成 (v1.3)"
echo "============================================"
echo " 系统: Ubuntu $VERSION_ID"
echo " 默认网卡: $DEV"
echo " 建议 MTU: $best   (AUTO_APPLY_MTU=$AUTO_APPLY_MTU)"
echo " xray 服务: $(systemctl is-active xray || echo 'unknown')"
echo " 443 监听: $(ss -ntlp 2>/dev/null | grep -E ':443\b' >/dev/null && echo '已监听' || echo '未检测到')"
echo
echo " 配置文件: $CONFIG"
echo " 备份时间戳: $TS （如需回滚请使用 .bak.$TS 文件）"
echo
[ -n "$UUID" ] && echo " UUID: $UUID"
[ -n "$PUB_KEY" ] && echo " PublicKey: $PUB_KEY"
[ -n "$SIDS" ] && echo " shortIds (示例):"
[ -n "$SIDS" ] && echo "$SIDS"
[ -n "$FIRST_SID" ] && echo " first shortId: $FIRST_SID"
echo
if [ -n "$VLESS_LINK" ]; then
  echo " 客户端链接 (复制)："
  echo "$VLESS_LINK"
  if [ -f "$QR_FILE" ]; then
    echo " 二维码文件: $QR_FILE"
  fi
else
  echo " 未能自动生成完整 VLESS-Reality 链接。请打开 $CONFIG 手动查看 publicKey / id / serverNames 并组装。"
fi
echo
echo "============================================"
info "完成。如需进一步定制（自动应用 MTU / 自动启用 BBR / 生成更多 shortIds / 加 QR 等），请修改脚本头部变量并再次运行。"
