📘 **Reality 一键安装脚本 - README**

---

````markdown
<div align="center">

# 🌈 Xray VLESS-Reality 一键安装脚本  
### 高稳定性 · 自动优化 · 自动检测 MTU · 自动生成订阅链接

</div>

---

## 🚀 功能特点

这个一键脚本用于在 **Ubuntu 服务器上快速部署 Xray VLESS-Reality**，支持完整优化与自动修复，包括：

### ✔ 自动安装最新 Xray（Reality）  
### ✔ 自动开启 BBR/BBR2 + fq  
### ✔ 自动修复 DNS use-vc 问题  
### ✔ 自动优化 sysctl 内核参数  
### ✔ 自动设置文件句柄（limits.conf）  
### ✔ 自动检测网络 MTU（1200–1500）  
### ✔ 自动生成 shortId（Reality 必需）  
### ✔ 自动从 config.json 中提取：  
- UUID  
- Public Key (pbk)  
- ServerName / SNI  
- shortId  
- 端口  
### ✔ 自动生成 vless:// 订阅链接（可直接用于客户端）  
### ✔ 自动 UFW 防火墙设置  
### ✔ 全程安全判断 + 错误捕获 + 自动备份配置  

---

## 📦 一键安装命令

**只需执行下面一行命令即可安装完整 Reality：**

```bash
bash <(curl -Ls https://raw.githubusercontent.com/dotree8/dotree8/main/install.sh)
````

脚本会自动完成所有工作，结束后会显示：

* 你的 UUID
* 公钥 pbk
* SNI
* shortId
* 最终 vless:// 链接

你几乎无需任何操作。

---

## 📌 系统支持

| 系统版本            | 支持情况    |
| --------------- | ------- |
| Ubuntu 24.04    | ✅       |
| Ubuntu 22.04    | ✅       |
| Ubuntu 20.04    | ✅       |
| Debian / CentOS | ❌（未来更新） |

---

## 🧩 安装完成后输出示例

安装完脚本后会看到类似：

```
Xray Reality 安装成功！
------------------------------------------
UUID: 123e4567-e89b-12d3-a456-426614174000
Public Key (pbk): b1XUzvGdxxxxxxxxxxxxxxxxxxxxxx
SNI: www.cloudflare.com
shortId: 12345678
端口: 443
------------------------------------------

你的 Reality 节点链接：

vless://UUID@你的IP:443?encryption=none&security=reality&sni=www.cloudflare.com&pbk=公钥&sid=短ID&fp=chrome#dotree8
```

你可以直接复制到客户端使用。

---

## ⚙ 内核优化说明

脚本会自动执行下面优化：

### 内核转发 / TCP 优化

```
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=512000
...
```

### 文件句柄优化

```
* soft nofile 512000
* hard nofile 512000
```

### 自动开启 BBR2

使用 teddysun 官方脚本，稳定安全。

---

## 🔧 防火墙自动设置

脚本会执行：

| 端口          | 说明      |
| ----------- | ------- |
| 22/tcp      | 保留 SSH  |
| 443/tcp     | Reality |
| 所有 outgoing | 允许      |

所有 inbound 除 22、443 均拒绝，确保 VPS 安全。

---

## 📡 Reality 工作原理（简单版）

1. 不暴露真实服务
2. 不可被主动探测识别
3. 443 伪装为 HTTPS
4. 只有带正确 SNI + shortId 的客户端才能连接
5. 真正安全稳固、适合长期使用

---

## 🔧 卸载（未来 v1.3 加入菜单模式）

后续版本会加入：

```
install / uninstall / fix / optimize / status
```

---

## 🆘 常见问题（FAQ）

### ❓ 1. 执行 curl 失败？

请检查服务器是否能访问 GitHub：

```
curl https://www.google.com
curl https://raw.githubusercontent.com
```

---

### ❓ 2. 客户端导入提示错误？

可能是 `SNI` 或 `shortId` 写错。
脚本已自动提取，你可以重新执行：

```
cat /usr/local/etc/xray/config.json
```

---

### ❓ 3. Xray 没在监听 443？

```
ss -tlnp | grep 443
systemctl status xray
journalctl -u xray --no-pager
```

---

## 📝 更新日志

### v1.2（当前版本）

* 完整自动化 Reality 安装
* 自动提取配置（UUID/SNI/PBK）
* 自动生成短 ID
* 完整内核优化
* 自动检测 MTU
* 自动修复 use-vc
* 防火墙自动配置
* 错误捕获 + 日志系统

---

## ❤️ 开源说明

本脚本基于 Xray、Reality、Linux 内核优化相关项目实现。
你可以自由修改、分发、商用。

欢迎 Star ⭐！

👉 [https://github.com/dotree8/dotree8](https://github.com/dotree8/dotree8)

```
