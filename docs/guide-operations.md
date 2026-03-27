# OpenClaw 运维手册

本文档涵盖 Azure VM 上 OpenClaw 的日常运维操作，包括服务管理、日志排查、配置变更、升级和常见问题处理。

> **约定**：本文中 `$` 开头的命令在 Ubuntu（SSH）中执行，`>` 开头的命令在 Windows（PowerShell / RDP）中执行。

---

## 目录

1. [服务状态检查](#1-服务状态检查)
2. [重启服务](#2-重启服务)
3. [查看日志](#3-查看日志)
4. [配置管理](#4-配置管理)
5. [升级 OpenClaw](#5-升级-openclaw)
6. [端口与网络排查](#6-端口与网络排查)
7. [Caddy (HTTPS) 排查](#7-caddy-https-排查)
8. [磁盘与资源监控](#8-磁盘与资源监控)
9. [备份与恢复](#9-备份与恢复)
10. [安全巡检](#10-安全巡检)
11. [常见问题速查表](#11-常见问题速查表)

---

## 1. 服务状态检查

### Ubuntu

```bash
# 查看 OpenClaw Gateway 状态
$ sudo systemctl status openclaw

# 输出示例（正常）：
#   Active: active (running) since ...
# 输出示例（异常）：
#   Active: failed (Result: exit-code)

# 检查 OpenClaw 健康状态
$ openclaw doctor
```

### Windows (WSL)

```powershell
# 查看 WSL 是否正在运行
> wsl --list --verbose
# STATE 应为 Running

# 在 WSL 内查看 OpenClaw 服务状态
> wsl -d Ubuntu -- sudo systemctl status openclaw

# 检查 Windows 端口代理是否生效
> netsh interface portproxy show v4tov4
# 应包含 18789 -> WSL IP 的映射

# 检查 OpenClaw 健康
> wsl -d Ubuntu -- openclaw doctor
```

### 本地 macOS (LaunchAgent)

```bash
# 查看 Gateway 进程
$ ps aux | grep openclaw-gateway

# 查看 LaunchAgent 状态
$ launchctl print gui/$(id -u)/ai.openclaw.gateway

# 健康检查
$ openclaw doctor

# 列出已配置的模型
$ openclaw models list
```

---

## 2. 重启服务

### Ubuntu

```bash
# 重启 OpenClaw Gateway
$ sudo systemctl restart openclaw

# 仅停止
$ sudo systemctl stop openclaw

# 仅启动
$ sudo systemctl start openclaw

# 重新加载 systemd 配置（修改 .service 文件后需要执行）
$ sudo systemctl daemon-reload
$ sudo systemctl restart openclaw
```

### Windows (WSL)

```powershell
# 在 WSL 内重启 OpenClaw
> wsl -d Ubuntu -- sudo systemctl restart openclaw

# 如果 WSL 本身卡死，重启整个 WSL
> wsl --shutdown
> wsl -d Ubuntu -- sudo systemctl start openclaw

# WSL 重启后需刷新端口代理（IP 会变）
# 脚本位于 C:\openclaw\refresh-portproxy.ps1（部署时自动创建）
> powershell -File C:\openclaw\refresh-portproxy.ps1
```

### 本地 macOS

```bash
# 使用 openclaw 内置命令重启 Gateway
$ openclaw gateway restart

# 手动方式
$ launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

---

## 3. 查看日志

### Ubuntu

```bash
# 实时跟踪 Gateway 日志（Ctrl+C 退出）
$ journalctl -u openclaw -f

# 查看最近 100 行日志
$ journalctl -u openclaw -n 100

# 查看最近 1 小时的日志
$ journalctl -u openclaw --since "1 hour ago"

# 查看安装日志
$ cat /var/log/openclaw/install.log

# 查看 Caddy 日志（启用 HTTPS 时）
$ journalctl -u caddy -f
```

### Windows (WSL)

```powershell
# 在 WSL 内查看日志
> wsl -d Ubuntu -- journalctl -u openclaw -f

# 查看安装日志
> type C:\openclaw\phase1.log
> type C:\openclaw\phase2.log

# 查看 Caddy 日志（启用 HTTPS 时）
> type C:\caddy\caddy.log
```

### 本地 macOS

```bash
# Gateway 运行日志
$ cat ~/.openclaw/logs/gateway.log

# Gateway 错误日志
$ cat ~/.openclaw/logs/gateway.err.log

# 实时跟踪
$ tail -f ~/.openclaw/logs/gateway.log

# 配置健康日志
$ cat ~/.openclaw/logs/config-health.json
```

---

## 4. 配置管理

### 配置文件位置

| 环境 | 路径 |
|------|------|
| Ubuntu VM | `/home/<admin>/.openclaw/openclaw.json` |
| Windows VM (WSL) | WSL 内 `/home/openclaw/.openclaw/openclaw.json` |
| 本地 macOS | `~/.openclaw/openclaw.json` |

### 查看当前配置

```bash
# 查看完整配置（注意包含 API Key，不要在不安全的环境中输出）
$ cat ~/.openclaw/openclaw.json

# 仅查看模型配置
$ openclaw models list

# 诊断配置问题
$ openclaw doctor
```

### 修改配置后生效

配置文件修改后**必须重启 Gateway** 才能生效：

```bash
# Ubuntu
$ sudo systemctl restart openclaw

# macOS
$ openclaw gateway restart

# Windows (WSL)
> wsl -d Ubuntu -- sudo systemctl restart openclaw
```

### 常用配置变更示例

**切换默认模型：**

修改 `openclaw.json` 中的 `agents.defaults.model.primary`：

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "azure-openai/gpt-4.1"
      }
    }
  }
}
```

**添加模型别名：**

```json
{
  "agents": {
    "defaults": {
      "models": {
        "azure-openai/gpt-4.1": { "alias": "gpt4" },
        "azure-openai/gpt-5.4-mini": { "alias": "mini" }
      }
    }
  }
}
```

**修改 Gateway 绑定地址：**

```json
{
  "gateway": {
    "port": 18789,
    "bind": "loopback"
  }
}
```

`bind` 可选值：`"loopback"`（仅本机）、`"0.0.0.0"`（所有接口）。

---

## 5. 升级 OpenClaw

### Ubuntu

```bash
# 1. 升级
$ sudo npm install -g openclaw@latest

# 2. 验证
$ openclaw --version
$ openclaw doctor

# 3. 重启服务
$ sudo systemctl restart openclaw

# 4. 检查运行状态
$ sudo systemctl status openclaw
```

### Windows (WSL)

```powershell
# 1. 在 WSL 内升级
> wsl -d Ubuntu -- bash -c "sudo npm install -g openclaw@latest"

# 2. 验证
> wsl -d Ubuntu -- openclaw --version

# 3. 重启服务
> wsl -d Ubuntu -- sudo systemctl restart openclaw
```

### 本地 macOS

```bash
$ npm install -g openclaw@latest
$ openclaw --version
$ openclaw doctor
$ openclaw gateway restart
```

> **注意**：升级后建议运行 `openclaw doctor` 检查，某些大版本可能需要运行 `openclaw onboard` 更新配置。

---

## 6. 端口与网络排查

### 检查端口监听

```bash
# Ubuntu / macOS — 检查 18789 端口是否在监听
$ ss -tlnp | grep 18789
# 或
$ lsof -i :18789
```

```powershell
# Windows — 检查端口占用
> netstat -ano | findstr 18789
```

### 测试连通性

```bash
# 从本地测试 VM 的 Gateway 是否可达
$ curl -s -o /dev/null -w "%{http_code}" http://<VM_PUBLIC_IP>:18789
# 返回 200 或 401 表示端口可通

# 测试 HTTPS（启用 Caddy 时）
$ curl -s -o /dev/null -w "%{http_code}" https://<FQDN>
```

### NSG 规则检查

```bash
# 查看 VM 所属 NSG 的入站规则
$ az network nsg rule list --nsg-name openclaw-nsg --resource-group rg-openclaw -o table
```

### 常见网络问题

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| 浏览器无法访问 18789 | NSG 未放行 / Gateway 未绑定 0.0.0.0 | 检查 NSG 规则 + `ss -tlnp` |
| HTTPS 证书错误 | Caddy 未获取证书 / DNS 未解析 | `journalctl -u caddy` 查看证书获取日志 |
| WSL 端口不通 | 端口代理失效（WSL IP 变了） | 运行 `refresh-portproxy.ps1` |
| 连接超时 | VM 未启动 / NSG 全部拒绝 | Azure Portal 检查 VM 状态和 NSG |

---

## 7. Caddy (HTTPS) 排查

仅当使用 `-EnablePublicHttps` 部署时适用。

### Ubuntu

```bash
# 查看 Caddy 状态
$ sudo systemctl status caddy

# 查看 Caddy 配置
$ cat /etc/caddy/Caddyfile

# 重启 Caddy
$ sudo systemctl restart caddy

# 检查证书状态
$ sudo caddy list-certificates

# 测试反向代理到 Gateway
$ curl -s http://127.0.0.1:18789
```

### Windows

```powershell
# Caddy 安装目录
> dir C:\caddy\

# 查看 Caddyfile
> type C:\caddy\Caddyfile

# 手动启动 Caddy（排查用）
> C:\caddy\caddy.exe run --config C:\caddy\Caddyfile
```

### Let's Encrypt 证书获取失败

常见原因：
1. DNS 尚未指向 VM 公网 IP — 确认 `nslookup <FQDN>` 返回正确 IP
2. 443 端口被防火墙阻塞 — 确认 NSG 放行 443 和 80
3. 域名格式错误 — Caddyfile 中的域名必须是完整 FQDN

---

## 8. 磁盘与资源监控

### Ubuntu

```bash
# 磁盘使用
$ df -h

# OpenClaw 目录占用
$ du -sh ~/.openclaw/

# 清理 OpenClaw 会话历史（释放空间）
$ du -sh ~/.openclaw/agents/main/sessions/
$ rm -f ~/.openclaw/agents/main/sessions/*.jsonl

# 内存和 CPU
$ free -h
$ top -b -n 1 | head -20
```

### Windows

```powershell
# 磁盘使用
> Get-PSDrive C | Select-Object Used, Free

# OpenClaw 目录占用
> wsl -d Ubuntu -- du -sh /home/openclaw/.openclaw/

# WSL 内存使用
> wsl -d Ubuntu -- free -h
```

---

## 9. 备份与恢复

### 备份

关键数据目录：

| 目录 | 内容 | 重要性 |
|------|------|--------|
| `~/.openclaw/openclaw.json` | 主配置文件 | ★★★ |
| `~/.openclaw/credentials/` | 通道认证凭据 | ★★★ |
| `~/.openclaw/agents/` | Agent 配置 + 会话历史 | ★★ |
| `~/.openclaw/workspace/` | 工作目录 | ★ |

```bash
# Ubuntu — 备份到本地
$ tar czf openclaw-backup-$(date +%Y%m%d).tar.gz \
    ~/.openclaw/openclaw.json \
    ~/.openclaw/credentials/ \
    ~/.openclaw/agents/main/agent/

# 下载到本地（从本地机器执行）
$ scp <user>@<VM_IP>:~/openclaw-backup-*.tar.gz ./
```

### 恢复

```bash
# 上传备份到 VM
$ scp openclaw-backup-20260327.tar.gz <user>@<VM_IP>:~/

# 在 VM 上恢复
$ cd ~ && tar xzf openclaw-backup-20260327.tar.gz
$ sudo systemctl restart openclaw
```

---

## 10. 安全巡检

定期执行以下检查确保 Gateway 安全：

```bash
# 1. 运行 OpenClaw 内置诊断
$ openclaw doctor

# 2. 检查 Gateway 认证模式（应为 password 或 token）
$ grep -A3 '"auth"' ~/.openclaw/openclaw.json

# 3. 检查 Gateway 绑定地址
#    - 有 HTTPS(Caddy): 应为 loopback (127.0.0.1)
#    - 无 HTTPS: 绑定 0.0.0.0 但必须启用密码认证
$ grep '"bind"' ~/.openclaw/openclaw.json

# 4. 检查 NSG 规则是否有多余端口暴露
$ az network nsg rule list --nsg-name openclaw-nsg --resource-group rg-openclaw -o table

# 5. 检查系统更新 (Ubuntu)
$ sudo apt list --upgradable

# 6. 检查 npm 全局包是否有已知漏洞
$ npm audit -g
```

### 安全最佳实践清单

- [ ] Gateway 认证已启用（`gateway.auth.mode` 为 `password` 或 `token`）
- [ ] 生产环境已启用 HTTPS（`-EnablePublicHttps`）
- [ ] NSG 仅开放必要端口（HTTPS: 443，非 HTTPS: 22/3389 + 18789）
- [ ] 操作系统和 Node.js 保持最新
- [ ] API Key 未硬编码在脚本或代码中
- [ ] `logs/` 目录中的 `.env` 文件未提交到 Git

---

## 11. 常见问题速查表

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| **Gateway 启动失败** | 端口被占用 / 配置文件语法错误 | `journalctl -u openclaw -n 50` 查看错误；`python3 -m json.tool ~/.openclaw/openclaw.json` 验证 JSON |
| **`openclaw models list` 报错** | 配置中 api 类型不合法或缺少 models 数组 | 检查 provider 的 `api` 字段是否为合法值（如 `openai-responses`），确保有 `models` 数组 |
| **Web UI 能打开但模型调用失败** | API Key 错误 / 端点不可达 / 模型 ID 不匹配 | `curl` 直接测试端点；确认 API Key 有效；确认模型 ID 与部署名一致 |
| **浏览器显示 401 Unauthorized** | Gateway 密码认证已启用 | 输入正确的 Gateway 密码（见 `.env` 文件中的 `GATEWAY_PASSWORD`） |
| **Slack/Teams 消息无响应** | 通道未启用 / Token 失效 / 网络不通 | 检查 `openclaw.json` 中通道配置；`openclaw doctor` 查看通道状态 |
| **WSL 重启后服务不可达** | WSL IP 变化导致端口代理失效 | 运行 `C:\openclaw\refresh-portproxy.ps1` |
| **`npm install -g openclaw` 报权限错误** | Ubuntu 上需要 sudo | 使用 `sudo npm install -g openclaw@latest` |
| **HTTPS 证书过期/未获取** | 443 端口未放行 / DNS 未解析 | 检查 NSG 放行 443+80；`nslookup <FQDN>` 确认 DNS |
| **VM SSH/RDP 连不上** | VM 已停止 / NSG 规则缺失 / 密码错误 | Azure Portal 检查 VM 状态；检查 NSG 入站规则 |
| **聊天 UI 模型列表显示旧模型** | Agent 缓存未刷新 | 删除 `~/.openclaw/agents/main/agent/models.json` 后重启 Gateway |

---

## 快速命令参考

```bash
# ---- Ubuntu 一行命令速查 ----
sudo systemctl status openclaw          # 状态
sudo systemctl restart openclaw         # 重启
journalctl -u openclaw -f               # 实时日志
openclaw doctor                         # 健康检查
openclaw models list                    # 模型列表
sudo npm install -g openclaw@latest     # 升级

# ---- macOS 一行命令速查 ----
openclaw gateway restart                # 重启
openclaw doctor                         # 健康检查
openclaw models list                    # 模型列表
tail -f ~/.openclaw/logs/gateway.log    # 实时日志
npm install -g openclaw@latest          # 升级
```
