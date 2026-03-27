# 排障手册：Microsoft Foundry 模型与 OpenClaw 兼容性

本手册记录了在 OpenClaw 中配置 Microsoft Foundry（Azure OpenAI）多模型时遇到的兼容性问题、排查过程和最终解决方案。

---

## 目录

- [排障手册：Microsoft Foundry 模型与 OpenClaw 兼容性](#排障手册microsoft-foundry-模型与-openclaw-兼容性)
  - [目录](#目录)
  - [一、背景](#一背景)
    - [测试环境](#测试环境)
    - [OpenClaw 支持的 API 类型](#openclaw-支持的-api-类型)
  - [二、API 类型选择：Responses vs Chat Completions](#二api-类型选择responses-vs-chat-completions)
  - [三、问题一：Encrypted content 错误](#三问题一encrypted-content-错误)
    - [现象](#现象)
    - [原因](#原因)
    - [解决方案](#解决方案)
  - [四、问题二：Unrecognized reasoning\_effort](#四问题二unrecognized-reasoning_effort)
    - [现象](#现象-1)
    - [原因](#原因-1)
    - [解决方案](#解决方案-1)
  - [五、问题三：Responses API 模型不支持](#五问题三responses-api-模型不支持)
    - [现象](#现象-2)
    - [原因](#原因-2)
    - [解决方案](#解决方案-2)
  - [六、问题四：reasoning\_effort "low" 不受支持](#六问题四reasoning_effort-low-不受支持)
    - [现象](#现象-3)
    - [原因](#原因-3)
    - [行为](#行为)
    - [尝试修复](#尝试修复)
    - [结论](#结论)
  - [七、问题五：431 Request Header Fields Too Large](#七问题五431-request-header-fields-too-large)
    - [现象](#现象-4)
    - [原因](#原因-4)
    - [解决方案](#解决方案-3)
  - [八、最终方案：统一使用 Chat Completions](#八最终方案统一使用-chat-completions)
    - [关键配置要点](#关键配置要点)
    - [优势](#优势)
    - [已知限制](#已知限制)
  - [九、compat 字段说明](#九compat-字段说明)
  - [十、相关命令速查](#十相关命令速查)

---

## 一、背景

### 测试环境

- **OpenClaw**: 2026.3.24 (cff6dc9)
- **Microsoft Foundry 端点**: `https://shuaihua-azureai-foundry.openai.azure.com/openai/v1`
- **部署模型**: gpt-4.1、gpt-5.1-chat、grok-4-1-fast-reasoning、Kimi-K2.5、DeepSeek-V3.2

### OpenClaw 支持的 API 类型

| API 类型             | 端点                         | 说明                                  |
| -------------------- | ---------------------------- | ------------------------------------- |
| `openai-completions` | `{baseUrl}/chat/completions` | Chat Completions API，兼容性最佳      |
| `openai-responses`   | `{baseUrl}/responses`        | Responses API，功能更丰富但兼容性受限 |

---

## 二、API 类型选择：Responses vs Chat Completions

OpenClaw 支持在 provider 级别和 model 级别分别配置 `api` 字段。Model 级别的 `api` 会覆盖 provider 级别的设置。

**关键发现**：Microsoft Foundry 上并非所有模型都支持 Responses API。实测结果：

| 模型                    | Chat Completions | Responses API                           |
| ----------------------- | ---------------- | --------------------------------------- |
| gpt-4.1                 | ✅                | ✅（但有 store 问题）                    |
| gpt-5.1-chat            | ✅                | ✅（但有 store + reasoning_effort 问题） |
| grok-4-1-fast-reasoning | ✅                | ❌ 不支持                                |
| Kimi-K2.5               | ✅                | ❌ 不支持                                |
| DeepSeek-V3.2           | ✅                | ❌ 不支持                                |

---

## 三、问题一：Encrypted content 错误

### 现象

使用 gpt-4.1 + `openai-responses` API 时，模型返回错误：

```
Error: Encrypted content is not supported.
```

### 原因

OpenClaw 源码中 `shouldForceResponsesStore()` 函数会检测 Azure URL 并在使用 Responses API 时强制设置 `store: true`。Azure OpenAI 的某些模型部署不支持 `store: true`，导致此错误。

相关源码逻辑：
```
if (url 包含 "azure" && api === "openai-responses") → 强制 store: true
```

### 解决方案

**方案 A（已验证）**：将模型的 API 切换为 `openai-completions`，绕过 Responses API 的 store 强制逻辑。

**方案 B**：在 model 级别设置 `compat.supportsStore: false`，阻止 OpenClaw 发送 `store: true`。

---

## 四、问题二：Unrecognized reasoning_effort

### 现象

gpt-4.1 设置 `reasoning: true` 后报错：

```
Error: Unrecognized request argument supplied: reasoning_effort
```

### 原因

gpt-4.1 是一个非推理模型，不支持 `reasoning_effort` 参数。当 `reasoning: true` 时，OpenClaw 会在请求中附加 `reasoning_effort` 字段，而 gpt-4.1 不认识该参数。

### 解决方案

将 gpt-4.1 的 `reasoning` 设置为 `false`。只有真正支持推理的模型（如 gpt-5.1-chat、grok-4-1-fast-reasoning）才应设为 `true`。

---

## 五、问题三：Responses API 模型不支持

### 现象

DeepSeek-V3.2、Kimi-K2.5、grok-4-1-fast-reasoning 使用 `openai-responses` API 时报错：

```
Error: The model does not support the Responses API.
```

### 原因

这些模型在 Microsoft Foundry 上仅部署了 Chat Completions 端点，不支持 Responses API。

### 解决方案

在 provider 级别设置 `"api": "openai-completions"`，让所有模型默认使用 Chat Completions API。

---

## 六、问题四：reasoning_effort "low" 不受支持

### 现象

gpt-5.1-chat 在 fast mode（快速模式）下报错：

```
Error: 'low' is not a supported value for reasoning_effort. Supported values are: 'medium', 'high'.
```

OpenClaw 会自动重试，日志显示 "retrying with medium"。

### 原因

OpenClaw 的 `resolveFastModeReasoningEffort()` 函数会为所有模型（包括 gpt-5.x）硬编码返回 `"low"` 作为快速模式的 reasoning_effort。但 gpt-5.1-chat 仅支持 `"medium"` 和 `"high"`。

### 行为

OpenClaw 内建了自动降级机制：当 `"low"` 失败后，会自动使用 `"medium"` 重试。因此实际使用不受影响，只是日志中会出现一次重试记录。

### 尝试修复

我们尝试在 `compat` 中设置 `minThinkingLevel: "medium"` 来覆盖默认行为：

```json
"compat": {
  "supportsStore": false,
  "supportsStreamOptions": false,
  "minThinkingLevel": "medium"
}
```

但 OpenClaw 2026.3.24 的 compat schema 不支持 `supportsStreamOptions` 和 `minThinkingLevel` 字段，配置验证直接拒绝：

```
Invalid config: Unrecognized keys: supportsStreamOptions, minThinkingLevel
```

执行 `openclaw doctor --fix` 后，doctor 会自动删除这两个无效字段。

### 结论

当前版本无法通过配置解决此问题。OpenClaw 的自动重试机制可以兜底，实际使用正常。需等待后续版本扩展 compat schema。

---

## 七、问题五：431 Request Header Fields Too Large

### 现象

grok-3 模型在发送请求时报错：

```
431 Request Header Fields Too Large
```

### 原因

grok-3 模型的请求头大小超过了 Microsoft Foundry 端点的限制。这与 OpenClaw 的认证 header 配置和请求内容综合导致。

### 解决方案

从模型列表中移除 grok-3。如果确实需要 grok-3，建议使用独立的 API 端点或减少请求上下文大小。

---

## 八、最终方案：统一使用 Chat Completions

经过反复测试，**统一使用 `openai-completions`（Chat Completions API）** 是兼容性最好的方案：

```json
{
  "models": {
    "providers": {
      "azure-openai": {
        "baseUrl": "https://<your-endpoint>.openai.azure.com/openai/v1",
        "api": "openai-completions",
        "models": [
          { "id": "gpt-4.1", "reasoning": false },
          { "id": "gpt-5.1-chat", "reasoning": true },
          { "id": "grok-4-1-fast-reasoning", "reasoning": true },
          { "id": "Kimi-K2.5", "reasoning": false },
          { "id": "DeepSeek-V3.2", "reasoning": false }
        ]
      }
    }
  }
}
```

### 关键配置要点

1. **Provider 级别** 设置 `"api": "openai-completions"`，所有模型默认继承
2. **不要** 在 model 级别覆盖 `api` 为 `"openai-responses"`，除非确认该模型在你的端点上完全兼容
3. **`reasoning: true`** 只为真正的推理模型设置（gpt-5.x、grok-4.x 等）
4. **`reasoning: false`** 用于非推理模型（gpt-4.1、Kimi、DeepSeek 等），避免发送不支持的参数
5. **认证** 使用 `authHeader: false` + `headers: { "api-key": "<key>" }` 格式

### 优势

- 所有模型均兼容，无需逐个调试
- 避免 Responses API 的 `store: true` 强制逻辑
- 无需设置 `compat` 字段
- 更简单的配置，更少的出错可能

### 已知限制

- gpt-5.1-chat 在 fast mode 下会先尝试 reasoning_effort "low" 失败，然后自动降级到 "medium"（多一次网络请求）
- 无法使用 Responses API 独有的功能（如 `previous_response_id` 链式对话）

---

## 九、compat 字段说明

OpenClaw 2026.3.24 的 model compat schema **仅支持** 以下字段：

| 字段            | 类型    | 说明                                     |
| --------------- | ------- | ---------------------------------------- |
| `supportsStore` | boolean | 是否支持 `store: true` 参数（默认 true） |

以下字段在代码中存在但 **未纳入 config schema**，设置会导致验证错误：

- `supportsStreamOptions` — 是否支持 stream_options 参数
- `minThinkingLevel` — 最低推理等级

使用无效的 compat 字段时：
- `openclaw models list` 会报错：`Invalid config: Unrecognized keys`
- `openclaw doctor --fix` 会自动删除无效字段并备份配置

---

## 十、相关命令速查

```bash
# 列出所有已配置模型
openclaw models list

# 验证并修复配置
openclaw doctor --fix

# 查看 Gateway 日志（含 API 请求详情）
journalctl -u openclaw -f          # Linux systemd
tail -f ~/.openclaw/logs/gateway.log  # macOS

# 测试特定模型
openclaw chat --model azure-openai/gpt-4.1

# 查看完整配置
cat ~/.openclaw/openclaw.json | python3 -m json.tool
```

---

> **最后更新**: 2026-03-27 | OpenClaw 2026.3.24 (cff6dc9)
