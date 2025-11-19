#!/bin/bash
# 完全自动安装 Reality（无交互）for Ubuntu 20/22/24
# 版本：v1.0-stable

set -e

echo "========================================"
echo " 🚀 Reality (VLESS-Reality) 自动安装脚本"
echo "    * 自动安装 * 自动优化 * 自动伪装 "
echo "    * Ubuntu 20/22/24 支持 "
echo "    * 作者: dotree8 (本脚本自动生成)"
echo "========================================"
sleep 1

# ---------------------------
# 0. root 权限检查
# ---------------------------
if [ "$(id -u)" != "0" ]; then
    echo "❌ 请输入 root 用户运行：sudo -i"
    exit 1
fi

# ---------------------------
# 1. 系统版本检查
# ---------------------------
. /etc/os-release
if [[ "$VERSION_ID" != "20.04" && "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
    echo "❌ 当前系统为 $VERSION_ID，不在支持范围 (20/22/24)"
    exit 1
fi
echo "✔ 系统版本检测成功：Ubuntu $VERSION_ID"

# ---------------------------
# 2. 检测主网卡（你提供的是 eth0，因此优先使用 eth0）
# ---------------------------
DEV=$(ip route | grep default | awk '{print $5}')
[ -z "$DEV" ] && DEV="eth0"

echo "✔ 检测到网卡：$DEV"

# ---------------------------
# 3. DNS use-vc 修复
# ---------------------------
if ! grep -q "options use-vc" /etc/resolv.conf; then
    echo "options use-vc" >> /etc/resolv.conf
fi
echo "✔ DNS use-vc 已设置"

# ---------------------------
# 4. 安装 Reality（官方 yahuisme）
# ---------------------------
echo "🚀 正在安装 Reality..."
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh)

sleep 1

# ---------------------------
# 5. 检查安装是否成功
# ---------------------------
if ! systemctl is-active --quiet xray; then
    echo "❌ Xray 未能成功启动，请检查错误"
    exit 1
fi

echo "✔ Reality 安装成功"

CONFIG="/usr/local/etc/xray/config.json"

# 自动提取 UUID、公钥、shortId
UUID=$(grep -oP '(?<="id": ")[^"]+' $CONFIG | head -n1)
PUB_KEY=$(grep -oP '(?<="publicKey": ")[^"]+' $CONFIG)
SNI=$(grep -oP '(?<="serverNames": \[")[^"]+' $CONFIG)

# ---------------------------
# 6. 启用 BBR3（teddysun 官方脚本）
# ---------------------------
echo "🚀 正在启用 BBR3..."
bash <(curl -L -s https://raw.githubusercontent.com/teddysun/across/master/bbr.sh) <<< "2"

echo "✔ BBR3 已启用"

# ---------------------------
# 7. 防火墙配置
# ---------------------------
echo "🚀 配置 UFW 防火墙..."
apt update -y
apt install -y ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable

echo "✔ 防火墙已配置（仅开放 22 / 443）"

# ---------------------------
# 8. 系统文件数优化
# ---------------------------
cat << EOF >/etc/security/limits.conf
* soft nofile 512000
* hard nofile 512000
root soft nofile 512000
root hard nofile 512000
EOF

echo "fs.file-max = 1024000" >> /etc/sysctl.conf

echo "✔ 文件句柄限制已优化"

# ---------------------------
# 9. sysctl 网络优化（Reality 最佳参数）
# ---------------------------
cat << 'EOF' >> /etc/sysctl.conf

# --------- Reality 最优参数 ----------
fs.file-max = 1024000
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.tcp_rmem=4096 87380 6291456
net.ipv4.tcp_wmem=4096 65536 6291456
net.ipv4.tcp_fastopen = 3
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
# --------------------------------------
EOF

sysctl -p

echo "✔ sysctl 优化已完成"

# ---------------------------
# 10. 自动生成新的 shortId
# ---------------------------
SHORTID=$(openssl rand -hex 4)

sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$SHORTID\"],/g" $CONFIG
systemctl restart xray

echo "✔ 新 shortId 已应用：$SHORTID"

# ---------------------------
# 11. 自动检测最佳 MTU
# ---------------------------
echo "📡 正在自动检测最佳 MTU..."

best=0
for mtu in $(seq 1500 -1 1200); do
    if ping -c1 -W1 -s $((mtu - 28)) -M do 8.8.8.8 >/dev/null 2>&1; then
        best=$mtu
        break
    fi
done

if [ "$best" -eq 0 ]; then
    best=1400
fi

ip link set mtu $best dev "$DEV"

echo "✔ 最佳 MTU 已应用：$best"

# ---------------------------
# 12. 生成 VLESS Reality 链接
# ---------------------------
DOMAIN=$SNI
PORT=443

LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB_KEY&sid=$SHORTID&type=tcp&flow=xtls-rprx-vision#Reality-auto"

# ---------------------------
# 13. 最终输出
# ---------------------------
clear
echo "============================================="
echo "   🎉 Reality 安装成功（全自动模式）"
echo "============================================="
echo ""
echo "🔑 UUID:        $UUID"
echo "🔐 PublicKey:   $PUB_KEY"
echo "🆔 shortId:     $SHORTID"
echo "🌐 伪装域名:     $DOMAIN"
echo "🔧 MTU:          $best"
echo ""
echo "📎 客户端链接："
echo "$LINK"
echo ""
echo "============================================="
echo "你现在可以复制上面的 VLESS 节点使用。"
echo "============================================="
