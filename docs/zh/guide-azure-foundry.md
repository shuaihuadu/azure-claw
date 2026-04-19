# Azure Foundry / Azure OpenAI 多模型配置指南

本文档适用于在 OpenClaw Gateway 中接入 **Azure AI Foundry** 或经典 **Azure OpenAI** 服务，涵盖单模型、多模型，以及 chat 与 reasoning 模型混用的完整配置思路。

> 目标版本：OpenClaw **2026.4.15+**
> 目标端点：Azure OpenAI **V1 兼容端点**（`/openai/v1`，2024 年 11 月 GA）

---

## 一、为什么要用 `/openai/v1` 而不是 `/openai/deployments/...`

Azure OpenAI 历史上有两套 REST 形态：

| 端点形态 | 路径示例                                                                   | 说明                                                                                                       |
| -------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 经典     | `/openai/deployments/{deployment}/chat/completions?api-version=2024-xx-xx` | 强绑定 deployment 名，必须带 `api-version`                                                                 |
| V1 兼容  | `/openai/v1/chat/completions`，`/openai/v1/responses`                      | 2024-11 GA，**与 OpenAI 官方 API 形状一致**，drop-in 兼容，OpenClaw 内置的 `openai-*` adapter 全都能直接用 |

**请一律使用 V1 兼容端点**。baseUrl 格式：

```
https://<your-resource-name>.openai.azure.com/openai/v1
```

认证仍然沿用 Azure 的 `api-key:` 头（不是 `Authorization: Bearer`），在 OpenClaw 里通过 `headers.authHeader` 声明：

```jsonc
"headers": { "authHeader": "api-key" }
```

---

## 二、两种 `api` adapter：`openai-completions` vs `openai-responses`

这是 Azure Foundry 多模型配置里**最容易踩坑**的地方。OpenClaw 的 `models.providers.<id>.api` 字段枚举值：

| `api` 值               | 底层路径                                  | 适用模型族系                                              |
| ---------------------- | ----------------------------------------- | --------------------------------------------------------- |
| `openai-completions`   | `POST /chat/completions`                  | GPT-4.1 / GPT-4o / GPT-5.x **chat** / Mini 系列           |
| `openai-responses`     | `POST /responses`                         | **o1 / o3 / o4 / codex / GPT-5 reasoning** 等所有推理模型 |
| `anthropic-messages`   | `POST /v1/messages`                       | Anthropic 原生 / 部分聚合代理                             |
| `google-generative-ai` | `POST /v1beta/models/...:generateContent` | Google AI Studio / Vertex                                 |

### 选择规则

1. **chat family（非推理）** → `openai-completions`
2. **reasoning family（推理）** → **必须** `openai-responses`（Responses API 才支持 `reasoning.effort`、reasoning tokens、server-side `store`）
3. 如果不确定，用下面的 curl 探一下（见第六节）

### 为什么不建议在一个 provider 里混用

`models.providers.<id>.api` 是 **provider 级** transport；`models.providers.<id>.models[].api` 虽然也能写，会 override，但同一 provider 内部混两种 transport 代码路径走 `normalizeTransport` 二次重写，容易踩到 headers / streaming 对齐问题。

**推荐做法：拆成两个 provider，共用 baseUrl 和 apiKey。**

---

## 三、`api` 字段优先级

| 位置                                 | 生效范围                                                   |
| ------------------------------------ | ---------------------------------------------------------- |
| `models.providers.<id>.api`          | **该 provider 下所有模型**的默认 transport，99% 场景写这里 |
| `models.providers.<id>.models[].api` | **仅该模型**，覆盖 provider 级，**不推荐**                 |

优先级：per-model `api` > provider `api` > 内置默认。

---

## 四、Provider 级字段全集

