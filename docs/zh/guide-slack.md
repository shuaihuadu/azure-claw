# 操作手册：配置 Slack 作为消息通道

本手册介绍如何将 **Slack** 连接到 OpenClaw Gateway，让你直接在 Slack 中与 AI 助手对话。配置完成后，你可以在 Slack 的 DM 或频道中 @Bot 来调用 AI 助手。

---

## 目录

1. [前置条件](#一前置条件)
2. [创建 Slack App](#二创建-slack-app)
3. [配置 Bot 权限](#三配置-bot-权限)
4. [启用事件订阅](#四启用事件订阅)
5. [安装 App 到 Workspace](#五安装-app-到-workspace)
6. [获取 Token 和密钥](#六获取-token-和密钥)
7. [配置 OpenClaw](#七配置-openclaw)
8. [验证连接](#八验证连接)
9. [高级配置](#九高级配置)
10. [常见问题](#十常见问题)

---

## 一、前置条件

- 已完成 Azure Claw 部署（参见主 [README](../../README.md)）
- 已配置 AI 模型提供商（参见 [Microsoft Foundry 配置手册](guide-microsoft-foundry.md) 或使用其他提供商）
- 拥有 Slack Workspace 管理员权限（或可请求管理员批准 App 安装）
- VM 的 18789 端口可从公网访问（NSG 已配置）

---

## 二、创建 Slack App

### 方式 A：使用 App Manifest 创建（推荐）

使用 Manifest 可以一步完成 App 创建、权限配置、事件订阅和 Socket Mode 启用，无需手动逐项设置。

1. 前往 [Slack API: Your Apps](https://api.slack.com/apps)
2. 点击 **Create New App**
3. 选择 **From an app manifest**
4. 选择你的 Slack Workspace → 点击 **Next**
5. 选择 **JSON** 格式，将以下 Manifest 粘贴到编辑框中：

```json
{
    "display_information": {
        "name": "OpenClaw",
        "description": "Slack connector for OpenClaw"
    },
    "features": {
        "app_home": {
            "home_tab_enabled": false,
            "messages_tab_enabled": true,
            "messages_tab_read_only_enabled": false
        },
        "bot_user": {
            "display_name": "OpenClaw",
            "always_online": false
        },
        "slash_commands": [
            {
                "command": "/openclaw",
                "description": "Send a message to OpenClaw",
                "should_escape": false
            }
        ]
    },
    "oauth_config": {
        "scopes": {
            "bot": [
                "chat:write",
                "chat:write.public",
                "channels:history",
                "channels:read",
                "groups:history",
                "im:history",
                "im:read",
                "im:write",
                "mpim:history",
                "users:read",
                "app_mentions:read",
                "reactions:read",
                "reactions:write",
                "pins:read",
                "pins:write",
                "emoji:read",
                "commands",
                "files:read",
                "files:write"
            ]
        },
        "pkce_enabled": false
    },
    "settings": {
        "event_subscriptions": {
            "bot_events": [
                "app_mention",
                "message.channels",
                "message.groups",
                "message.im",
                "message.mpim",
                "reaction_added",
                "reaction_removed",
                "member_joined_channel",
                "member_left_channel",
                "channel_rename",
                "pin_added",
                "pin_removed"
            ]
        },
        "interactivity": {
            "is_enabled": true
        },
        "org_deploy_enabled": false,
        "socket_mode_enabled": true,
        "token_rotation_enabled": false
    }
}
```

6. 点击 **Next** → 预览配置摘要 → 点击 **Create**
7. App 创建成功后自动跳转到管理页面

> **使用 Manifest 创建后，第三步（配置 Bot 权限）和第四步（启用事件订阅）已自动完成**，可直接跳到[第三步的 3.2 节](#32-生成-app-level-token)生成 App-Level Token，然后继续[第五步](#五安装-app-到-workspace)。

### 方式 B：手动创建（From Scratch）

1. 前往 [Slack API: Your Apps](https://api.slack.com/apps)
2. 点击 **Create New App**
3. 选择 **From scratch**
4. 填写信息：
   - **App Name**: `OpenClaw` （或你喜欢的名称）
   - **Workspace**: 选择你的 Slack Workspace
5. 点击 **Create App**

创建后会进入 App 管理页面，继续按第三步和第四步手动配置。

---

## 三、配置 Bot 权限

> **提示**: 如果你在第二步中使用了 **App Manifest** 创建，权限和 Slash Command 已自动配置，可直接跳到 [3.2 生成 App-Level Token](#32-生成-app-level-token)。

### 3.1 添加 Bot Token Scopes

1. 左侧菜单 → **OAuth & Permissions**
2. 向下滚动到 **Scopes** → **Bot Token Scopes**
3. 点击 **Add an OAuth Scope**，逐一添加以下权限：

| Scope               | 说明                            |
| ------------------- | ------------------------------- |
| `app_mentions:read` | 读取 @提及消息                  |
| `chat:write`        | 发送消息                        |
| `chat:write.public` | 在未加入的公共频道中发送消息    |
| `channels:history`  | 读取公共频道历史消息            |
| `channels:read`     | 读取公共频道基本信息            |
| `groups:history`    | 读取私有频道历史消息            |
| `im:history`        | 读取 DM 历史消息                |
| `im:read`           | 查看 DM 信息                    |
| `im:write`          | 发起 DM 对话                    |
| `mpim:history`      | 读取群组 DM 历史                |
| `users:read`        | 读取用户信息                    |
| `reactions:read`    | 读取消息 Emoji 表情回应         |
| `reactions:write`   | 添加/删除 Emoji 表情回应        |
| `pins:read`         | 读取频道置顶消息                |
| `pins:write`        | 置顶/取消置顶消息               |
| `emoji:read`        | 读取自定义 Emoji 列表           |
| `commands`          | 注册和处理 Slash Commands       |
| `files:read`        | 读取用户上传的文件（图片/文档） |
| `files:write`       | 上传文件（AI 返回文件）         |

### 3.1b 配置 Slash Command（可选）

1. 左侧菜单 → **Slash Commands**
2. 点击 **Create New Command**
3. 填写：
   - **Command**: `/openclaw`
   - **Short Description**: `Send a message to OpenClaw`
   - **Escape channels, users, and links**: 不勾选
4. 点击 **Save**

配置后，你可以在 Slack 任何位置输入 `/openclaw <你的问题>` 直接向 AI 提问。

### 3.1c 启用 Interactivity

1. 左侧菜单 → **Interactivity & Shortcuts**
2. 打开 **Interactivity** 开关
3. 点击 **Save Changes**

### 3.2 生成 App-Level Token

Socket Mode 需要一个 App-Level Token，用于建立 WebSocket 连接：

1. 左侧菜单 → **Basic Information**
2. 向下滚动到 **App-Level Tokens**
3. 点击 **Generate Token and Scopes**
4. Token Name: `openclaw-socket`
5. 添加 Scope: `connections:write`
6. 点击 **Generate**
7. **保存生成的 Token**（以 `xapp-` 开头）

> **重要**: 此 Token 只在生成时显示一次，请立即保存。如丢失需重新生成。

---

## 四、启用事件订阅

> **提示**: 如果你在第二步中使用了 **App Manifest** 创建，Socket Mode 和事件订阅已自动配置，可直接跳到[第五步](#五安装-app-到-workspace)。

### 4.1 启用 Socket Mode

1. 左侧菜单 → **Socket Mode**
2. 打开 **Enable Socket Mode** 开关（如提示生成 Token，参见 [3.2 节](#32-生成-app-level-token)）

### 4.2 配置事件订阅

1. 左侧菜单 → **Event Subscriptions**
2. 打开 **Enable Events** 开关
3. 在 **Subscribe to bot events** 中添加以下事件：

| 事件                    | 说明                |
| ----------------------- | ------------------- |
| `app_mention`           | 有人 @Bot 时触发    |
| `message.im`            | 收到 DM 消息        |
| `message.channels`      | 公共频道有新消息    |
| `message.groups`        | 私有频道有新消息    |
| `message.mpim`          | 群组 DM 有新消息    |
| `reaction_added`        | 有人添加 Emoji 回应 |
| `reaction_removed`      | 有人移除 Emoji 回应 |
| `member_joined_channel` | 成员加入频道        |
| `member_left_channel`   | 成员离开频道        |
| `channel_rename`        | 频道重命名          |
| `pin_added`             | 消息被置顶          |
| `pin_removed`           | 消息被取消置顶      |

4. 点击 **Save Changes**

---

## 五、安装 App 到 Workspace

1. 左侧菜单 → **Install App**
2. 点击 **Install to Workspace**
3. 审核权限 → 点击 **Allow**
4. 安装成功后，你会得到 **Bot User OAuth Token**（以 `xoxb-` 开头）
5. **保存此 Token**

---

## 六、获取 Token 和密钥

你需要收集以下三项信息（都在 Slack App 管理页面可以找到）：

| 信息               | 位置                                                 | 格式                             |
| ------------------ | ---------------------------------------------------- | -------------------------------- |
| **Bot Token**      | OAuth & Permissions → Bot User OAuth Token           | `xoxb-xxxx-xxxx-xxxx`            |
| **App Token**      | Basic Information → App-Level Tokens                 | `xapp-1-xxxx` （仅 Socket Mode） |
| **Signing Secret** | Basic Information → App Credentials → Signing Secret | 32 位十六进制字符串              |

> **安全提示**: 这些 Token 是敏感凭据，请勿泄露或提交到代码仓库。

---

## 七、配置 OpenClaw

SSH 登录到 VM 后（Windows 则在 WSL 中操作），配置 Slack 通道。

### 方式 A：使用 `openclaw onboard` 交互式配置

```bash
openclaw onboard
```

在交互式向导中：
1. 选择 Add Channel → **Slack**
2. 输入 Bot Token (`xoxb-...`)
3. 输入 App Token (`xapp-...`)（Socket Mode）
4. 输入 Signing Secret
5. 完成配置

### 方式 B：手动编辑配置文件

```bash
nano ~/.openclaw/openclaw.json
```

在配置文件中添加 Slack 通道：

```jsonc
{
  "agent": {
    "model": "azure/gpt-4o"
  },
  "providers": {
    "azure": {
      // ... 模型提供商配置
    }
  },
  "channels": {
    "slack": {
      "enabled": true,
      "botToken": "xoxb-xxxx-xxxx-xxxx",
      "appToken": "xapp-1-xxxx",           // Socket Mode 需要
      "signingSecret": "your_signing_secret_here",
      "socketMode": true                    // 推荐使用 Socket Mode
    }
  }
}
```

**配置字段说明**：

| 字段            | 必填               | 说明                                 |
| --------------- | ------------------ | ------------------------------------ |
| `enabled`       | 是                 | 启用 Slack 通道                      |
| `botToken`      | 是                 | Bot User OAuth Token (`xoxb-` 开头)  |
| `appToken`      | Socket Mode 时必填 | App-Level Token (`xapp-` 开头)       |
| `signingSecret` | 是                 | 用于验证来自 Slack 的请求签名        |
| `socketMode`    | 否                 | 是否使用 Socket Mode（默认 `false`） |

### 重启服务

```bash
# Ubuntu
sudo systemctl restart openclaw

# 检查状态
sudo systemctl status openclaw
```

---

## 八、验证连接

### 8.1 检查 Gateway 日志

```bash
journalctl -u openclaw -f
```

正常启动应看到类似输出：

```
OpenClaw Gateway started on 0.0.0.0:18789
Channel connected: Slack (Socket Mode)
Listening for Slack events...
```

### 8.2 在 Slack 中测试

#### 测试 DM（直接消息）

1. 在 Slack 左侧边栏找到你的 Bot（在 **Apps** 分类下）
2. 点击 Bot 名称，打开 DM 对话
3. 发送一条消息，如 "你好"
4. 等待 AI 回复

#### 测试频道 @提及

1. 邀请 Bot 到某个频道：在频道中输入 `/invite @OpenClaw`
2. 发送消息 `@OpenClaw 今天天气怎么样？`
3. Bot 应该在频道中回复

### 8.3 运行诊断

```bash
openclaw doctor
```

确保 `Slack channel` 检查项显示为 ✅ Connected。

---

## 九、高级配置

### 9.1 限制响应频道

如果不想 Bot 响应所有频道的消息，可以配置白名单：

```jsonc
{
  "channels": {
    "slack": {
      "enabled": true,
      "botToken": "xoxb-xxxx",
      "appToken": "xapp-xxxx",
      "signingSecret": "xxxx",
      "socketMode": true,
      // 仅在指定频道中响应
      "allowedChannels": ["C01XXXXXXXX", "C02YYYYYYYY"]
    }
  }
}
```

> 频道 ID 可在 Slack 频道信息底部找到，或通过右键频道名称 → Copy Link 获取。

### 9.2 自定义 Bot 行为

```jsonc
{
  "channels": {
    "slack": {
      "enabled": true,
      // ...基础配置...

      // DM 中无需 @提及即可触发（默认 true）
      "respondInDM": true,

      // 频道中是否需要 @提及才触发（默认 true）
      "requireMention": true,

      // 是否在回复中添加线程（Thread）而不是直接在频道发送
      "useThreads": true
    }
  }
}
```

### 9.3 多 Workspace 支持

如果你需要服务多个 Slack Workspace，可以配置多个 Slack 通道实例：

```jsonc
{
  "channels": {
    "slack": {
      "enabled": true,
      "botToken": "xoxb-workspace1-token",
      "appToken": "xapp-workspace1-token",
      "signingSecret": "secret1",
      "socketMode": true
    },
    "slack-team2": {
      "type": "slack",
      "enabled": true,
      "botToken": "xoxb-workspace2-token",
      "appToken": "xapp-workspace2-token",
      "signingSecret": "secret2",
      "socketMode": true
    }
  }
}
```

---

## 十、常见问题

### Q: Bot 已在线但不回复消息

1. 检查 Event Subscriptions 是否已启用并添加了正确的事件
2. 确认 Bot 已被邀请到对应频道（`/invite @OpenClaw`）
3. 查看 Gateway 日志是否有收到事件：`journalctl -u openclaw -f`
4. 运行 `openclaw doctor` 检查 Slack 连接状态

### Q: 出现 `invalid_auth` 错误

- Bot Token 已过期或被撤销，前往 Slack App 管理页面重新生成
- 确认使用的是 **Bot User OAuth Token**（`xoxb-`），而非 User Token

### Q: 出现 `token_revoked` 错误

- App 可能被从 Workspace 中卸载，重新安装：**Install App** → **Reinstall to Workspace**

### Q: Socket Mode 连接失败

- 确认 App-Level Token (`xapp-`) 正确且未过期
- 确认 Socket Mode 已在 Slack App 设置中启用
- 检查 VM 是否可以访问外网（Socket Mode 需要出站连接到 `wss://wss-primary.slack.com`）

### Q: Webhook 模式验证失败

- 确认 VM 的 18789 端口从公网可达
- 确认 OpenClaw 已启动并正确配置 Slack 通道后，再在 Slack 中填写 Request URL
- 确认 URL 格式正确：`http://<VM_PUBLIC_IP>:18789/channels/slack/events`

### Q: 消息延迟很高

- 检查 AI 模型提供商的响应时间（`openclaw doctor`）
- Socket Mode 通常比 Webhook 有略高延迟，但更安全
- 确认 VM 规格足够（建议至少 `Standard_B2s`）

### Q: 如何使用 Slash Command？

在 Slack 任何对话窗口中输入 `/openclaw 你的问题`，即可直接向 AI 提问。Slash Command 的回复仅对发送者可见（ephemeral），适合在公共频道中私密提问。

### Q: 如何让 Bot 响应 Emoji Reactions？

如果使用了 App Manifest 创建，`reaction_added` 和 `reaction_removed` 事件已自动订阅。如果手动创建，需在 Event Subscriptions 中添加 `reaction_added` 事件，并在 Bot Token Scopes 中添加 `reactions:read` 权限。

---

## 安全建议

1. **使用 Socket Mode**: 相比 HTTP Webhook，Socket Mode 不需要暴露公网端口，更安全
2. **限制响应频道**: 使用 `allowedChannels` 配置白名单，避免 Bot 在不相关频道中响应
3. **定期轮转 Token**: 定期重新生成 Bot Token 和 App Token
4. **启用 Gateway 认证**: 配置 `gateway.auth.mode: "password"` 保护 Web UI
5. **审计日志**: 定期检查 `journalctl -u openclaw` 中的 Slack 事件日志

---

## 参考链接

- [Slack API 官方文档](https://api.slack.com/docs)
- [Slack Bot 开发指南](https://api.slack.com/bot-users)
- [Slack Socket Mode 文档](https://api.slack.com/apis/socket-mode)
- [Slack App 权限 Scopes](https://api.slack.com/scopes)
- [OpenClaw Channels 文档](https://docs.openclaw.ai/channels)
- [OpenClaw Slack 通道文档](https://docs.openclaw.ai/channels/slack)
