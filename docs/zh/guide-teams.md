# 操作手册：配置 Microsoft Teams 作为消息通道

本手册介绍如何将 **Microsoft Teams** 连接到 OpenClaw Gateway，让你直接在 Teams 的 DM、群组聊天或频道中与 AI 助手对话。

> **复杂度提示**: Teams 集成比 Slack/Telegram 更复杂，需要创建 Azure Bot 资源、制作 Teams App Manifest 并上传。建议预留 30-60 分钟完成全部配置。

---

## 目录

1. [前置条件](#一前置条件)
2. [安装 Teams 插件](#二安装-teams-插件)
3. [创建 Azure Bot](#三创建-azure-bot)
4. [获取凭据](#四获取凭据)
5. [配置消息端点](#五配置消息端点)
6. [启用 Teams 频道](#六启用-teams-频道)
7. [创建 Teams App Manifest](#七创建-teams-app-manifest)
8. [上传 Teams App](#八上传-teams-app)
9. [配置 OpenClaw](#九配置-openclaw)
10. [验证连接](#十验证连接)
11. [高级配置](#十一高级配置)
12. [常见问题](#十二常见问题)

---

## 一、前置条件

- 已完成 Azure Claw 部署（参见主 [README](../../README.md)）
- 已配置 AI 模型提供商（参见 [Microsoft Foundry 配置手册](guide-microsoft-foundry.md) 或使用其他提供商）
- 已通过 SSH (Ubuntu) 或 RDP (Windows) 连接到 VM
- **必须启用 `-EnablePublicHttps`**（Teams Webhook 要求 HTTPS 端点）或有其他方式暴露 HTTPS 端点
- 拥有 Azure AD（Microsoft Entra ID）管理权限（创建 App Registration）
- 拥有 Teams 管理员权限（或可请求管理员批准 App 上传）

> **重要**: Teams Bot 仅支持 **HTTPS** 端点。如果你部署时未启用 `-EnablePublicHttps`，需要通过 Tailscale Funnel 或 ngrok 等方式提供 HTTPS 访问。强烈建议使用 `-EnablePublicHttps` 部署。

---

## 半自动化配置（推荐）

本项目提供 `setup-teams.ps1` 脚本，可自动完成以下步骤：

- 创建 App Registration + Client Secret
- 创建 Azure Bot (F0 免费层)
- 配置消息端点 + 启用 Teams 频道
- 远程安装 Teams 插件到 VM
- 更新 Caddy 反向代理 / 端口转发配置
- 注入 Teams 凭据到 OpenClaw 配置并重启服务
- 生成 Teams App 包（manifest.json + 图标 + ZIP）

```powershell
# 自动检测 rg-openclaw 中的现有部署
.\setup-teams.ps1

# 指定资源组和 Bot 名称
.\setup-teams.ps1 -ResourceGroup rg-openclaw -BotName my-openclaw-bot
```

脚本完成后，你只需手动执行一步：**将生成的 `openclaw-teams-app.zip` 上传到 Teams**（参见[第八章](#八上传-teams-app)）。

> 输出目录 `logs/teams-<timestamp>/` 包含：
>
> - `setup-teams.log` — 配置日志
> - `.env` — Teams 凭据（App ID、Secret、Tenant ID）
> - `openclaw-teams-app.zip` — 直接上传到 Teams 的应用包

如果你更喜欢完全手动配置，请继续阅读下方的分步指南。

---

## 二、安装 Teams 插件

Microsoft Teams 以插件形式提供，不包含在 OpenClaw 核心安装中。

SSH 登录到 VM 后（Windows 则在 WSL 中操作）：

```bash
openclaw plugins install @openclaw/msteams
```

验证安装：

```bash
openclaw plugins list
# 应看到 @openclaw/msteams
```

---

## 三、创建 Azure Bot

### 方式 A：Azure Portal

1. 前往 [创建 Azure Bot](https://portal.azure.com/#create/Microsoft.AzureBot)
2. 填写 **Basics** 标签页：

| 字段               | 值                                 |
| ------------------ | ---------------------------------- |
| **Bot handle**     | `openclaw-msteams`（必须全局唯一） |
| **Subscription**   | 选择你的 Azure 订阅                |
| **Resource group** | 可使用 `rg-openclaw` 或新建        |
| **Pricing tier**   | `Free`（开发/测试足够）            |
| **Type of App**    | **Single Tenant**（推荐）          |
| **Creation type**  | Create new Microsoft App ID        |

> **注意**: 自 2025-07-31 起，新创建的 Bot 不再支持 Multi-Tenant 类型，请使用 **Single Tenant**。

3. 点击 **Review + create** → **Create**（等待 1-2 分钟）

### 方式 B：Azure CLI

```bash
# 创建 Azure Bot 资源
az bot create \
  --resource-group rg-openclaw \
  --name openclaw-msteams \
  --kind registration \
  --sku F0
```

---

## 四、获取凭据

你需要收集三项凭据：

### 4.1 获取 App ID

1. 进入刚创建的 Azure Bot 资源
2. 左侧菜单 → **Configuration**
3. 复制 **Microsoft App ID**（格式：`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`）

### 4.2 获取 App Password（Client Secret）

1. 在 Configuration 页面，点击 **Manage Password**（跳转到 App Registration）
2. 左侧菜单 → **Certificates & secrets**
3. 点击 **+ New client secret**
4. 填写描述（如 `openclaw-secret`），选择过期时间
5. 点击 **Add**
6. **立即复制 Value 列的值** — 这就是 `appPassword`

> **重要**: Client Secret 只在创建时显示一次，离开页面后无法再查看。如丢失需重新创建。

### 4.3 获取 Tenant ID

1. 在 App Registration 页面 → **Overview**
2. 复制 **Directory (tenant) ID**

### 凭据汇总

| 凭据             | 来源                                      | 用途         |
| ---------------- | ----------------------------------------- | ------------ |
| **App ID**       | Azure Bot → Configuration                 | Bot 身份标识 |
| **App Password** | App Registration → Certificates & secrets | Bot 认证密钥 |
| **Tenant ID**    | App Registration → Overview               | 租户 ID      |

---

## 五、配置消息端点

Teams 通过 HTTPS Webhook 将消息发送到你的 Bot。你需要设置一个公网可达的 HTTPS 端点。

### 使用 Azure Claw HTTPS 模式（推荐）

如果你部署时使用了 `-EnablePublicHttps`，Caddy 已经在 443 端口提供 HTTPS。你需要在 Caddy 中添加 Teams Webhook 的反向代理规则。

SSH 登录到 VM，编辑 Caddyfile：

```bash
sudo nano /etc/caddy/Caddyfile
```

修改为：

```
<你的FQDN> {
    # OpenClaw Gateway WebSocket + Web UI
    reverse_proxy /api/messages 127.0.0.1:3978
    reverse_proxy 127.0.0.1:18789
}
```

> 将 `<你的FQDN>` 替换为 `.env` 文件中的 `FQDN` 值，例如 `openclaw-xxxx.eastasia.cloudapp.azure.com`。

重新加载 Caddy：

```bash
sudo systemctl reload caddy
```

你的消息端点为：`https://<FQDN>/api/messages`

### 设置 Azure Bot 端点

1. 回到 Azure Portal → Azure Bot 资源 → **Configuration**
2. 设置 **Messaging endpoint** 为：
   ```
   https://<你的FQDN>/api/messages
   ```
3. 点击 **Apply**

---

## 六、启用 Teams 频道

1. 在 Azure Bot 资源中，左侧菜单 → **Channels**
2. 点击 **Microsoft Teams**
3. 点击 **Configure** → **Save**
4. 接受 Terms of Service

---

## 七、创建 Teams App Manifest

Teams App 需要一个 Manifest 包（ZIP 文件），包含 `manifest.json` 和两个图标文件。

### 7.1 创建图标文件

准备两个 PNG 图标：
- `color.png` — 192×192 像素，彩色图标
- `outline.png` — 32×32 像素，线框图标（白色线条 + 透明背景）

> **快速方式**: 可以用任意 192×192 和 32×32 的 PNG 图片作为占位。

### 7.2 创建 manifest.json

创建 `manifest.json`，替换其中的 `<APP_ID>` 为你的 Microsoft App ID：

```json
{
    "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.23/MicrosoftTeams.schema.json",
    "manifestVersion": "1.23",
    "version": "1.0.0",
    "id": "<APP_ID>",
    "name": {
        "short": "OpenClaw"
    },
    "developer": {
        "name": "Azure Claw",
        "websiteUrl": "https://openclaw.ai",
        "privacyUrl": "https://openclaw.ai/privacy",
        "termsOfUseUrl": "https://openclaw.ai/terms"
    },
    "description": {
        "short": "OpenClaw AI 助手",
        "full": "通过 Microsoft Teams 与 OpenClaw AI 助手对话"
    },
    "icons": {
        "outline": "outline.png",
        "color": "color.png"
    },
    "accentColor": "#5B6DEF",
    "bots": [
        {
            "botId": "<APP_ID>",
            "scopes": [
                "personal",
                "team",
                "groupChat"
            ],
            "isNotificationOnly": false,
            "supportsCalling": false,
            "supportsVideo": false,
            "supportsFiles": true
        }
    ],
    "webApplicationInfo": {
        "id": "<APP_ID>"
    },
    "authorization": {
        "permissions": {
            "resourceSpecific": [
                {
                    "name": "ChannelMessage.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "ChannelMessage.Send.Group",
                    "type": "Application"
                },
                {
                    "name": "Member.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "Owner.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "ChannelSettings.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "TeamMember.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "TeamSettings.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "ChatMessage.Read.Chat",
                    "type": "Application"
                }
            ]
        }
    }
}
```

### 7.3 打包 ZIP

将三个文件放在同一目录，打包为 ZIP：

```bash
zip openclaw-teams-app.zip manifest.json color.png outline.png
```

> **替代方式**: 也可以使用 [Teams Developer Portal](https://dev.teams.microsoft.com/apps) 在线创建 App，省去手动编辑 JSON Manifest 的步骤。操作方法：
> 1. 点击 **+ New app** → 填写基本信息
> 2. **App features** → **Bot** → 选择 "Enter a bot ID manually" → 粘贴 App ID
> 3. 勾选 Scopes: Personal, Team, Group Chat
> 4. **Distribute** → **Download app package** 下载 ZIP

---

## 八、上传 Teams App

### 方式 A：通过 Teams 客户端上传（Sideload）

1. 打开 Teams 客户端
2. 左侧边栏 → **Apps** → **Manage your apps**
3. 点击 **Upload an app** → **Upload a custom app**
4. 选择刚才创建的 `openclaw-teams-app.zip`
5. 确认安装

> **如果上传失败**: 尝试选择 "Upload an app to your org's app catalog" 而不是 "Upload a custom app"，这通常可以绕过 Sideload 限制。

### 方式 B：通过 Teams Admin Center 上传

1. 前往 [Teams Admin Center](https://admin.teams.microsoft.com/)
2. **Teams apps** → **Manage apps**
3. 点击 **Upload new app** → 选择 ZIP 文件
4. 安装完成后，在 Teams 中搜索 "OpenClaw" 并添加

### 安装到团队

安装 App 后，还需要将 Bot 添加到具体的团队/频道：

1. 进入目标团队
2. 点击团队名称 → **Manage team** → **Apps**
3. 搜索并添加 "OpenClaw"

---

## 九、配置 OpenClaw

SSH 登录到 VM 后（Windows 则在 WSL 中操作），配置 Teams 通道。

### 方式 A：使用 `openclaw onboard` 交互式配置

```bash
openclaw onboard
```

在交互式向导中：
1. 选择 Add Channel → **Microsoft Teams**
2. 输入 App ID
3. 输入 App Password（Client Secret）
4. 输入 Tenant ID
5. 确认 Webhook 端口和路径
6. 完成配置

### 方式 B：手动编辑配置文件

```bash
nano ~/.openclaw/openclaw.json
```

添加 Teams 通道配置：

```jsonc
{
  "agent": {
    "model": "azure/gpt-4o"  // 或其他模型
  },
  "channels": {
    "msteams": {
      "enabled": true,
      "appId": "<APP_ID>",
      "appPassword": "<APP_PASSWORD>",
      "tenantId": "<TENANT_ID>",
      "webhook": {
        "port": 3978,
        "path": "/api/messages"
      }
    }
  }
}
```

也可以使用环境变量代替配置文件中的敏感信息：

```bash
export MSTEAMS_APP_ID="<APP_ID>"
export MSTEAMS_APP_PASSWORD="<APP_PASSWORD>"
export MSTEAMS_TENANT_ID="<TENANT_ID>"
```

### 配置字段说明

| 字段           | 必填 | 说明                                 |
| -------------- | ---- | ------------------------------------ |
| `enabled`      | 是   | 启用 Teams 通道                      |
| `appId`        | 是   | Azure Bot 的 Microsoft App ID        |
| `appPassword`  | 是   | App Registration 的 Client Secret    |
| `tenantId`     | 是   | Azure AD 租户 ID                     |
| `webhook.port` | 否   | Webhook 监听端口（默认 `3978`）      |
| `webhook.path` | 否   | Webhook 路径（默认 `/api/messages`） |

### 重启服务

```bash
# Ubuntu
sudo systemctl restart openclaw

# 检查状态
sudo systemctl status openclaw
```

---

## 十、验证连接

### 10.1 检查 Gateway 日志

```bash
journalctl -u openclaw -f
```

正常启动应看到类似输出：

```
OpenClaw Gateway started on 127.0.0.1:18789
Channel connected: Microsoft Teams (webhook on :3978)
Listening for Teams events...
```

### 10.2 通过 Azure Web Chat 测试

在上传 Teams App 之前，可以先用 Azure 内置的 Web Chat 验证 Webhook 是否正常：

1. Azure Portal → Azure Bot 资源 → **Test in Web Chat**
2. 发送一条消息
3. 确认收到 AI 回复

> 这一步可以确认你的 Webhook 端点是否正确连接，排除 Teams App 本身的问题。

### 10.3 在 Teams 中测试

#### 测试 DM（直接消息）

1. 在 Teams 左侧边栏的 **Apps** 中找到 OpenClaw
2. 点击打开 → 发送一条 DM 消息
3. 等待 AI 回复

#### 测试频道 @提及

1. 确保 Bot 已添加到目标团队
2. 在频道中发送 `@OpenClaw 你好`
3. Bot 应在频道中回复

> **注意**: 频道中默认需要 @提及才会触发 Bot 回复。可通过 `requireMention: false` 配置更改此行为。

### 10.4 运行诊断

```bash
openclaw doctor
```

确保 `Microsoft Teams channel` 检查项显示为 ✅ Connected。

---

## 十一、高级配置

### 11.1 访问控制

#### DM 访问策略

默认 DM 策略为 `pairing`（配对模式），未知发送者的消息会被忽略，需要管理员批准。

```jsonc
{
  "channels": {
    "msteams": {
      // pairing: 需要配对审批（默认）
      // allowlist: 仅允许列表中的用户
      // open: 允许所有人
      // disabled: 禁用 DM
      "dmPolicy": "pairing",
      // 使用 AAD Object ID（推荐，比用户名更稳定）
      "allowFrom": ["<aad-object-id-1>", "<aad-object-id-2>"]
    }
  }
}
```

#### 群组/频道访问策略

默认群组策略为 `allowlist`（白名单模式），Bot 不会在未授权的群组/频道中响应。

```jsonc
{
  "channels": {
    "msteams": {
      // allowlist: 仅允许列表中的群组（默认）
      // open: 允许任何群组（仍需 @提及）
      // disabled: 禁用群组响应
      "groupPolicy": "allowlist",
      "groupAllowFrom": ["user@org.com"],
      // 按团队/频道精细控制
      "teams": {
        "<team-id>": {
          "channels": {
            "<channel-id>": {
              "requireMention": true
            }
          }
        }
      }
    }
  }
}
```

### 11.2 回复样式

Teams 频道有两种 UI 样式，需要根据频道实际设置选择：

| 样式                    | 说明                      | `replyStyle` 值  |
| ----------------------- | ------------------------- | ---------------- |
| **Posts**（经典）       | 消息显示为卡片 + 线程回复 | `thread`（默认） |
| **Threads**（类 Slack） | 消息线性排列              | `top-level`      |

```jsonc
{
  "channels": {
    "msteams": {
      "replyStyle": "thread",
      "teams": {
        "<team-id>": {
          "channels": {
            "<channel-id>": {
              "replyStyle": "top-level"
            }
          }
        }
      }
    }
  }
}
```

### 11.3 启用 Graph API（频道文件/图片支持）

默认情况下，频道中的图片/文件附件无法被 Bot 读取（只有 HTML 占位符）。如需支持，需要添加 Microsoft Graph 权限：

1. 在 Entra ID → App Registration 中添加 **Microsoft Graph Application 权限**：
   - `ChannelMessage.Read.All`（读取频道消息附件 + 历史）
   - `Chat.Read.All`（读取群组聊天）
2. 点击 **Grant admin consent**（需要管理员权限）
3. 更新 Teams App Manifest 版本号，重新打包上传

#### 在群组/频道中发送文件

群组/频道中发送文件需要额外配置 SharePoint：

1. 添加 Graph API 权限：
   - `Sites.ReadWrite.All`（Application）— 上传文件到 SharePoint
   - `Chat.Read.All`（Application）— 可选，启用针对用户的共享链接
2. 获取 SharePoint Site ID：

```bash
# 通过 Graph Explorer 或 curl
curl -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/sites/<hostname>:/<site-path>"
```

3. 配置 OpenClaw：

```jsonc
{
  "channels": {
    "msteams": {
      "sharePointSiteId": "<site-id>"
    }
  }
}
```

### 11.4 消息历史

```jsonc
{
  "channels": {
    "msteams": {
      // 频道/群组消息历史条数（默认 50，设为 0 禁用）
      "historyLimit": 50,
      // DM 历史条数
      "dmHistoryLimit": 50
    }
  }
}
```

---

## 十二、常见问题

### Q: 测试 Web Chat 出现 `401 Unauthorized`

这是正常现象 — 说明你的端点是可达的，但没有通过 Azure JWT 认证。请使用 Azure Portal 的 **Test in Web Chat** 功能测试，而不是直接用浏览器访问。

### Q: Teams 中发送消息没有回复

1. 确认 Gateway 已启动并监听 3978 端口：`journalctl -u openclaw -f`
2. 确认 Azure Bot 的 Messaging Endpoint 设置正确
3. 频道中默认需要 @提及，检查是否正确 `@OpenClaw`
4. 运行 `openclaw doctor` 查看 Teams 连接状态

### Q: 频道中图片无法显示

- 这是 Teams 的限制：图片/文件存储在 SharePoint/OneDrive 中，Bot 默认无法访问
- 需要为 App Registration 添加 Microsoft Graph 权限并获得管理员同意（参见 [11.3 启用 Graph API](#113-启用-graph-api频道文件图片支持)）

### Q: 上传 Manifest 报错 "Icon file cannot be empty"

- Manifest ZIP 中引用的图标文件是 0 字节或不存在
- 确保 `color.png`（192×192）和 `outline.png`（32×32）是有效的 PNG 文件

### Q: 上传 Manifest 报错 "webApplicationInfo.Id already in use"

- App 已在其他团队/聊天中安装。先卸载旧版本，或等待 5-10 分钟让变更传播
- 也可以通过 [Teams Admin Center](https://admin.teams.microsoft.com/) 上传

### Q: Bot 在私有频道中不工作

- 这是 Teams 的已知限制。Bot 对私有频道的支持有限
- 替代方案：使用标准频道进行 Bot 交互，或直接使用 DM

### Q: 消息回复延迟或重复

- Teams 通过 HTTP Webhook 发送消息，如果 AI 模型响应慢，可能导致：
  - Gateway 超时
  - Teams 重试消息（产生重复回复）
- OpenClaw 会快速返回响应并异步发送 AI 回复，但极慢的模型响应仍可能有问题
- 建议使用响应速度较快的模型（如 `gpt-4o-mini`）

### Q: 如何获取 Team ID 和 Channel ID？

**Team ID** 和 **Channel ID** 需要从 Teams URL 中提取（注意不是 `groupId` 参数）：

```
Team URL:
https://teams.microsoft.com/l/team/19%3ABk4j...%40thread.tacv2/conversations?groupId=...
                                    └────────────────────────────┘
                                    Team ID（URL 解码后使用）

Channel URL:
https://teams.microsoft.com/l/channel/19%3A15bc...%40thread.tacv2/ChannelName?groupId=...
                                      └─────────────────────────┘
                                      Channel ID（URL 解码后使用）
```

> **注意**: URL 中的 `groupId` 查询参数不是 Team ID，不要使用。

### Q: 如何更新已安装的 App？

1. 修改 `manifest.json` 中的设置
2. 递增 `version` 字段（如 `1.0.0` → `1.1.0`）
3. 重新打包 ZIP 并上传
4. 在每个团队中重新安装 App 以使新权限生效
5. 完全退出并重新启动 Teams（不只是关闭窗口），清除缓存

---

## 安全建议

1. **使用 HTTPS**: Teams Webhook 必须使用 HTTPS 端点，确保部署时启用 `-EnablePublicHttps`
2. **保护凭据**: `appPassword` 是敏感信息，不要提交到代码仓库或分享给他人
3. **使用 AAD Object ID**: 在 `allowFrom` 中使用稳定的 AAD Object ID 而非用户名（用户名可变）
4. **限制群组访问**: 保持默认的 `groupPolicy: "allowlist"`，仅允许授权群组使用 Bot
5. **定期轮转密钥**: 定期在 App Registration 中重新生成 Client Secret
6. **审计日志**: 定期检查 `journalctl -u openclaw` 中的 Teams 事件日志

---

## 参考链接

- [OpenClaw Microsoft Teams 文档](https://docs.openclaw.ai/channels/msteams)
- [创建 Azure Bot](https://learn.microsoft.com/azure/bot-service/bot-service-quickstart-registration) — Azure Bot 设置指南
- [Teams Developer Portal](https://dev.teams.microsoft.com/apps) — 创建/管理 Teams App
- [Teams App Manifest Schema](https://learn.microsoft.com/microsoftteams/platform/resources/schema/manifest-schema)
- [RSC 权限参考](https://learn.microsoft.com/microsoftteams/platform/graph-api/rsc/resource-specific-consent)
- [Teams Bot 文件处理](https://learn.microsoft.com/microsoftteams/platform/bots/how-to/bots-filesv4)
- [Proactive Messaging](https://learn.microsoft.com/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages)
