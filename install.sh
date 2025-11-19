#!/usr/bin/env bash
# dotree8 — XRAY VLESS-REALITY 全自动安装脚本（修正版）
# 适用：Ubuntu 20.04 / 22.04 / 24.04
# 说明：本脚本为“无交互全自动”版，运行前建议先在 VPS 做快照
# 版本：v1.1 (修正版：增加校验/备份/jq/json 安全修改/网卡自动识别)
set -euo pipefail
IFS=$'\n\t'

LOG_PREFIX="[dotree8]"

echo "$LOG_PREFIX 启动脚本..."

# ---------------------------
# 简单工具函数
# ---------------------------
timestamp() { date +%F_%H%M%S; }

fail_exit() {
    echo "$LOG_PREFIX 错误：$1"
    exit 1
}

# ---------------------------
# 1) root 检查
# ---------------------------
if [ "$(id -u)" -ne 0 ]; then
    fail_exit "请以 root 用户运行本脚本（sudo -i），脚本已退出。"
fi

# ---------------------------
# 2) 系统版本检测
# ---------------------------
if [ ! -f /etc/os-release ]; then
    fail_exit "/etc/os-release 不存在，无法判断系统。"
fi
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    fail_exit "本脚本仅支持 Ubuntu，检测到：$ID"
fi
if [[ "$VERSION_ID" != "20.04" && "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
    fail_exit "当前 Ubuntu 版本 $VERSION_ID 未列为支持版本 (20.04/22.04/24.04)。若确认兼容，可手动修改脚本后再运行。"
fi
echo "$LOG_PREFIX 系统检测通过：Ubuntu $VERSION_ID"

# ---------------------------
# 3) 更新并安装基础依赖（无交互）
# ---------------------------
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y curl ca-certificates wget gnupg lsb-release jq iproute2 iputils-ping

# ---------------------------
# 4) 检测主出口网卡（若未检测到，使用 eth0 作为回退）
# ---------------------------
DEV=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
if [ -z "$DEV" ]; then
    DEV="eth0"
    echo "$LOG_PREFIX 未检测到默认网卡，使用回退网卡：$DEV"
else
    echo "$LOG_PREFIX 检测到默认出口网卡：$DEV"
fi

# ---------------------------
# 5) 备份关键文件（如果存在）
# ---------------------------
TS=$(timestamp)
backup_file() {
    local f="$1"
    if [ -f "$f" ]; then
        cp -a "$f" "${f}.bak.$TS"
        echo "$LOG_PREFIX 备份 $f -> ${f}.bak.$TS"
    fi
}
backup_file /etc/sysctl.conf
backup_file /etc/security/limits.conf
backup_file /usr/local/etc/xray/config.json || true

# ---------------------------
# 6) DNS use-vc 设置（谨慎追加）
# ---------------------------
if ! grep -q "options use-vc" /etc/resolv.conf 2>/dev/null; then
    echo "options use-vc" >> /etc/resolv.conf
    echo "$LOG_PREFIX 已追加 options use-vc 到 /etc/resolv.conf"
fi

# ---------------------------
# 7) 安装 Reality（yahuisme 官方脚本）
# ---------------------------
echo "$LOG_PREFIX 正在下载安装并执行 yahuisme 的 Reality 安装脚本..."
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) || fail_exit "yahuisme 安装脚本执行失败"

# 等待服务稳定
sleep 2

# ---------------------------
# 8) 检查 xray 服务是否运行并监听 443
# ---------------------------
if ! systemctl is-active --quiet xray; then
    journalctl -u xray --no-pager -n 80 || true
    fail_exit "xray 服务未启动，请检查安装日志。"
fi
# 检查 443 端口是否被 xray 监听（或已绑定）
if ! ss -ntlp 2>/dev/null | grep -E ':443\b' >/dev/null 2>&1; then
    echo "$LOG_PREFIX 警告：未检测到 443 端口被监听。请检查 xray 是否绑定到 443。继续执行但请注意。"
else
    echo "$LOG_PREFIX 检测到 443 端口已监听。"
fi

# ---------------------------
# 9) 启用 BBR（teddysun 脚本，选择 2）
# ---------------------------
echo "$LOG_PREFIX 启用 BBR..."
bash <(curl -fsSL https://raw.githubusercontent.com/teddysun/across/master/bbr.sh) <<< "2" || echo "$LOG_PREFIX 启用 BBR 可能已存在或脚本返回非零，继续..."

# ---------------------------
# 10) 安装并配置 UFW（谨慎，保留现有规则备份）
# ---------------------------
apt install -y ufw || true
# 备份现有规则（如果有）
ufw status numbered >/dev/null 2>&1 && ufw status verbose > "/root/ufw_status_$TS.txt" || true

# set policy
ufw default deny incoming || true
ufw default allow outgoing || true
# 保留 SSH (22)，HTTPs (443)
ufw allow 22/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true
echo "$LOG_PREFIX UFW 已配置（允许 22 / 443）"

# ---------------------------
# 11) 文件句柄优化（limits.conf）
# ---------------------------
cat > /etc/security/limits.conf <<'EOF'
* soft nofile 512000
* hard nofile 512000
root soft nofile 512000
root hard nofile 512000
EOF
echo "$LOG_PREFIX 已写入 /etc/security/limits.conf"

# ---------------------------
# 12) sysctl 优化（使用标记块，避免重复追加）
# ---------------------------
START_TAG="# >>> dotree8 sysctl start"
END_TAG="# <<< dotree8 sysctl end"
# 移除旧的 dotree8 块（如果存在）
if grep -qF "$START_TAG" /etc/sysctl.conf 2>/dev/null; then
    awk -v s="$START_TAG" -v e="$END_TAG" 'BEGIN{del=0} { if(index($0,s)) {del=1; next} if(index($0,e)) {del=0; next} if(!del) print }' /etc/sysctl.conf > /tmp/sysctl.clean.$TS
    mv /tmp/sysctl.clean.$TS /etc/sysctl.conf
    echo "$LOG_PREFIX 移除旧的 sysctl dotree8 配置块"
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

sysctl -p || echo "$LOG_PREFIX sysctl -p 出现问题，但继续。"

# ---------------------------
# 13) 安装 net-tools (用于 netstat) 并 jq（用于修改 JSON）
# ---------------------------
apt install -y net-tools openssl jq || true

# ---------------------------
# 14) 安全地修改 config.json：生成 shortId（使用 jq）
# ---------------------------
CONFIG="/usr/local/etc/xray/config.json"
if [ ! -f "$CONFIG" ]; then
    echo "$LOG_PREFIX 警告：配置文件 $CONFIG 不存在，跳过 shortId 修改。"
else
    # 备份已在上面完成
    NEW_SID=$(openssl rand -hex 4)
    # 如果 shortIds 存在，替换；否则插入到 root 位置（尽量保证兼容）
    if jq -e '.inbounds[0].streamSettings.reality' "$CONFIG" >/dev/null 2>&1; then
        # 使用 jq 更新 .inbounds[0].streamSettings.reality.shortIds = [NEW_SID]
        TMP=$(mktemp)
        jq --arg sid "$NEW_SID" '( .inbounds ) |= ( . as $arr | ( range(0;($arr|length)) | select( (.[$_] .streamSettings? .reality?) ) ) as $i | .[$i].streamSettings.reality.shortIds = [$sid] )' "$CONFIG" > "$TMP" 2>/dev/null || true
        # fallback: if tmp is empty, try a simpler assignment at top-level reality key
        if [ -s "$TMP" ]; then
            mv "$TMP" "$CONFIG"
            echo "$LOG_PREFIX 已用 jq 写入 shortId: $NEW_SID"
        else
            rm -f "$TMP"
            echo "$LOG_PREFIX jq 更新 shortId 失败，尝试 sed 回退..."
            sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$NEW_SID\"],/g" "$CONFIG" || true
        fi
    else
        # 如果没找到预期的 reality 结构，尝试全局替换或直接告知
        echo "$LOG_PREFIX 未能检测到 standard reality 结构，尝试用 sed 更新 shortIds"
        sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$NEW_SID\"],/g" "$CONFIG" || true
    fi

    systemctl restart xray || echo "$LOG_PREFIX 重启 xray 出现问题，但继续。"
fi

# ---------------------------
# 15) MTU 自动检测（使用检测到的 DEV）
# ---------------------------
echo "$LOG_PREFIX 正在探测最佳 MTU (1200..1500)，请耐心..."
best=0
for mtu in $(seq 1500 -1 1200); do
    if ping -c1 -W1 -s $((mtu - 28)) -M do 8.8.8.8 >/dev/null 2>&1; then
        best=$mtu
        break
    fi
done
if [ "$best" -eq 0 ]; then
    best=1400
    echo "$LOG_PREFIX 未能探测到更高 MTU，使用安全默认：$best"
else
    echo "$LOG_PREFIX 检测到最佳 MTU：$best"
fi
ip link set mtu "$best" dev "$DEV" || echo "$LOG_PREFIX 设置 MTU 失败（请检查网卡名 $DEV）"

# ---------------------------
# 16) 从 config.json 安全提取 UUID / publicKey / serverName (SNI)
# ---------------------------
UUID=""
PUB_KEY=""
SNI=""
if [ -f "$CONFIG" ]; then
    # 尝试使用 jq 提取常见字段（兼容多种 config 布局）
    UUID=$(jq -r '(.inbounds[]?.settings?.clients[]?.id // .inbounds[0].settings.clients[0].id) // empty' "$CONFIG" 2>/dev/null || true)
    PUB_KEY=$(jq -r '(.inbounds[]?.streamSettings?.reality?.publicKey // .inbounds[0].streamSettings.reality.publicKey) // empty' "$CONFIG" 2>/dev/null || true)
    SNI=$(jq -r '(.inbounds[]?.streamSettings?.reality?.serverNames[0] // .inbounds[0].streamSettings.reality.serverNames[0]) // empty' "$CONFIG" 2>/dev/null || true)
fi

# 兼容性回退：用 grep 解析（如果 jq 未能取到）
if [ -z "$UUID" ] && [ -f "$CONFIG" ]; then
    UUID=$(grep -oP '(?<="id":\s*")[^"]+' "$CONFIG" | head -n1 || true)
fi
if [ -z "$PUB_KEY" ] && [ -f "$CONFIG" ]; then
    PUB_KEY=$(grep -oP '(?<="publicKey":\s*")[^"]+' "$CONFIG" | head -n1 || true)
fi
if [ -z "$SNI" ] && [ -f "$CONFIG" ]; then
    SNI=$(grep -oP '(?<="serverNames":\s*\[\s*")[^"]+' "$CONFIG" | head -n1 || true)
fi

# ---------------------------
# 17) 生成 VLESS Reality 链接（尽量填充可用字段）
# ---------------------------
if [ -n "$UUID" ] && [ -n "$PUB_KEY" ] && [ -n "$SNI" ]; then
    LINK="vless://${UUID}@${SNI}:443?encryption=none&security=reality&sni=${SNI}&pbk=${PUB_KEY}&sid=${NEW_SID}&fp=chrome#dotree8"
else
    LINK=""
fi

# ---------------------------
# 18) 输出最终状态与信息
# ---------------------------
echo
echo "============================================"
echo "  dotree8: Reality 安装/优化 完成"
echo "============================================"
echo " 系统: Ubuntu $VERSION_ID"
echo " 默认网卡: $DEV"
echo " MTU: $best"
echo " xray 服务状态: $(systemctl is-active xray || echo 'unknown')"
echo " 443 监听: $(ss -ntlp 2>/dev/null | grep -E ':443\b' >/dev/null && echo '已监听' || echo '未检测到')"
echo
echo " 配置文件: $CONFIG"
echo " 备份时间戳: $TS （如需回滚请使用 .bak.$TS 文件）"
echo
[ -n "$UUID" ] && echo " UUID: $UUID"
[ -n "$PUB_KEY" ] && echo " PublicKey: $PUB_KEY"
[ -n "$NEW_SID" ] && echo " shortId: $NEW_SID"
echo
if [ -n "$LINK" ]; then
    echo " 客户端链接 (复制)："
    echo "$LINK"
else
    echo " 未能自动生成完整的 VLESS-Reality 链接。请打开 $CONFIG 查看 publicKey / id / serverNames 并手动组装。"
fi
echo
echo "============================================"
echo "$LOG_PREFIX 完成。如需帮助请把上述输出贴给我。"
