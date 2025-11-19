#!/bin/bash
# ================================
#  XRAY VLESS-REALITY 一键脚本
#  Author: dotree8 (Optimized by ChatGPT)
#  System: Ubuntu 20/22/24
# ================================

set -e

echo "==============================="
echo "   VLESS-Reality 一键安装脚本"
echo "==============================="

# -------------------------------
# 0. DNS use-vc
# -------------------------------
echo "[1/10] 设置 DNS use-vc..."
grep -q "options use-vc" /etc/resolv.conf || echo "options use-vc" | sudo tee -a /etc/resolv.conf > /dev/null

# -------------------------------
# 1. 安装 Reality（yahuisme 官方）
# -------------------------------
echo "[2/10] 安装 XRAY Reality..."
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh)

# -------------------------------
# 2. 启用 BBR3
# -------------------------------
echo "[3/10] 启用 BBR3..."
bash <(curl -L -s https://raw.githubusercontent.com/teddysun/across/master/bbr.sh) <<< "2"

# -------------------------------
# 3. 安装 net-tools
# -------------------------------
echo "[4/10] 安装 net-tools..."
apt install -y net-tools

# -------------------------------
# 4. 防火墙 UFW
# -------------------------------
echo "[5/10] 配置 UFW..."
apt update -y
apt install -y ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable

# -------------------------------
# 5. 文件句柄优化
# -------------------------------
echo "[6/10] 优化文件句柄..."
cat << EOF | sudo tee /etc/security/limits.conf >/dev/null
* soft nofile 512000
* hard nofile 512000
root soft nofile 512000
root hard nofile 512000
EOF

echo "fs.file-max = 1024000" | sudo tee -a /etc/sysctl.conf >/dev/null

# -------------------------------
# 6. sysctl 内核优化
# -------------------------------
echo "[7/10] 应用 sysctl 网络优化..."

cat << 'EOF' | sudo tee -a /etc/sysctl.conf >/dev/null

# ========== Reality 网络最优参数 ==========
fs.file-max = 1024000

# BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# TCP 内核优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

# TCP Buffer
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.tcp_rmem=4096 87380 6291456
net.ipv4.tcp_wmem=4096 65536 6291456

# Fastopen
net.ipv4.tcp_fastopen = 3

# IPv6 不禁用，只关闭 RA
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

EOF

sudo sysctl -p

# -------------------------------
# 7. 自动生成 shortId
# -------------------------------
echo "[8/10] 自动生成 shortId..."

SHORTID=$(openssl rand -hex 4)
CONFIG="/usr/local/etc/xray/config.json"

sed -i "s/\"shortIds\": \[.*/\"shortIds\": [\"$SHORTID\"],/g" $CONFIG

systemctl restart xray

echo "新 shortId: $SHORTID"

# -------------------------------
# 8. Reality 回源检测
# -------------------------------
echo "[9/10] 检查伪装回源..."

curl -I https://learn.microsoft.com -m 5 || true

# -------------------------------
# 9. 自动 MTU 检测
# -------------------------------
echo "[10/10] 自动检测最佳 MTU..."

best=0
for mtu in $(seq 1500 -1 1200); do
    if ping -c1 -W1 -s $((mtu - 28)) -M do 8.8.8.8 >/dev/null 2>&1; then
        best=$mtu
        break
    fi
done

if [ "$best" -ne 0 ]; then
    echo "最佳 MTU = $best"
    ip link set mtu $best dev eth0 || true
fi

# -------------------------------
# 完成
# -------------------------------
echo "======================================="
echo " 🎉 VLESS-Reality 安装 + 优化 完成！"
echo "======================================="
echo "shortId：$SHORTID"
echo "MTU：$best"
echo ""
echo "建议执行："
echo "systemctl status xray --no-pager"
echo "======================================="
