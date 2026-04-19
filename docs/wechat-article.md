# 一键将 OpenClaw 部署到 Azure

> **Azure Claw**：一条命令把开源 AI 助手 **OpenClaw** 部署到 **Azure** 虚拟机，支持 Ubuntu / Windows，默认公网 HTTPS + 密码认证，7×24 小时在线。

## Azure Claw 是什么

[Azure Claw](https://github.com/shuaihuadu/azure-claw) 是一个开源的一键部署项目，专门解决一件事：**把 OpenClaw 稳定地、可重现地跑到 Azure 云端**。

- 🚀 **一键部署**：一条 `deploy.ps1` 命令完成全部基础设施 + 软件安装，全程 8-10 分钟
- 🖥️ **双系统可选**：Ubuntu 24.04 LTS（默认推荐）/ Windows 11 + WSL2
- 🔒 **默认生产姿势**：Caddy 反向代理 + Let's Encrypt 自动证书 + Gateway 密码认证 + 设备配对
- 📦 **基础设施即代码**：Bicep 模板管理 VNet / NSG / VM，也可用 Azure Portal「Deploy to Azure」一键按钮
- 🧹 **清理利索**：`destroy.ps1` 一条命令干净收场，资源组整体删除
- 📝 **完整文档**：中英双语运维手册，涵盖 Slack / Teams / 故障排查 / 升级备份

> **说明**：OpenClaw 本身不必多介绍了——自托管 AI 助手网关，把 Telegram / Slack / Teams / Discord / iMessage 等统一接到后端 AI 模型（Claude / GPT / Gemini / Azure OpenAI）上。详见 [openclaw.ai](https://openclaw.ai/)。

## 为什么要把 OpenClaw 部署到云端

本地跑玩玩没问题，但要让它成为**你真正天天在用的"个人 AI 助手"**，本地方案很快就会遇到瓶颈：

| 维度                   | 本地机器                     | Azure 云端               |
| ---------------------- | ---------------------------- | ------------------------ |
| **在线时长**           | 关机 / 睡眠就失联            | 7×24 常驻                |
| **公网可达**           | NAT 穿透、内网穿透，配到头秃 | 自带公网 IP + HTTPS 域名 |
| **网络质量**           | 家宽上行小、IP 经常变        | 机房带宽稳定、IP 固定    |
| **iOS/Android 客户端** | 外网连不上，只能在家用       | 任何地方随时连           |
| **算力占用**           | 挂后台吃本机 CPU/内存        | 独立 VM，不抢本机资源    |
| **和朋友/团队共享**    | 别人连不进来                 | 给个链接 + 密码即可      |
| **可重现部署**         | 换台电脑全要重来             | 一条命令全自动复刻       |

一句话：**云上跑的 OpenClaw，才是你能拿出去用、拿出去分享的 OpenClaw**。

Azure Claw 要做的，就是把"云上跑"这件事收敛成一条命令。

## 这就是 Azure Claw 要解决的事

**一句话**：一条 PowerShell 命令，把 OpenClaw 部署到 Azure 上，带公网 HTTPS + 自动证书 + 密码认证，开机即用。

```powershell
.\deploy.ps1
```

就这一行。脚本会：

1. 自动登录 Azure、选订阅、选区域、选 VM 规格；
2. 跑 Bicep 模板创建 VNet / NSG / Public IP / VM；
3. 在 VM 里装 Node.js、OpenClaw、Caddy、jq；
4. 申请 Let's Encrypt 证书；
5. 启用 systemd 常驻 + 崩溃自动重启；
6. 把凭据写到本地 `logs/<时间戳>/.env`，生成一份量身定做的 `guide.md`。

部署完成，浏览器打开 Azure 自动分配的域名（形如 `https://openclaw-xxxx.eastasia.cloudapp.azure.com`，**不用你自己买域名**），输入密码，在服务器上执行 `openclaw onboard` 配好模型和通道，就可以在 Telegram 里和你自己的 AI 助手聊天了。

## 为什么值得一试

### 一、真的是"一键"

不是那种装好 Azure CLI 再自己写 parameters.json 的"一键"，是真的**零参数跑**：

- 不写参数 → 交互式引导，实时查询你订阅里可用的区域和 VM 规格，避免选到不可用的；
- 想自动化 → 所有参数都可以传命令行，跑 CI/CD 无压力；
- 失败会告诉你为什么失败，而不是丢一堆乱码给你。

### 二、双系统镜像可选

| 系统              | 推荐场景                   |
| ----------------- | -------------------------- |
| Ubuntu 24.04 LTS  | 默认推荐，资源占用最小     |
| Windows 11 + WSL2 | 需要 Office/桌面工具时可选 |

一个 `-OsType` 参数切换，脚本会分别跑两套安装流程。

### 三、默认就是生产可用的姿势

很多教程里的 "OpenClaw quick start" 是 `openclaw gateway run`，然后暴露 18789 裸奔。

Azure Claw 默认配置是：

- **Caddy 反向代理**在 443 端口，Let's Encrypt 自动续签证书；
- Gateway 绑定 loopback，外网只能走 HTTPS；
- Gateway **强制密码认证**（`gateway.auth.mode: "password"`），密码自动生成 16 位强密码；
- 新设备登录需要在服务器上 `openclaw devices approve --latest` 审批，设备配对机制防止密码泄露后被滥用；
- systemd 管理，崩溃自动重启、开机自启。

一句话：部署完就是"可以放心发给朋友用"的状态。

### 四、一份真正好用的操作手册

部署完在 `logs/<时间戳>/guide.md` 里有一份量身定做的指南，涵盖：

- 连接服务器（SSH / RDP）
- 登录 Web 控制台、首次配对流程
- 查看 / 重置 Gateway 密码
- 生成 Control Token（macOS / iOS / Android 客户端远程连接用）
- 配置访问 Origin（解决 403 CORS）
- 故障排查（502、服务挂了、OOM、磁盘满等）
- 升级 / 备份 / 清理

中英双语：[中文运维手册](https://github.com/shuaihuadu/azure-claw/blob/main/docs/zh/guide-operations.md) · [English Ops Guide](https://github.com/shuaihuadu/azure-claw/blob/main/docs/en/guide-operations.md)

### 五、想清理？一条命令干净收场

```powershell
.\destroy.ps1
```

把整个资源组删掉，不留任何残留资源。

## 开箱体验（≈ 10 分钟）

### 前置条件

- Azure 订阅（[注册入口](https://azure.microsoft.com/)）
- Azure CLI（[安装指南](https://learn.microsoft.com/cli/azure/install-azure-cli)）
- PowerShell 7+（macOS / Linux 也能跑，不是 Windows 专属）
- 一个 AI 模型的 API Key（Claude / OpenAI / Azure OpenAI 任选其一）

### 三步搞定

```powershell
# 1. 克隆仓库
git clone https://github.com/shuaihuadu/azure-claw.git
cd azure-claw

# 2. 登录 Azure
az login

# 3. 一键部署（全程约 8-10 分钟）
.\deploy.ps1
```

部署完成后，按 `logs/<时间戳>/guide.md` 里的步骤：

1. SSH 进 VM，运行 `openclaw onboard` 填 API Key、选通道（推荐先玩 Telegram，只需要一个 Bot Token）
2. 浏览器打开 `https://<Azure 分配的域名>`，用 `.env` 里的 `GATEWAY_PASSWORD` 登录，页面会提示 "pairing required"
3. 回到 SSH 执行 `openclaw devices approve --latest` 审批这次配对
4. 掏出手机，打开 Telegram，开始聊

## 适合谁用

- 想搞一个 7×24 在线、可以 Telegram 随时撸的个人 AI 助手的开发者
- 受够本地跑 Bot 老断线的重度玩家
- 想在 Teams / Slack 里挂个"团队小助手"的 Tech Lead
- 打算写 AI Agent 教程、想要一套干净部署模板的技术博主
- 学 Azure / Bicep 想找一个真实完整的项目练手的同学

## 仓库链接

> **GitHub**：[https://github.com/shuaihuadu/azure-claw](https://github.com/shuaihuadu/azure-claw)
>
> 一键部署按钮：README 里的 "Deploy to Azure" 按钮（免克隆，点一下就进 Portal 填表单）
>
> 欢迎 Star、Issue、PR。遇到问题可以直接提 Issue，看到会第一时间回。

## 最后

OpenClaw 本身是个很酷的项目，但把它稳定地、可重现地、带 HTTPS 和认证地跑到云上，中间还有不少琐碎的配置和踩坑。

Azure Claw 把这些都封装好了：**帮你把"我想在云上跑一个自己的 AI 助手"这个念头，收敛到一条命令里**。

如果觉得有用，欢迎转发、Star、告诉身边想折腾 AI Agent 的朋友。

---

**相关链接**

- OpenClaw 官网：<https://openclaw.ai/>
- OpenClaw 文档：<https://docs.openclaw.ai/>
- Azure Claw 仓库：<https://github.com/shuaihuadu/azure-claw>
- Azure 官网：<https://azure.microsoft.com/>