```jsonc
"azure-chat": {
  "baseUrl": "https://<res>.openai.azure.com/openai/v1",
  "apiKey": "${AZURE_OPENAI_API_KEY}",       // 建议用环境变量，不要明文
  "api": "openai-completions",               // provider 级 transport
  "headers": { "authHeader": "api-key" },    // Azure 专用：告诉 OpenClaw 用 api-key 头
  "models": [ /* 见下节 */ ]
}
```

`apiKey` 引用的环境变量在 systemd 里这样注入：

```bash
sudo systemctl edit openclaw
# 在 [Service] 下追加
Environment=AZURE_OPENAI_API_KEY=<你的密钥>
sudo systemctl daemon-reload
sudo systemctl restart openclaw
```

---

## 五、Per-model 字段细调

`models[]` 支持两种写法：

**字符串简写**（全走默认）：
```jsonc
"models": ["gpt-4.1", "gpt-5.4-mini"]
```

**对象展开**（可细调）：
```jsonc
"models": [
  {
    "id": "o4",                     // = Azure deployment name（大小写敏感）
    "name": "Azure o4 (reasoning)", // UI 显示名
    "reasoning": true,              // 是否推理模型，默认 false
    "input": ["text", "image"],     // 接受的 modality，默认 ["text"]
    "contextWindow": 272000,        // 原厂上下文窗口 (metadata)，默认 200000
    "contextTokens": 128000,        // OpenClaw 运行时实际打包上限，可 < contextWindow
    "maxTokens": 32000,             // 单次生成 output 上限，默认 8192
    "cost": {                       // 仅用于 /usage 统计，不影响路由；Foundry 可留 0
      "input": 15.0,
      "output": 60.0,
      "cacheRead": 1.5,
      "cacheWrite": 18.75
    },
    "compat": {
      "supportsDeveloperRole": false, // Azure 的 openai-completions 会被自动关掉，显式写也行
      "requiresStringContent": false  // 极少数老端点需要 messages[].content 为字符串
    }
  }
]
```

### 省略时的默认值

| 字段            | 默认              |
| --------------- | ----------------- |
| `reasoning`     | `false`           |
| `input`         | `["text"]`        |
| `cost`          | 全 0              |
| `contextWindow` | `200000`          |
| `contextTokens` | = `contextWindow` |
| `maxTokens`     | `8192`            |

**原则：只写你要偏离默认的字段**。Foundry 场景下通常只需要显式写 `contextWindow` / `contextTokens` / `maxTokens` / `reasoning`，`cost` 一般可以省。

### `contextWindow` vs `contextTokens`

- `contextWindow`：模型**原厂**上下文，metadata，给 UI / 诊断显示
- `contextTokens`：OpenClaw 实际打包对话时的上限，**控制实际计费**

例子：Azure o4 原厂 272K，但你想省钱 → `"contextTokens": 128000` 强制压到 128K。

### 关于"compact"

如果你想问的是**会话压缩（长对话摘要）**，那不在 provider / model 块里，而在 `agents.defaults.compaction`，属于 agent 级别的策略。本文不展开，详见运维手册。

---

## 六、完整示例：chat + reasoning 双 provider

