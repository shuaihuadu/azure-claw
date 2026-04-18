# 🦞 Azure Claw — 一键部署 OpenClaw 到 Azure VM


[English](README.md)

一键将 [OpenClaw](https://openclaw.ai/) 个人 AI 助手部署到 Azure 虚拟机，支持 **Ubuntu 24.04 LTS** 和 **Windows 11** 镜像可选。

## 什么是 OpenClaw

OpenClaw 是一个自托管的 AI 助手网关，将 WhatsApp、Telegram、Discord、Slack、iMessage 等聊天应用连接到 AI 编码代理（如 Pi）。你在自己的机器上运行一个 Gateway 进程，它就成为消息应用和 AI 助手之间的桥梁。

- **自托管**: 运行在你自己的硬件上，数据完全掌控
- **多通道**: 一个 Gateway 同时服务 WhatsApp、Telegram、Discord 等
- **Agent 原生**: 支持工具调用、会话管理、记忆和多代理路由
- **开源**: MIT 许可证，社区驱动

## 前置条件

在本地开发机上需要安装以下工具：

| 工具                | 用途              | 安装指南                                                                                                                     |
| ------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **Azure CLI**       | 部署 Azure 资源   | [安装 Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)                                                    |
| **PowerShell 7+**   | 运行部署/清理脚本 | [安装 PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)（Windows 自带 5.1 也可用） |
| **Azure Bicep CLI** | 编译 Bicep 模板   | 随 Azure CLI 自动安装，或 `az bicep install`                                                                                 |

此外你还需要：

- **Azure 订阅**（[免费创建](https://azure.microsoft.com/free/)）
- **AI 模型提供商的 API Key**（OpenAI / Anthropic / 等），部署完成后在 VM 上配置

## 快速开始

### 方式一：一键部署（Azure Portal）

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fshuaihuadu%2Fazure-claw%2Fmain%2Finfra%2Fazuredeploy.json)

点击按钮，在 Azure Portal 中填写参数即可。

> **注意**: Deploy to Azure 按钮需要仓库为 **公开仓库**，且已生成 ARM 模板：
> ```powershell
> az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
> git add infra/azuredeploy.json && git commit -m "Generate ARM template" && git push
> ```
> 如果仓库为私有，请使用方式二的脚本部署。

### 方式二：脚本部署（推荐）

```powershell
# 交互式引导部署（推荐首次使用）
# 自动查询订阅、可用区域、VM 规格，逐步引导选择
.\deploy.ps1

# 自定义参数部署（跳过交互）
.\deploy.ps1 -Location eastasia -VmSize Standard_B2as_v2 -OsType Ubuntu -AdminUsername azureclaw -AdminPassword "YourP@ssw0rd!"

# 指定资源组名称
.\deploy.ps1 -ResourceGroup my-rg -Location eastasia

# 部署 Windows 11 VM
.\deploy.ps1 -OsType Windows

# 启用公网 HTTPS 访问（Caddy + Let's Encrypt 自动证书 + 密码认证）
.\deploy.ps1 -EnablePublicHttps
```

部署完成后，SSH 进入 VM 运行 `openclaw onboard`，交互式配置 AI 模型提供商（OpenAI / Anthropic / Azure OpenAI 等）和消息通道。

> **提示**: 不带任何参数运行 `.\deploy.ps1` 会进入交互式引导模式，自动查询你的 Azure 订阅中可用的区域和 VM 规格，避免选到不可用的资源。

部署参数说明：

| 参数                 | 说明                                | 默认值              |
| -------------------- | ----------------------------------- | ------------------- |
| `-Location`          | Azure 区域                          | `eastasia`          |
| `-OsType`            | 操作系统 (`Ubuntu` / `Windows`)     | `Ubuntu`            |
| `-VmSize`            | VM 规格                             | `Standard_B2als_v2` |
| `-AdminUsername`     | 管理员用户名                        | `azureclaw`         |
| `-AdminPassword`     | 管理员密码                          | 自动生成强密码      |
| `-ResourceGroup`     | Azure 资源组名称                    | `rg-openclaw`       |
| `-EnablePublicHttps` | 公网 HTTPS（Caddy + Let's Encrypt） | **开启**            |

> **Windows 用户注意**: Windows 11 + WSL2 至少需要 8GB 内存，建议使用 `Standard_B2as_v2` 或更高规格：
> ```powershell
> .\deploy.ps1 -OsType Windows -VmSize Standard_B2as_v2
> ```

> 所有参数都有默认值，直接运行 `.\deploy.ps1` 即可。

### 部署产物

部署成功后，在 `logs/` 目录下生成时间戳目录，包含三个文件：

```
logs/20260320143052/
├── deploy.log    # 部署过程日志（参数脱敏）
├── .env          # 敏感信息（用户名、密码、IP 等）
└── guide.md      # 操作指南（如何连接服务器和 OpenClaw）
```

## 部署后操作

部署完成后，打开 `logs/<timestamp>/guide.md` 查看完整操作指南。

### Ubuntu VM

**一、连接远程服务器**（用户名和密码参见 `.env` 文件）：

```bash
ssh <ADMIN_USERNAME>@<VM_PUBLIC_IP>
```

**二、连接 OpenClaw**：

```bash
# 浏览器访问 Web 控制台
# 未启用 HTTPS 时:
http://<VM_PUBLIC_IP>:18789
# 启用 HTTPS 时:
https://<FQDN>  # FQDN 参见 .env 文件

# Gateway 登录密码参见 .env 文件中的 GATEWAY_PASSWORD

# 首次连接需要设备配对（浏览器显示 "pairing required"）
# SSH 登录服务器后执行：
openclaw devices approve --latest

# 检查服务状态
sudo systemctl status openclaw

# 运行交互式配置（设置 API Key、通道等）
openclaw onboard

# 查看 Gateway 日志
journalctl -u openclaw -f
```

### Windows 11 VM

> **注意**: Windows 部署分两阶段完成。Phase 1 安装 WSL2 后 VM 会自动重启，Phase 2 在重启后自动安装 Node.js 和 OpenClaw。
> 首次部署后请等待约 5-10 分钟再通过 RDP 连接，确保 Phase 2 完成。可检查 `C:\openclaw\phase2.log` 查看进度。

**一、连接远程服务器**（用户名和密码参见 `.env` 文件）：

```powershell
mstsc /v:<VM_PUBLIC_IP>
```

**二、连接 OpenClaw**：

```powershell
# RDP 登录后打开浏览器访问
http://localhost:18789
# 启用 HTTPS 时，也可从外网访问:
# https://<FQDN>  # FQDN 参见 .env 文件

# Gateway 登录密码参见 .env 文件中的 GATEWAY_PASSWORD

# 首次连接需要设备配对（浏览器显示 "pairing required"）
# 在 PowerShell 中执行：
wsl -d Ubuntu -u openclaw -- openclaw devices approve --latest

# 打开 PowerShell 运行诊断
openclaw doctor

# 运行交互式配置
openclaw onboard --install-daemon
```

## 清理资源

```powershell
# 删除所有 Azure 资源（会确认提示）
.\destroy.ps1

# 指定资源组名称
.\destroy.ps1 -ResourceGroup my-rg

# 跳过确认直接删除
.\destroy.ps1 -Force
```

## 项目结构

```
azure-claw/
├── .github/
│   └── copilot-instructions.md      # Copilot 开发指引
├── docs/                            # 操作手册
│   ├── zh/                          # 中文文档
│   │   ├── guide-operations.md          # 运维手册（服务排查、重启、日志、升级等）
│   │   ├── guide-slack.md               # 配置 Slack 通道
│   │   └── guide-teams.md               # 配置 Microsoft Teams 通道
│   └── en/                          # English documentation
│       ├── guide-operations.md
│       ├── guide-slack.md
│       └── guide-teams.md
├── infra/                           # Bicep 基础设施代码
│   ├── main.bicep                   # 主 Bicep 模板
│   ├── azuredeploy.json             # ARM 模板（由 Bicep 生成，供一键部署）
│   ├── main.parameters.json         # 参数文件
│   └── modules/
│       ├── network.bicep            # VNet / NSG / Public IP
│       ├── vm-ubuntu.bicep          # Ubuntu VM 模块
│       └── vm-windows.bicep         # Windows VM 模块
├── scripts/
│   ├── install-openclaw-ubuntu.sh   # Ubuntu 安装脚本
│   ├── install-openclaw-windows.ps1 # Windows 安装脚本
│   └── shared-functions.ps1         # 共享 PowerShell 辅助函数
├── deploy.ps1                       # 部署入口脚本
├── destroy.ps1                      # 资源清理脚本
├── setup-teams.ps1                  # Teams 通道半自动配置脚本
├── azure.yaml                       # azd 项目配置
├── .gitignore
├── LICENSE                          # MIT 许可证
├── logs/                            # 部署产物（git ignored）
│   └── {yyyyMMddHHmmss}/
│       ├── deploy.log               # 部署日志
│       ├── .env                     # 敏感信息
│       └── guide.md                 # 操作指南
└── README.md
```

## VM 规格建议

| 场景         | 推荐 VM 规格      | vCPU | 内存  | 说明                                   |
| ------------ | ----------------- | ---- | ----- | -------------------------------------- |
| 个人轻度使用 | Standard_B2als_v2 | 2    | 4 GB  | 基础 Gateway + 1-2 个通道（仅 Ubuntu） |
| 日常使用     | Standard_B2as_v2  | 2    | 8 GB  | 多通道 + Browser 工具                  |
| 重度使用     | Standard_B4as_v2  | 4    | 16 GB | 多代理 + Browser + 沙箱                |

## 安全注意事项

- 所有部署模式均默认启用 Gateway 密码认证（`gateway.auth.mode: "password"`），密码自动生成并保存在 `.env` 文件中
- 使用 `-EnablePublicHttps` 可进一步启用 Caddy 反向代理 + Let's Encrypt 自动 HTTPS 证书，加密传输层
- HTTPS 模式下，Gateway 绑定 loopback，仅 Caddy 可访问，NSG 开放 443 端口
- 非 HTTPS 模式下，NSG 开放 SSH (22) / RDP (3389) 和 Gateway (18789) 端口，密码通过 HTTP 明文传输
- **建议** 在生产环境启用 `-EnablePublicHttps`，或通过 VPN 访问 Gateway，避免密码明文传输
- 敏感信息（密码、Gateway 密码等）仅保存在 `logs/<timestamp>/.env`，不会提交到 Git
- 定期运行 `openclaw doctor` 检查安全配置
- 参考 OpenClaw [安全指南](https://docs.openclaw.ai/gateway/security)

## 常见问题

### 首次连接为什么要配对？

OpenClaw Gateway 使用设备配对机制保障安全。每个新浏览器/设备首次连接时需要在服务器端执行 `openclaw devices approve --latest` 审批。配对基于浏览器存储的 device token，更换浏览器、清除数据或使用隐私模式都需要重新配对。

### 支持哪些 AI 模型？

OpenClaw 支持多种模型提供商，包括 OpenAI (GPT-5.2/Codex)、Anthropic (Claude)、Google (Gemini) 等。详见 [Models 文档](https://docs.openclaw.ai/concepts/models)。

### Windows 为什么需要 WSL2？

OpenClaw 官方推荐在 Windows 上使用 WSL2 运行。本项目的 Windows 11 VM 脚本会自动配置 WSL2 + Ubuntu 环境来运行 OpenClaw，以确保最佳兼容性。

### 如何连接消息通道？

部署完成后，通过 `openclaw onboard` 或手动编辑 `~/.openclaw/openclaw.json` 配置通道。最快的方式是先连接 Telegram（只需一个 Bot Token）。详见 [Channels 文档](https://docs.openclaw.ai/channels)。

### 如何更新 OpenClaw？

**Ubuntu:**

```bash
sudo npm install -g openclaw@latest
openclaw doctor
sudo systemctl restart openclaw
```

**Windows (WSL):**

```powershell
# 在 PowerShell 中执行
wsl -d Ubuntu -- bash -c "sudo npm install -g openclaw@latest"
wsl -d Ubuntu -- bash -c "sudo systemctl restart openclaw"
```

## 配置指南

部署完成后，参考以下指南配置 AI 模型和消息通道：

- [配置 Slack 消息通道](docs/zh/guide-slack.md) — 在 Slack 中与 AI 助手对话
- [配置 Microsoft Teams 消息通道](docs/zh/guide-teams.md) — 在 Teams 中与 AI 助手对话（提供半自动化配置脚本 `setup-teams.ps1`）
- [运维手册](docs/zh/guide-operations.md) — 服务排查、重启、日志查看、升级、备份、安全巡检等日常运维操作

## 参考链接

- [OpenClaw 官网](https://openclaw.ai/)
- [OpenClaw 文档](https://docs.openclaw.ai/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [ClawHub 技能市场](https://clawhub.ai/)
- [OpenClaw Docker 部署](https://docs.openclaw.ai/install/docker)
- [Tailscale 远程访问](https://docs.openclaw.ai/gateway/tailscale)

## 许可证

[MIT](LICENSE)