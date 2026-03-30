# Azure Claw — Copilot 开发指引

## 项目概述

azure-claw 是一个一键部署项目，将 [OpenClaw](https://github.com/openclaw/openclaw) 个人 AI 助手部署到 Azure VM。支持 Ubuntu 24.04 LTS 和 Windows 11 双镜像。

## 技术栈

- **基础设施**: Azure Bicep → ARM 模板，Azure Developer CLI (azd)
- **部署脚本**: PowerShell (`deploy.ps1` / `destroy.ps1`)
- **目标平台**: Azure VM (Ubuntu 24.04 LTS / Windows 11)
- **VM 安装脚本**: Bash (Ubuntu) / PowerShell (Windows)
- **运行时**: Node.js 24 (推荐) 或 Node 22.16+
- **应用**: OpenClaw Gateway (TypeScript, npm 全局安装)

## 目录结构约定

```
azure-claw/
├── .github/
│   └── copilot-instructions.md      # 本文件（Copilot 开发指引）
├── docs/                            # 操作手册
│   ├── zh/                          # 中文文档
│   │   ├── guide-microsoft-foundry.md    # 配置 Azure OpenAI / Microsoft Foundry 模型
│   │   ├── guide-model-troubleshooting.md # 模型连接排障指南
│   │   ├── guide-operations.md          # 日常运维操作手册
│   │   ├── guide-slack.md               # 配置 Slack 通道
│   │   └── guide-teams.md               # 配置 Microsoft Teams 通道
│   └── en/                          # English documentation
│       ├── guide-microsoft-foundry.md
│       ├── guide-model-troubleshooting.md
│       ├── guide-operations.md
│       ├── guide-slack.md
│       └── guide-teams.md
├── infra/                           # Bicep 基础设施代码
│   ├── main.bicep                   # 入口模板，根据 osType 参数分发
│   ├── main.parameters.json         # 默认参数
│   ├── azuredeploy.json             # 导出的 ARM 模板
│   └── modules/
│       ├── foundry.bicep            # Azure AI 服务 + 模型部署（可选）
│       ├── network.bicep            # VNet, Subnet, NSG, Public IP
│       ├── vm-ubuntu.bicep          # Ubuntu VM + NIC + CustomScript
│       └── vm-windows.bicep         # Windows VM + NIC + CustomScriptExtension
├── scripts/
│   ├── install-openclaw-ubuntu.sh   # Ubuntu: Node.js + OpenClaw + systemd
│   ├── install-openclaw-windows.ps1 # Windows: WSL2 + Node.js + OpenClaw
│   ├── setup-foundry-model.ps1     # 独立工具：发现 VM + 3 模式配置 Foundry 模型
│   └── shared-functions.ps1        # 共享辅助函数（模型知识库、交互选择等）
├── deploy.ps1                       # 部署入口脚本
├── destroy.ps1                      # 资源清理脚本
├── setup-teams.ps1                  # Teams 通道半自动配置脚本
├── azure.yaml                       # azd 项目描述文件
├── .gitignore                       # 忽略 logs/ 等
├── logs/                            # 部署产物（git ignored）
│   └── {yyyyMMddHHmmss}/           # 以时间戳命名的目录
│       ├── deploy.log               # 部署日志
│       ├── .env                     # 敏感信息（密码、连接串等）
│       └── guide.md                 # 操作指南文档
└── README.md
```

## Bicep 编写规范

### 命名规则

- 资源名称使用 kebab-case：`openclaw-vm`, `openclaw-nsg`
- Bicep 变量/参数使用 camelCase：`vmName`, `osType`, `adminUsername`
- 模块文件名使用 kebab-case：`vm-ubuntu.bicep`, `vm-windows.bicep`

### 参数设计

主模板 `main.bicep` 必须暴露以下参数：

| 参数                | 类型                  | 必填 | 默认值         | 说明                                         |
| ------------------- | --------------------- | ---- | -------------- | -------------------------------------------- |
| `location`          | string                | 否   | 资源组位置     | 部署区域                                     |
| `osType`            | 'Ubuntu' \| 'Windows' | 否   | `Ubuntu`       | 操作系统类型                                 |
| `vmSize`            | string                | 否   | `Standard_B2als_v2` | VM 规格                                      |
| `adminUsername`     | string                | 否   | `azureclaw`    | 管理员用户名                                 |
| `adminPassword`     | securestring          | 否   | 自动生成       | 管理员密码（password 认证）                  |
| `enablePublicHttps` | bool                  | 否   | `true`         | 启用公网 HTTPS（Caddy + Let's Encrypt）      |
| `gatewayPassword`   | securestring          | 否   | 自动生成       | Gateway 认证密码（enablePublicHttps 时使用） |
| `enableFoundry`     | bool                  | 否   | `false`        | 自动创建 Azure AI 资源并部署模型             |
| `foundryModelName`  | string                | 否   | `gpt-4.1`      | 部署的模型名称（enableFoundry 时使用）       |
| `foundryLocation`   | string                | 否   | `eastus`       | Foundry 资源区域（非所有区域都支持所有模型） |

- VM 名称固定为 `openclaw-vm`，不作为用户参数
- SSH 认证方式固定为 password，不暴露 authenticationType 参数
- Ubuntu 镜像固定为 24.04 LTS（offer: ubuntu-24_04-lts, sku: server）
- 资源组名称默认 `rg-openclaw`，可通过 deploy.ps1 的 `-ResourceGroup` 参数或交互模式自定义

### 模块化原则

- `foundry.bicep`：条件创建 Azure AI Services 账户 + 模型部署，输出 endpoint 和 API key
- `network.bicep`：创建 VNet、Subnet、NSG（入站规则）、Public IP，输出子网 ID 和公网 IP ID
- `vm-ubuntu.bicep`：创建 Ubuntu VM + NIC，通过 CustomScript 扩展执行安装脚本
- `vm-windows.bicep`：创建 Windows 11 VM + NIC，通过 CustomScriptExtension 执行安装脚本
- `main.bicep`：调用 network 模块，条件调用 foundry 模块，根据 `osType` 条件部署对应 VM 模块

### Bicep 输出

`main.bicep` 必须输出以下值，供 `deploy.ps1` 捕获写入 logs：

| 输出                | 说明                         |
| ------------------- | ---------------------------- |
| `publicIpAddress`   | VM 公网 IP 地址              |
| `fqdn`              | VM 域名 (cloudapp.azure.com) |
| `vmName`            | VM 名称                      |
| `osType`            | 部署的操作系统类型           |
| `adminUsername`     | 管理员用户名                 |
| `enablePublicHttps` | 是否启用公网 HTTPS           |

### 安全要求

- 密码参数必须使用 `@secure()` 装饰器
- NSG 入站规则：
  - SSH (22) — 仅 Ubuntu
  - RDP (3389) — 仅 Windows
  - Gateway (18789) — enablePublicHttps=false 时开放
  - HTTPS (443) — enablePublicHttps=true 时开放
- 不要在模板中硬编码任何密钥或敏感信息
- Public IP 使用 Static 分配，配置 DNS 标签（`openclaw-<uniqueString>`）
- 当 enablePublicHttps=true 时，Gateway 绑定 loopback，由 Caddy 反向代理处理公网流量

## 部署脚本规范

### `deploy.ps1` 工作流

```
用户运行 deploy.ps1 [-Location eastasia] [-VmSize Standard_B2als_v2] [-OsType Ubuntu] [-AdminUsername azureclaw] [-AdminPassword xxx] [-ResourceGroup rg-openclaw] [-EnablePublicHttps]
    │
    ├─ 1. 参数处理（所有参数有默认值，密码为空则自动生成强密码）
    ├─ 1b. 若 EnablePublicHttps，自动生成 Gateway 密码
    ├─ 2. 检查 az cli 登录状态（未登录则执行 az login）
    ├─ 3. 创建资源组（默认 rg-openclaw，交互模式可选择/自定义）
    ├─ 4. 执行 az deployment group create（部署 Bicep 模板）
    ├─ 5. 捕获部署输出（Public IP、VM 名称等）
    ├─ 6. 创建 logs/{timestamp}/ 目录
    ├─ 7. 写入 logs/{timestamp}/deploy.log（部署参数脱敏 + 部署过程日志）
    ├─ 8. 写入 logs/{timestamp}/.env（敏感信息：密码、连接串）
    ├─ 9. 生成 logs/{timestamp}/guide.md（操作指南，引用 .env 中的变量）
    ├─ 10. 控制台输出摘要 + 指南路径
    └─ 11. 可选：配置 AI 模型（选择现有资源 / 创建新资源 / 手动输入）
```

### `destroy.ps1` 工作流

```
用户运行 destroy.ps1 [-ResourceGroup rg-openclaw] [-Force]
    │
    ├─ 1. 确认提示（除非 -Force）
    ├─ 2. 执行 az group delete --name rg-openclaw --yes
    └─ 3. 输出清理完成信息
```

### logs 目录结构

每次部署在 `logs/` 下创建一个时间戳目录，包含三个文件：

```
logs/20260320143052/
├── deploy.log    # 部署过程日志（参数脱敏、Bicep 输出、耗时等）
├── .env          # 敏感信息，不可提交到 Git
└── guide.md      # 操作指南文档
```

#### `.env` 文件格式

```env
ADMIN_USERNAME=azureclaw
ADMIN_PASSWORD=<实际密码>
VM_PUBLIC_IP=20.xxx.xxx.xxx
FQDN=openclaw-xxxx.eastasia.cloudapp.azure.com
OS_TYPE=Ubuntu
VM_SIZE=Standard_B2als_v2
LOCATION=eastasia
RESOURCE_GROUP=rg-openclaw
ENABLE_PUBLIC_HTTPS=true
GATEWAY_PASSWORD=<Gateway 认证密码>
DEPLOY_TIME=2026-03-20T14:30:52
```

#### `guide.md` 内容（根据 osType 动态生成）

Ubuntu 版本：

```markdown
# OpenClaw 部署操作指南

## 部署信息

- 部署时间: 2026-03-20 14:30:52
- 公网 IP: 20.xxx.xxx.xxx
- 操作系统: Ubuntu 24.04 LTS
- VM 规格: Standard_B2als_v2
- 资源组: rg-openclaw

> 敏感信息（用户名/密码）保存在同目录下的 `.env` 文件中。

## 一、连接远程服务器

使用 SSH 密码登录（用户名和密码参见 `.env` 文件）：
ssh <ADMIN_USERNAME>@<VM_PUBLIC_IP>

## 二、连接 OpenClaw

1. 浏览器访问 Web 控制台: http://<VM_PUBLIC_IP>:18789
2. 检查服务状态: sudo systemctl status openclaw
3. 运行交互式配置: openclaw onboard
4. 查看日志: journalctl -u openclaw -f

## 三、清理资源

.\destroy.ps1
```

Windows 版本：

```markdown
## 一、连接远程服务器

使用远程桌面连接（用户名和密码参见 `.env` 文件）：
mstsc /v:<VM_PUBLIC_IP>

## 二、连接 OpenClaw

1. RDP 登录后打开浏览器访问: http://localhost:18789
2. 打开 PowerShell 运行: openclaw doctor
3. 运行交互式配置: openclaw onboard --install-daemon

## 三、清理资源

.\destroy.ps1
```

## VM 安装脚本编写规范

### Ubuntu 脚本 (`install-openclaw-ubuntu.sh`)

```bash
#!/bin/bash
set -euo pipefail
```

脚本执行流程：

1. 更新系统包 (`apt-get update && apt-get upgrade -y`)
2. 安装依赖 (`curl`, `git`, `build-essential`)
3. 安装 Node.js 24 (通过 NodeSource 官方仓库)
4. 全局安装 OpenClaw (`npm install -g openclaw@latest`)
5. 创建 OpenClaw 配置目录和默认配置 (`~/.openclaw/openclaw.json`)
6. 创建并启用 systemd 服务 (`openclaw.service`)
7. 若 enablePublicHttps：安装 Caddy 反向代理，配置 HTTPS + 密码认证
8. 配置防火墙 (443 或 18789)

### Windows 脚本 (`install-openclaw-windows.ps1`)

脚本执行流程：

1. 启用 WSL2 功能
2. 安装 Ubuntu WSL 发行版
3. 在 WSL 内安装 Node.js 24
4. 在 WSL 内全局安装 OpenClaw
5. 创建默认配置
6. 设置 OpenClaw 作为 Windows 服务或 WSL 内的 systemd 服务
7. 若 enablePublicHttps：安装 Caddy（Windows 原生）反向代理，配置 HTTPS + 密码认证
8. 配置 Windows 防火墙规则 (443 或 18789)

## OpenClaw 相关知识

### 关键端口

- **18789**: Gateway WebSocket + Web UI 默认端口
- **443**: HTTPS (Caddy 反向代理，enablePublicHttps=true 时)

### 关键路径

- `~/.openclaw/`: OpenClaw 主目录
- `~/.openclaw/openclaw.json`: 主配置文件
- `~/.openclaw/workspace/`: 代理工作目录
- `~/.openclaw/credentials/`: 通道认证凭据

### 最小配置

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-opus-4-6",
      },
    },
  },
}
```

### 常用命令

```bash
openclaw onboard --install-daemon  # 交互式设置 + 安装守护进程
openclaw gateway run --port 18789  # 启动 Gateway
openclaw doctor                    # 诊断检查
openclaw dashboard                 # 打开 Web UI
```

### systemd 服务单元

```ini
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<admin_user>
ExecStart=/usr/bin/openclaw gateway run --port 18789 --bind lan --auth password
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=OPENCLAW_GATEWAY_PASSWORD=<gateway_password>

