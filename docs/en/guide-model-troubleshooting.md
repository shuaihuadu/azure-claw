# Troubleshooting: Microsoft Foundry Model Compatibility with OpenClaw

This guide documents compatibility issues encountered when configuring multiple Microsoft Foundry (Azure OpenAI) models in OpenClaw, including investigation processes and final solutions.

---

## Table of Contents

- [1. Background](#1-background)
- [2. API Type Selection: Responses vs Chat Completions](#2-api-type-selection-responses-vs-chat-completions)
- [3. Issue 1: Encrypted Content Error](#3-issue-1-encrypted-content-error)
- [4. Issue 2: Unrecognized reasoning\_effort](#4-issue-2-unrecognized-reasoning_effort)
- [5. Issue 3: Responses API Not Supported](#5-issue-3-responses-api-not-supported)
- [6. Issue 4: reasoning\_effort "low" Not Supported](#6-issue-4-reasoning_effort-low-not-supported)
- [7. Issue 5: 431 Request Header Fields Too Large](#7-issue-5-431-request-header-fields-too-large)
- [8. Final Solution: Unified Chat Completions](#8-final-solution-unified-chat-completions)
- [9. compat Field Reference](#9-compat-field-reference)
- [10. Quick Command Reference](#10-quick-command-reference)

---

## 1. Background

### Test Environment

- **OpenClaw**: 2026.3.24 (cff6dc9)
- **Microsoft Foundry Endpoint**: `https://shuaihua-azureai-foundry.openai.azure.com/openai/v1`
- **Deployed Models**: gpt-4.1, gpt-5.1-chat, grok-4-1-fast-reasoning, Kimi-K2.5, DeepSeek-V3.2

### OpenClaw Supported API Types

| API Type             | Endpoint                     | Description                                              |
| -------------------- | ---------------------------- | -------------------------------------------------------- |
| `openai-completions` | `{baseUrl}/chat/completions` | Chat Completions API, best compatibility                 |
| `openai-responses`   | `{baseUrl}/responses`        | Responses API, richer features but limited compatibility |

---

## 2. API Type Selection: Responses vs Chat Completions

OpenClaw supports configuring the `api` field at both the provider level and the model level. Model-level `api` settings override provider-level settings.

**Key finding**: Not all models on Microsoft Foundry support the Responses API. Test results:

| Model                   | Chat Completions | Responses API                               |
| ----------------------- | ---------------- | ------------------------------------------- |
| gpt-4.1                 | ✅                | ✅ (but has store issues)                    |
| gpt-5.1-chat            | ✅                | ✅ (but has store + reasoning_effort issues) |
| grok-4-1-fast-reasoning | ✅                | ❌ Not supported                             |
| Kimi-K2.5               | ✅                | ❌ Not supported                             |
| DeepSeek-V3.2           | ✅                | ❌ Not supported                             |

---

## 3. Issue 1: Encrypted Content Error

### Symptom

When using gpt-4.1 with `openai-responses` API, the model returns:

```
Error: Encrypted content is not supported.
```

### Cause

OpenClaw's `shouldForceResponsesStore()` function detects Azure URLs and forces `store: true` when using the Responses API. Some Azure OpenAI model deployments don't support `store: true`, causing this error.

Related code logic:
```
if (url contains "azure" && api === "openai-responses") → force store: true
```

### Solution

**Solution A (verified)**: Switch the model's API to `openai-completions`, bypassing the Responses API's forced store logic.

**Solution B**: Set `compat.supportsStore: false` at the model level to prevent OpenClaw from sending `store: true`.

---

## 4. Issue 2: Unrecognized reasoning_effort

### Symptom

gpt-4.1 with `reasoning: true` reports:

```
Error: Unrecognized request argument supplied: reasoning_effort
```

### Cause

gpt-4.1 is a non-reasoning model that doesn't support the `reasoning_effort` parameter. When `reasoning: true`, OpenClaw includes `reasoning_effort` in the request, which gpt-4.1 doesn't recognize.

### Solution

Set gpt-4.1's `reasoning` to `false`. Only models that actually support reasoning (e.g., gpt-5.1-chat, grok-4-1-fast-reasoning) should be set to `true`.

---

## 5. Issue 3: Responses API Not Supported

### Symptom

DeepSeek-V3.2, Kimi-K2.5, and grok-4-1-fast-reasoning report errors when using `openai-responses` API:

```
Error: The model does not support the Responses API.
```

### Cause

These models only have Chat Completions endpoints deployed on Microsoft Foundry and don't support the Responses API.

### Solution

Set `"api": "openai-completions"` at the provider level so all models default to the Chat Completions API.

---

## 6. Issue 4: reasoning_effort "low" Not Supported

### Symptom

gpt-5.1-chat in fast mode reports:

```
Error: 'low' is not a supported value for reasoning_effort. Supported values are: 'medium', 'high'.
```

OpenClaw automatically retries, with logs showing "retrying with medium".

### Cause

OpenClaw's `resolveFastModeReasoningEffort()` function hardcodes `"low"` as the fast mode reasoning_effort for all models (including gpt-5.x). However, gpt-5.1-chat only supports `"medium"` and `"high"`.

### Behavior

OpenClaw has a built-in automatic fallback mechanism: when `"low"` fails, it automatically retries with `"medium"`. So actual usage is unaffected — you'll just see one retry entry in the logs.

### Attempted Fix

We tried setting `minThinkingLevel: "medium"` in `compat` to override the default:

```json
"compat": {
  "supportsStore": false,
  "supportsStreamOptions": false,
  "minThinkingLevel": "medium"
}
```

However, OpenClaw 2026.3.24's compat schema doesn't support `supportsStreamOptions` or `minThinkingLevel` fields, and config validation rejects them:

```
Invalid config: Unrecognized keys: supportsStreamOptions, minThinkingLevel
```

Running `openclaw doctor --fix` will automatically remove these invalid fields.

### Conclusion

This issue cannot be resolved through configuration in the current version. OpenClaw's automatic retry mechanism provides a fallback — actual usage is normal. This will need a future version to expand the compat schema.

---

## 7. Issue 5: 431 Request Header Fields Too Large

### Symptom

grok-3 model reports errors when sending requests:

```
431 Request Header Fields Too Large
```

### Cause

grok-3's request header size exceeds the limit of the Microsoft Foundry endpoint. This is caused by a combination of OpenClaw's auth header configuration and request content.

### Solution

Remove grok-3 from the model list. If grok-3 is required, use a separate API endpoint or reduce the request context size.

---

## 8. Final Solution: Unified Chat Completions

After extensive testing, **using `openai-completions` (Chat Completions API) consistently** provides the best compatibility:

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

### Key Configuration Points

1. **Provider level**: Set `"api": "openai-completions"` so all models inherit it
2. **Do not** override `api` to `"openai-responses"` at the model level unless you've confirmed full compatibility for that model on your endpoint
3. **`reasoning: true`** should only be set for actual reasoning models (gpt-5.x, grok-4.x, etc.)
4. **`reasoning: false`** for non-reasoning models (gpt-4.1, Kimi, DeepSeek, etc.) to avoid sending unsupported parameters
5. **Authentication**: Use `authHeader: false` + `headers: { "api-key": "<key>" }` format

### Advantages

- All models are compatible — no per-model debugging needed
- Avoids the Responses API's forced `store: true` logic
- No need to set `compat` fields
- Simpler configuration with fewer potential errors

### Known Limitations

- gpt-5.1-chat in fast mode will first attempt reasoning_effort "low" (which fails), then automatically fall back to "medium" (one extra network request)
- Cannot use Responses API-exclusive features (e.g., `previous_response_id` chained conversations)

---

## 9. compat Field Reference

OpenClaw 2026.3.24's model compat schema **only supports** the following fields:

| Field           | Type    | Description                                                     |
| --------------- | ------- | --------------------------------------------------------------- |
| `supportsStore` | boolean | Whether the `store: true` parameter is supported (default true) |

The following fields exist in code but are **not included in the config schema** — setting them will cause validation errors:

- `supportsStreamOptions` — Whether the stream_options parameter is supported
- `minThinkingLevel` — Minimum reasoning level

When using invalid compat fields:
- `openclaw models list` will report: `Invalid config: Unrecognized keys`
- `openclaw doctor --fix` will automatically remove invalid fields and back up the config

---

## 10. Quick Command Reference

```bash
# List all configured models
openclaw models list

# Validate and fix configuration
openclaw doctor --fix

# View Gateway logs (including API request details)
journalctl -u openclaw -f          # Linux systemd
tail -f ~/.openclaw/logs/gateway.log  # macOS

# Test a specific model
openclaw chat --model azure-openai/gpt-4.1

# View full configuration
cat ~/.openclaw/openclaw.json | python3 -m json.tool
```

---

> **Last updated**: 2026-03-27 | OpenClaw 2026.3.24 (cff6dc9)