下面是生产可用的最小完整配置，同一个 Foundry 资源挂两种 `api`：

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "azure-chat/gpt-4.1",
        "fallbacks": ["azure-chat/gpt-5.4-mini", "azure-reasoning/o4"]
      },
      "models": {
        "azure-chat/gpt-4.1":      { "alias": "std"   },
        "azure-chat/gpt-5.4-mini": { "alias": "mini"  },
        "azure-reasoning/o4":      { "alias": "think" }
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "azure-chat": {
        "baseUrl": "https://my-foundry.openai.azure.com/openai/v1",
        "apiKey": "${AZURE_OPENAI_API_KEY}",
        "api": "openai-completions",
        "headers": { "authHeader": "api-key" },
        "models": [
          { "id": "gpt-4.1",      "contextWindow": 1047576, "maxTokens": 32768 },
          { "id": "gpt-5.4-mini", "contextWindow": 128000,  "maxTokens": 16384 }
        ]
      },
      "azure-reasoning": {
        "baseUrl": "https://my-foundry.openai.azure.com/openai/v1",
        "apiKey": "${AZURE_OPENAI_API_KEY}",
        "api": "openai-responses",
        "headers": { "authHeader": "api-key" },
        "models": [
          {
            "id": "o4",
            "reasoning": true,
            "contextWindow": 272000,
            "contextTokens": 128000,
            "maxTokens": 32000
          }
        ]
      }
    }
  }
}
```

应用：

```bash
# 把上面片段合并进 ~/.openclaw/openclaw.json
sudo systemctl restart openclaw
openclaw models status --probe   # 期望看到 4 条都绿
```

在 Chat UI 里用 `/model std`、`/model mini`、`/model think` 切换。

---

## 七、实战范例：Azure AI Foundry 单资源挂 4 个模型

本节是**实际在 azure-claw 部署上验证通过的配置**，模型来自同一个 Azure AI Foundry 资源（`<your-resource>`），包含 OpenAI 原生模型和第三方模型（Moonshot、DeepSeek 等）。

### 7.1 场景

- Foundry resource: `<your-resource>.openai.azure.com`
- 4 个 deployment（名字 = `models[].id`）：
  - `gpt-5.1-chat` — GPT-5.1 chat family
  - `gpt-4.1` — GPT-4.1
  - `Kimi-K2.5` — Moonshot Kimi K2.5（第三方）
  - `DeepSeek-V3.2` — DeepSeek V3.2（第三方）
- 所有 4 个 deployment 都要求 `max_completion_tokens` 而非 `max_tokens`
- 所有 deployment 都不支持 Responses API 的 server-side `store`

### 7.2 关键发现

这套配置踩过的坑和经验：

1. **Azure V1 端点对 chat 模型的两种 `api` 都接受**。同一个 GPT-4.1 deployment 用 `openai-completions` 或 `openai-responses` 都能返回 200，只要加上下面两个 compat flag：
   - `"compat": { "maxTokensField": "max_completion_tokens", "supportsStore": false }`
2. **第三方模型**（Kimi / DeepSeek）在 Azure Foundry 上也**同样要求 `max_completion_tokens`**，不能用老的 `max_tokens`。
3. **`apiKey` 和 `headers.api-key` 可以同时写同一个值**。OpenClaw 优先认 `headers.api-key`（直接透传），`apiKey` 是 provider 级 fallback；两者冗余写不会冲突，但推荐至少写 `apiKey` 保证 `openclaw doctor` 能识别。
4. **避免装 user 级 `openclaw-gateway.service`**。`openclaw onboard --install-daemon` 会装一个 user-scope systemd 服务抢占 18789，和 azure-claw 装的 system-scope `openclaw.service` 打架，症状是 system service 不停重启 + `EADDRINUSE`。部署过 azure-claw 的 VM 上**不要**再跑带 `--install-daemon` 的 onboard。如果跑过，用以下命令清掉：
   ```bash
   systemctl --user stop openclaw-gateway.service
   systemctl --user disable openclaw-gateway.service
   sudo systemctl restart openclaw
   ```

### 7.3 完整配置片段

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "microsoft-foundry/gpt-5.1-chat"
      },
      "models": {
        "microsoft-foundry/gpt-5.1-chat": {},
        "microsoft-foundry/gpt-4.1":      {},
        "azure-openai/Kimi-K2.5":         {},
        "azure-openai/DeepSeek-V3.2":     {}
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "microsoft-foundry": {
        "baseUrl": "https://<your-resource>.openai.azure.com/openai/v1",
        "api": "openai-responses",                                 // 也可用 openai-completions
        "apiKey": "<AZURE_OPENAI_KEY>",
        "headers": { "api-key": "<AZURE_OPENAI_KEY>" },            // Azure 专用认证头
        "models": [
          {
            "id": "gpt-5.1-chat",                                  // = Azure deployment name
            "name": "gpt-5.1",
            "reasoning": false,
            "input": ["text", "image"],
            "contextWindow": 128000,
            "maxTokens": 16384,
            "compat": {
              "supportsStore": false,                              // Azure 不支持 Responses server-side store
              "maxTokensField": "max_completion_tokens"            // 必须，否则 400
            }
          },
          {
            "id": "gpt-4.1",
            "name": "gpt-4.1",
            "reasoning": false,
            "input": ["text", "image"],
            "contextWindow": 128000,
            "maxTokens": 16384,
            "compat": {
              "supportsStore": false,
              "maxTokensField": "max_completion_tokens"
            }
          }
        ]
      },
      "azure-openai": {
        "baseUrl": "https://<your-resource>.openai.azure.com/openai/v1",
        "api": "openai-completions",                               // 第三方模型稳妥用 completions
        "apiKey": "<AZURE_OPENAI_KEY>",
        "headers": { "api-key": "<AZURE_OPENAI_KEY>" },
        "models": [
          {
            "id": "Kimi-K2.5",
            "name": "Kimi-K2.5",
            "reasoning": false,                                    // Kimi 实际含推理内容，见 §7.4
            "input": ["text", "image"],
            "contextWindow": 128000,
            "maxTokens": 16384,
            "compat": {
              "supportsStore": false,
              "maxTokensField": "max_completion_tokens"
            }
          },
          {
            "id": "DeepSeek-V3.2",
            "name": "DeepSeek-V3.2",
            "reasoning": false,
            "input": ["text", "image"],
            "contextWindow": 128000,
            "maxTokens": 16384,
            "compat": {
              "supportsStore": false,
              "maxTokensField": "max_completion_tokens"
            }
          }
        ]
      }
    }
  }
}
```