[Install]
WantedBy=multi-user.target
```

## 开发工作流

### 修改 Bicep 后

```bash
# 验证模板
az bicep build --file infra/main.bicep

# 预览部署（what-if）
az deployment group what-if \
  --resource-group rg-openclaw \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json

# 导出 ARM 模板供 Portal 一键部署
az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
```

### 测试安装脚本

```bash
# Ubuntu 脚本本地测试（在 WSL 或 Ubuntu VM 中）
bash scripts/install-openclaw-ubuntu.sh

# Windows 脚本测试（在 Windows VM 或本地 PowerShell 中）
powershell -ExecutionPolicy Bypass -File scripts/install-openclaw-windows.ps1
```

## 代码风格

- Bicep 文件使用 2 空格缩进
- Shell 脚本使用 2 空格缩进，开头包含 `set -euo pipefail`
- PowerShell 脚本使用 4 空格缩进，开头包含 `$ErrorActionPreference = 'Stop'`
- 所有注释使用英文（代码即文档），README 等面向用户的文档使用中文
- 变量和资源描述使用英文

## 注意事项

- Windows 11 上 OpenClaw 官方推荐通过 WSL2 运行，脚本应遵循此建议
- 部署脚本必须是幂等的（多次执行不会出错）
- 不要在脚本中硬编码版本号，使用 `@latest` 或参数化
- Gateway 默认绑定 `127.0.0.1`，无 HTTPS 时需要绑定到 `0.0.0.0` 以便远程访问
- 当 enablePublicHttps=true 时，Caddy 处理公网流量，Gateway 保持 loopback 绑定
- 启用公网 HTTPS 时自动配置 `gateway.auth.mode: "password"` + `OPENCLAW_GATEWAY_PASSWORD`
- 生产环境应配置认证（`gateway.auth.mode: "password"`），不要裸奔
- 敏感信息（密码等）只写入 `logs/{timestamp}/.env`，不要出现在 `.log` 或 `guide.md` 中
- `logs/` 目录整体在 `.gitignore` 中忽略
