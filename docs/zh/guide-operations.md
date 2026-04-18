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
12. [设备配对管理](#12-设备配对管理)

---

## 1. 服务状态检查

### OpenClaw CLI 通用命令（推荐，跨平台）

OpenClaw 提供了一组跨平台的 operator 命令，不依赖 systemd：

```bash
# 快速本地概览（gateway 可达性、模型、通道、最近活动）
$ openclaw status
$ openclaw status --all       # 完整本地诊断，安全粘贴用
$ openclaw status --deep      # 向 gateway 请求 live health probe

# Gateway 控制
$ openclaw gateway status     # gateway 进程状态
$ openclaw gateway status --deep  # 额外检查系统服务（launchd/systemd/schtasks）
$ openclaw gateway restart    # 重启
$ openclaw gateway stop       # 停止
$ openclaw gateway install    # 安装系统服务
$ openclaw gateway probe      # 探测 gateway 连接性

# 专用健康检查命令
$ openclaw health             # gateway snapshot（WS，低开销）
$ openclaw health --verbose   # 强制 live probe
$ openclaw health --json      # 机器可读 JSON

# 修复与迁移（配置、状态目录、服务）
$ openclaw doctor             # 只读诊断 + 交互式修复
$ openclaw doctor --fix       # 自动应用配置/状态迁移
$ openclaw doctor --repair    # 静默修复（推荐的都自动执行）
$ openclaw doctor --deep      # 新增：寻找额外的 gateway 安装

# 日志
$ openclaw logs --follow      # 等价于 tail -f

# 通道健康
$ openclaw channels status --probe  # 向 gateway 请求活探测
```

### Ubuntu、systemd层面

```bash
# 查看 OpenClaw Gateway 服务状态
$ sudo systemctl status openclaw

# 输出示例（正常）：
#   Active: active (running) since ...
# 输出示例（异常）：
#   Active: failed (Result: exit-code)
```

### Windows (WSL)

```powershell
# 查看 WSL 是否正在运行
> wsl --list --verbose
# STATE 应为 Running

# 在 WSL 内执行 OpenClaw CLI 通用命令
> wsl -d Ubuntu -u openclaw -- openclaw status
> wsl -d Ubuntu -u openclaw -- openclaw health

# 检查 Windows 端口代理是否生效
> netsh interface portproxy show v4tov4
# 应包含 18789 -> WSL IP 的映射
```

### 本地 macOS (LaunchAgent)

```bash
# 已由上面的通用 CLI 命令覆盖。补充的 launchd 层面：
$ launchctl print gui/$(id -u)/ai.openclaw.gateway
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
# OpenClaw 默认将日志写到 /tmp/openclaw/ 下（按日期轮换）
$ ls /tmp/openclaw/

# 实时跟踪今天的日志
$ tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log

# 或使用内置 CLI（跨平台）
$ openclaw logs --follow

# LaunchAgent 标准输出可能位于：
$ cat ~/Library/Logs/openclaw/gateway.log 2>/dev/null || echo 'check launchctl print for actual paths'
```

> 日志路径可通过 `logging.file` 在 `openclaw.json` 中自定义。

---

## 4. 配置管理

### 配置文件位置

| 环境             | 路径                                            |
| ---------------- | ----------------------------------------------- |
| Ubuntu VM        | `/home/<admin>/.openclaw/openclaw.json`         |
| Windows VM (WSL) | WSL 内 `/home/openclaw/.openclaw/openclaw.json` |
| 本地 macOS       | `~/.openclaw/openclaw.json`                     |

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

OpenClaw Gateway 默认监听 `~/.openclaw/openclaw.json` 的变化并自动热加载（`gateway.reload.mode="hybrid"`），**大多数配置更改无需手动重启**。

热加载行为与规则：

| 改动类型                                                                                   | 是否需要重启 |
| ------------------------------------------------------------------------------------------ | ------------ |
| 通道配置（`channels.*`、WhatsApp/Slack/Teams 等）                                          | 否           |
| Agent、模型、路由（`agents`、`models`、`routing`）                                         | 否           |
| 会话、消息、工具、媒体（`session`、`messages`、`tools`、`browser`、`skills`、`audio`）     | 否           |
| 自动化（`hooks`、`cron`、`agent.heartbeat`）                                               | 否           |
| Gateway 服务器（`gateway.port`、`gateway.bind`、`gateway.auth`、`gateway.tailscale`、TLS） | **是**       |
| 基础设施（`discovery`、`canvasHost`、`plugins`）                                           | **是**       |

`hybrid` 模式下，Gateway 会自动重启需要重启的改动。如果仅修改了普通字段，几乎无感生效。你可以查看日志确认是否重载：

```bash
$ journalctl -u openclaw -f | grep -i reload
```

如果你确实需要手动重启（例如端口或认证模式变更）：

```bash
# 跨平台（推荐）
$ openclaw gateway restart

# 或通过 systemd
$ sudo systemctl restart openclaw

# Windows (WSL)
> wsl -d Ubuntu -u openclaw -- openclaw gateway restart
```

> 【仅少数情况需手动重启】修改 `.service` 文件（而非 `openclaw.json`）后需 `sudo systemctl daemon-reload && sudo systemctl restart openclaw`。

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

| 症状                 | 可能原因                            | 排查方法                               |
| -------------------- | ----------------------------------- | -------------------------------------- |
| 浏览器无法访问 18789 | NSG 未放行 / Gateway 未绑定 0.0.0.0 | 检查 NSG 规则 + `ss -tlnp`             |
| HTTPS 证书错误       | Caddy 未获取证书 / DNS 未解析       | `journalctl -u caddy` 查看证书获取日志 |
| WSL 端口不通         | 端口代理失效（WSL IP 变了）         | 运行 `refresh-portproxy.ps1`           |
| 连接超时             | VM 未启动 / NSG 全部拒绝            | Azure Portal 检查 VM 状态和 NSG        |

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

| 目录                        | 内容                  | 重要性 |
| --------------------------- | --------------------- | ------ |
| `~/.openclaw/openclaw.json` | 主配置文件            | ★★★    |
| `~/.openclaw/credentials/`  | 通道认证凭据          | ★★★    |
| `~/.openclaw/agents/`       | Agent 配置 + 会话历史 | ★★     |
| `~/.openclaw/workspace/`    | 工作目录              | ★      |

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

### 凭据速查（登录密码 / Control Token）

进 Web UI 需要两级凭据：**Gateway 登录密码**（浏览器表单）和**Control Token**（仅 macOS 客户端 / CLI / iOS 节点等远程设备需要）。

#### Gateway 登录密码

凭部署方式不同，获取路径不一样：

| 部署方式                                 | 密码位置                                      |
| ---------------------------------------- | --------------------------------------------- |
| `deploy.ps1`                             | `logs/<timestamp>/.env` 中 `GATEWAY_PASSWORD` |
| Azure Portal 「Deploy to Azure」一键部署 | 你在部署表单中填写的 `gatewayPassword`        |
| 两者都丢了                               | 从服务端回查（见下方命令）                    |

```bash
# SSH 进 VM 后执行（Windows 用 wsl -d Ubuntu -u openclaw -- ...）
sudo systemctl cat openclaw | grep OPENCLAW_GATEWAY_PASSWORD
```

轮换密码：

```bash
# 生成新密码并更新 systemd Environment
NEW_PWD=$(openssl rand -base64 24)
sudo systemctl edit openclaw --full   # 把 OPENCLAW_GATEWAY_PASSWORD 改成 $NEW_PWD
sudo systemctl restart openclaw
echo "New password: $NEW_PWD"
```

### Gateway Control Token（`gateway.auth.token`）

Control Token 是远程客户端（如 macOS 应用、`openclaw` CLI 通过 SSH 隧道、iOS/Android node）连接 Gateway WebSocket 时使用的共享密钥。本项目默认使用 `password` 模式配合 Caddy HTTPS 反代，如果需要切换到 `token` 模式（例如接入 macOS 应用的 “Remote over SSH”或给 iOS/Android node 配对），可按以下方式获取。

#### 1. 让 OpenClaw 自动生成

```bash
# 方式 A：onboard 默认会写入 token，直接读取即可
$ jq -r '.gateway.auth.token' ~/.openclaw/openclaw.json

# 方式 B：使用 doctor 子命令单独生成/轮换
$ openclaw doctor --generate-gateway-token
```

生成后 token 会写入 `~/.openclaw/openclaw.json` 的 `gateway.auth.token` 字段。需要重启服务使配置生效：

```bash
$ sudo systemctl restart openclaw
```

#### 2. 手动设置自定义 token

```bash
# 生成 32 字节随机 token
$ TOKEN=$(openssl rand -base64 32)
$ echo "$TOKEN"

# 写入配置
$ openclaw config set gateway.auth.mode token
$ openclaw config set gateway.auth.token "$TOKEN"
$ sudo systemctl restart openclaw
```

#### 3. 客户端使用方式

- **环境变量**：`export OPENCLAW_GATEWAY_TOKEN="<token>"`
- **CLI 参数**：`openclaw gateway status --url ws://127.0.0.1:18789 --token <token>`
- **客户端配置**：在本地 `~/.openclaw/openclaw.json` 写入 `gateway.remote.token`
  ```bash
  openclaw config set gateway.remote.token "<token>"
  ```

#### 4. 轮换 token

怀疑泄露时立即轮换：

```bash
$ openclaw doctor --generate-gateway-token   # 生成新 token
$ sudo systemctl restart openclaw             # 重启服务应用
# 然后更新所有客户端（macOS 应用 / CLI / nodes）的 `gateway.remote.token`
```

> ⚠️ 不要将 token 提交到 Git。它等同于 Gateway 的 operator 凭证，持有者可以调用 `/v1/chat/completions`、`/tools/invoke` 等全部接口。

---

## 11. 常见问题速查表

| 问题                                     | 原因                                                                            | 解决方案                                                                                                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Gateway 启动失败**                     | 端口被占用 / 配置文件语法错误                                                   | `journalctl -u openclaw -n 50` 查看错误；`python3 -m json.tool ~/.openclaw/openclaw.json` 验证 JSON                                                                           |
| **`openclaw models list` 报错**          | 配置中 api 类型不合法或缺少 models 数组                                         | 检查 provider 的 `api` 字段是否为合法值（如 `openai-responses`），确保有 `models` 数组                                                                                        |
| **Web UI 能打开但模型调用失败**          | API Key 错误 / 端点不可达 / 模型 ID 不匹配                                      | `curl` 直接测试端点；确认 API Key 有效；确认模型 ID 与部署名一致                                                                                                              |
| **浏览器显示 401 Unauthorized**          | Gateway 密码认证已启用                                                          | 输入正确的 Gateway 密码（`deploy.ps1` 在 `.env` 的 `GATEWAY_PASSWORD`；Portal 一键部署即表单填的 `gatewayPassword`；忘了见 [§10 凭据速查](#凭据速查登录密码--control-token)） |
| **浏览器提示 `origin not allowed`**      | 从非 loopback 域名访问 Control UI，但 `gateway.controlUi.allowedOrigins` 未加白 | 参见下面 [11.1 Control UI “origin not allowed”](#111-control-ui-origin-not-allowed) 节                                                                                        |
| **Slack/Teams 消息无响应**               | 通道未启用 / Token 失效 / 网络不通                                              | 检查 `openclaw.json` 中通道配置；`openclaw doctor` 查看通道状态                                                                                                               |
| **WSL 重启后服务不可达**                 | WSL IP 变化导致端口代理失效                                                     | 运行 `C:\openclaw\refresh-portproxy.ps1`                                                                                                                                      |
| **`npm install -g openclaw` 报权限错误** | Ubuntu 上需要 sudo                                                              | 使用 `sudo npm install -g openclaw@latest`                                                                                                                                    |
| **HTTPS 证书过期/未获取**                | 443 端口未放行 / DNS 未解析                                                     | 检查 NSG 放行 443+80；`nslookup <FQDN>` 确认 DNS                                                                                                                              |
| **VM SSH/RDP 连不上**                    | VM 已停止 / NSG 规则缺失 / 密码错误                                             | Azure Portal 检查 VM 状态；检查 NSG 入站规则                                                                                                                                  |
| **聊天 UI 模型列表显示旧模型**           | Agent 缓存未刷新                                                                | 删除 `~/.openclaw/agents/main/agent/models.json` 后重启 Gateway                                                                                                               |

---

### 11.1 Control UI “origin not allowed”

**报错**：浏览器访问 Control UI 时提示

```
origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)
```

**原因**：Gateway 默认只信任 loopback (`http://127.0.0.1:18789` / `http://localhost:18789`) 作为 Control UI 的可信 origin。一旦你从公网 IP、Azure FQDN、Caddy HTTPS 域名或任何反向代理访问，都会被这个安全拦截抦下。

**推荐方案（按安全性排序）**：

#### 方案 A：SSH 隧道（最安全，推荐日常使用）

在本地打开终端：

```bash
ssh -N -L 18789:127.0.0.1:18789 <ADMIN_USERNAME>@<VM_PUBLIC_IP>
```

然后浏览器打开 <http://127.0.0.1:18789/>。从 Gateway 角度看是 loopback，无需加白。

#### 方案 B：加白你的访问 origin（适用于 Caddy HTTPS 部署 / 打宗明使用公网访问）

SSH 进 VM 后运行：

```bash
# 单个 origin
openclaw config set gateway.controlUi.allowedOrigins '["https://openclaw-xxxx.japaneast.cloudapp.azure.com"]'

# 多个 origin
openclaw config set gateway.controlUi.allowedOrigins \
  '["https://openclaw-xxxx.japaneast.cloudapp.azure.com", "https://chat.example.com"]'
```

或手工编辑 `~/.openclaw/openclaw.json`：

```jsonc
{
  "gateway": {
    "controlUi": {
      "enabled": true,
      // 列出你会从浏览器访问的全部 origin（含协议 + 主机 + 端口）
      "allowedOrigins": [
        "https://openclaw-xxxx.japaneast.cloudapp.azure.com",
        "http://20.48.19.109:18789"
      ]
    }
  }
}
```

修改后热加载生效（`gateway.reload.mode` 默认 `hybrid`）。如果仍不生效，手动重启：

```bash
openclaw gateway restart
# 或
sudo systemctl restart openclaw
```

验证：

```bash
openclaw config get gateway.controlUi.allowedOrigins
```

#### 三个常见陷阱

1. **origin 必须严格匹配**：包含 `scheme://host[:port]`，末尾不带斜杠。`https://example.com` 和 `https://example.com/` 不同；`https://example.com` 和 `https://example.com:443` 同义但建议不写默认端口。
2. **HTTP vs HTTPS 要区分**：启用了 Caddy HTTPS 就只开 `https://...`，不要同时加 `http://...:18789`，除非你确实需要两路均可访问。
3. **不要随手开通配**：官方有 `dangerouslyAllowHostHeaderOriginFallback` 选项但名字里带 `dangerously` 不是没原因的——会使 Control UI 认为 Host header 中的任何值都是合法 origin，反向代理后设置不当会被伪造。除非你完全控制代理层起点，否则不开。

#### Caddy HTTPS 部署场景快速启动

如果你是用 `deploy.ps1 -EnablePublicHttps` 部署的：FQDN 在 `.env` 里，直接一句搞定：

```bash
FQDN=$(grep ^FQDN ~/.env-or-from-logs | cut -d= -f2)  # 或手工贴
openclaw config set gateway.controlUi.allowedOrigins "[\"https://$FQDN\"]"
openclaw gateway restart
```

---

## 12. 设备配对管理

OpenClaw Gateway 默认对每个浏览器/客户端采用 **设备级配对**（device pairing）机制。输密码后还会被要求在服务器端审批才能进入 Web UI。

### 12.1 首次配对流程

> **顺序很重要**：浏览器密码验证通过后 Gateway 才会生成配对请求。密码/Token 不对时浏览器会直接报 401，服务端 `openclaw devices list --pending` 一直为空，即使执行 `approve` 也无内容可审批。

1. SSH 进 VM 执行 `openclaw onboard` 配置模型 API Key（首次部署后必做）
2. 浏览器访问 Control UI（`https://<FQDN>` 或 `http://<IP>:18789`），输入 `GATEWAY_PASSWORD` 后点击连接
3. 页面提示 `pairing required` / “等待服务器审批”（这才说明密码验证通过）
4. SSH 进 VM（Windows 则是 `wsl -d Ubuntu -u openclaw -- ...`）：

```bash
openclaw devices approve --latest
```

5. 浏览器自动完成连接

### 12.2 常用命令

```bash
openclaw devices list                    # 列出全部已配对设备
openclaw devices list --pending          # 只看待审批请求
openclaw devices approve --latest        # 审批最新一个请求
openclaw devices approve <id>            # 审批指定请求
openclaw devices remove <id>             # 撤销某台设备
openclaw devices remove --all            # 一键清空（下次连接全部需重新配对）
```

### 12.3 什么时候需要重新配对

配对绑定在浏览器本地存储的 device token，以下场景会丢失 token 并需重新审批：

- 换浏览器或设备访问
- 隐私模式 / 无痕浏览窗口
- 手动清除站点数据、Cookies 或 LocalStorage
- 浏览器重装、换用户配置
- 服务器侧执行 `openclaw devices remove`

### 12.4 故障排查

- **浏览器一直转圈 “pairing required”**：服务器未执行 approve，或 approve 后 Gateway 未重新下发事件。重试浏览器。
- **`openclaw devices list --pending` 为空**：请求未能到达 Gateway。检查是否 origin 被拦（参见 §11.1）或密码错误。
- **主动设一套可复用设备**：不建议。设备 token 是隐私凭证，共享后任何拿到的人都能以该设备身份接入。

---

## 快速命令参考

```bash
# ---- 跨平台 OpenClaw CLI（推荐）----
openclaw status                         # 本地概览
openclaw status --deep                  # 活探测
openclaw health --json                  # 结构化健康快照
openclaw gateway restart                # 重启 gateway
openclaw gateway status                 # gateway 状态
openclaw doctor                         # 诊断
openclaw doctor --repair                # 静默修复
openclaw logs --follow                  # 实时日志
openclaw channels status --probe        # 通道探测
openclaw models list                    # 模型列表
npm install -g openclaw@latest          # 升级（Ubuntu 需 sudo）

# ---- Ubuntu systemd 层面 ----
sudo systemctl status openclaw          # 状态
sudo systemctl restart openclaw         # 重启
journalctl -u openclaw -f               # 实时日志
```