> **安全提示**：生产环境把 `apiKey` 和 `headers.api-key` 的值替换成 `${AZURE_OPENAI_API_KEY}`，通过 systemd 的 `Environment=AZURE_OPENAI_API_KEY=...` 注入，避免 `openclaw.json` 里明文存密钥。

### 7.4 Kimi-K2.5 的 reasoning 行为

直接 curl 测试 Kimi：

```bash
curl -sS "$BASE/chat/completions" -H "api-key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"Kimi-K2.5","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":50}'
```

返回：

```jsonc
{
  "choices": [{
    "finish_reason": "length",               // ← 被截断
    "message": {
      "content": null,                        // ← 最终回答为空
      "reasoning_content": "The user said hi..."  // ← 推理过程
    }
  }]
}
```

说明 Kimi-K2.5 在 Azure 上**实际是 reasoning 模型**，50 token 全被推理吃掉了没写出 `content`。建议：

- 把 `maxTokens` 调到 4096+（给推理 + 输出留足空间）
- 或把 Kimi 从 `azure-openai` provider 移出，单独开一个 `api: "openai-responses"` 的 provider，并在该 model 里加 `"reasoning": true`

### 7.5 验证清单

改完配置后按顺序验证：

```bash
# 1. 重启并等 ready
sudo systemctl restart openclaw
sudo journalctl -u openclaw -f | grep -m1 "gateway] ready"

# 2. 直接 curl Azure 确认每个 deployment 可用
BASE="https://<res>.openai.azure.com/openai/v1"
KEY="<your-key>"
for M in gpt-5.1-chat gpt-4.1 Kimi-K2.5 DeepSeek-V3.2; do
  printf "%-18s  " "$M"
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" "$BASE/chat/completions" \
    -H "api-key: $KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_completion_tokens\":50}"
done

# 3. 浏览器打开 Control UI，输入 Gateway 密码，发一句话测试
```

---

## 八、curl 探测：我的 deployment 到底该用哪个 `api`？

> 注：原节号由第七小节 "实战范例" 的插入顺延，下面仍是通用探测脚本。

部署之前先验证：

