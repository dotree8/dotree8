VLESS Reality 全自动一键安装脚本
适用于：
Ubuntu 20.04 / 22.04 / 24.04
干净 IP，无需域名
国内三网友好（移动/联通/电信）
特点：
全自动安装 Xray VLESS + Reality
自动生成 shortId（隐蔽性更强）
自动开启 BBR3
自动 sysctl 内核网络优化
自动设置最佳 MTU
自动 UFW 防火墙
无需任何手动交互
可直接复制运行
一键安装命令
bash <(curl -L https://raw.githubusercontent.com/dotree8/dotree8/main/install.sh)
安装后检查命令
查看服务状态：
systemctl status xray --no-pager
查看配置：
cat /usr/local/etc/xray/config.json
修改 shortId（可选）
nano /usr/local/etc/xray/config.json
systemctl restart xray