```bash
BASE="https://my-foundry.openai.azure.com/openai/v1"
KEY="$AZURE_OPENAI_API_KEY"
DEPLOY="o4"   # 改成你的 Azure deployment 名

# 探 openai-completions
curl -sS -o /tmp/a.json -w "completions: %{http_code}\n" \
  "$BASE/chat/completions" \
  -H "api-key: $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$DEPLOY\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16}"

# 探 openai-responses
curl -sS -o /tmp/b.json -w "responses:   %{http_code}\n" \
  "$BASE/responses" \
  -H "api-key: $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$DEPLOY\",\"input\":\"hi\",\"max_output_tokens\":16}"
```

**判读**：

- `200` 两个都通 → chat 族，选 `openai-completions`（更稳）
- 只有 `/responses` 回 200，`/chat/completions` 回 400 + `Use Responses API` → 推理族，必须 `openai-responses`
- 都 `404` → deployment 名打错或 resource URL 错
- `401` → `api-key` 不对

---

## 九、常见报错排查

| 报错                                                                      | 原因                                                               | 解决                                                                                        |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `Model not allowed`                                                       | `models[]` 里没列该 id                                             | 把 deployment 名加进 `models[]`                                                             |
| `400 Unsupported parameter: 'max_tokens'` / `Use 'max_completion_tokens'` | Azure Foundry 的 GPT-5.x / Kimi / DeepSeek 等不再接受 `max_tokens` | 该 model 加 `"compat": { "maxTokensField": "max_completion_tokens" }`                       |
| `EADDRINUSE 127.0.0.1:18789` + systemd 无限重启                           | 装了 user-scope `openclaw-gateway.service` 抢占端口                | `systemctl --user stop/disable openclaw-gateway.service && sudo systemctl restart openclaw` |
| `404 DeploymentNotFound`                                                  | Azure deployment 名大小写或拼写错                                  | Foundry 控制台确认 deployment name                                                          |
| `400 The reasoning model requires the Responses API`                      | 推理模型走了 `openai-completions`                                  | 把这个 provider 的 `api` 改成 `openai-responses`                                            |
| `401 Unauthorized`                                                        | 密钥错或 authHeader 漏写                                           | 补 `"headers": { "authHeader": "api-key" }`                                                 |
| `Messages content must be a string`                                       | 老端点要求 string 内容                                             | 该 model 加 `"compat": { "requiresStringContent": true }`                                   |
| Gateway 启动时 `model not found: primary`                                 | `primary` 里写的 ref 没配对上 provider/model                       | 用完整 `provider/model` 形式，别只写模型名                                                  |
| 回复 `content: null` + `finish_reason: "length"`                          | 模型实际是 reasoning，`maxTokens` 太小被推理吞掉                   | 把 `maxTokens` 调高到 4096+，或移到 `openai-responses` provider 并设 `reasoning: true`      |

---

## 十、和老 `/openai/deployments` 格式的对照

如果你看过 Azure 官方文档或老的 OpenClaw 样例，可能见过这种写法。**不要再用**：

```jsonc
// ❌ 老格式（不推荐）
{
  "baseUrl": "https://<res>.openai.azure.com/openai/deployments/gpt-4.1",
  "api": "openai-completions",
  "models": [{ "id": "gpt-4.1" }]
}
```

问题：baseUrl 里写死了 deployment，**一个 provider 只能挂一个模型**，而且每次请求都要拼 `?api-version=...`，OpenClaw 内置 adapter 没这种逻辑。

**统一用 `/openai/v1` + `models[]`**，一个 provider 管 N 个 deployment，清爽。

---

## 十一、相关链接

- 运维手册：[guide-operations.md](./guide-operations.md)
- Slack 通道配置：[guide-slack.md](./guide-slack.md)
- Teams 通道配置：[guide-teams.md](./guide-teams.md)
- OpenClaw 官方 Configuration Reference: <https://docs.openclaw.ai/gateway/configuration-reference>
- Azure OpenAI V1 兼容端点: <https://learn.microsoft.com/azure/ai-services/openai/reference>
