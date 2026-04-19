# Azure Foundry / Azure OpenAI Multi-Model Configuration Guide

This guide covers connecting **Azure AI Foundry** or classic **Azure OpenAI** to OpenClaw Gateway — single model, multi-model, and mixing chat + reasoning families in one deployment.

> Target version: OpenClaw **2026.4.15+**
> Target endpoint: Azure OpenAI **V1-compatible endpoint** (`/openai/v1`, GA Nov 2024)

---

## 1. Why use `/openai/v1` instead of `/openai/deployments/...`

Azure OpenAI historically exposes two REST shapes:

| Endpoint shape | Path sample                                                                | Notes                                                                              |
| -------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Legacy         | `/openai/deployments/{deployment}/chat/completions?api-version=2024-xx-xx` | Hard-binds to a deployment, requires `api-version`                                 |
| V1-compatible  | `/openai/v1/chat/completions`, `/openai/v1/responses`                      | GA Nov 2024, **drop-in OpenAI shape**, works with all OpenClaw `openai-*` adapters |

**Always use the V1-compatible endpoint.** baseUrl format:

```
https://<your-resource-name>.openai.azure.com/openai/v1
```

Auth still uses Azure's `api-key:` header (not `Authorization: Bearer`), declared via `headers.authHeader`:

```jsonc
"headers": { "authHeader": "api-key" }
```

---

## 2. Two `api` adapters: `openai-completions` vs `openai-responses`

This is the **#1 footgun** of Azure Foundry multi-model setup. OpenClaw's `models.providers.<id>.api` enum:

| `api` value            | Underlying path                           | Model families                                                      |
| ---------------------- | ----------------------------------------- | ------------------------------------------------------------------- |
| `openai-completions`   | `POST /chat/completions`                  | GPT-4.1 / GPT-4o / GPT-5.x **chat** / Mini series                   |
| `openai-responses`     | `POST /responses`                         | **o1 / o3 / o4 / codex / GPT-5 reasoning** and all reasoning models |
| `anthropic-messages`   | `POST /v1/messages`                       | Anthropic native / some proxies                                     |
| `google-generative-ai` | `POST /v1beta/models/...:generateContent` | Google AI Studio / Vertex                                           |

### Selection rules

1. **chat family (non-reasoning)** → `openai-completions`
2. **reasoning family** → **MUST** `openai-responses` (only Responses API supports `reasoning.effort`, reasoning tokens, server-side `store`)
3. When unsure, curl-probe (see §6)

### Why not mix inside one provider

`models.providers.<id>.api` is a **provider-level** transport. `models.providers.<id>.models[].api` can override per-model, but mixing two transports in one provider goes through `normalizeTransport` rewrites and tends to trigger header / streaming alignment bugs.

**Recommended: split into two providers, share baseUrl and apiKey.**

---

## 3. `api` field precedence

| Location                             | Scope                                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------------- |
| `models.providers.<id>.api`          | Default transport for **all models** under this provider — write here 99% of the time |
| `models.providers.<id>.models[].api` | **That one model** only, overrides provider-level — **not recommended**               |

Precedence: per-model `api` > provider `api` > built-in default.

---

## 4. Provider-level fields

```jsonc
"azure-chat": {
  "baseUrl": "https://<res>.openai.azure.com/openai/v1",
  "apiKey": "${AZURE_OPENAI_API_KEY}",       // Prefer env var, not plaintext
  "api": "openai-completions",               // Provider-level transport
  "headers": { "authHeader": "api-key" },    // Azure-specific: tells OpenClaw to send creds as api-key header
  "models": [ /* see §5 */ ]
}
```

Inject the env var into systemd:

```bash
sudo systemctl edit openclaw
# Append under [Service]
Environment=AZURE_OPENAI_API_KEY=<your-key>
sudo systemctl daemon-reload
sudo systemctl restart openclaw
```

---

## 5. Per-model fields

`models[]` accepts two forms:

**Shorthand strings** (all defaults):
```jsonc
"models": ["gpt-4.1", "gpt-5.4-mini"]
```

**Object form** (tunable):
```jsonc
"models": [
  {
    "id": "o4",                     // = Azure deployment name (case-sensitive)
    "name": "Azure o4 (reasoning)", // UI display name
    "reasoning": true,              // Reasoning model flag, default false
    "input": ["text", "image"],     // Input modalities, default ["text"]
    "contextWindow": 272000,        // Upstream context window (metadata), default 200000
    "contextTokens": 128000,        // OpenClaw runtime packing cap, can be < contextWindow
    "maxTokens": 32000,             // Per-request output cap, default 8192
    "cost": {                       // For /usage stats only, does NOT affect routing; leave 0 for Foundry
      "input": 15.0,
      "output": 60.0,
      "cacheRead": 1.5,
      "cacheWrite": 18.75
    },
    "compat": {
      "supportsDeveloperRole": false, // Azure openai-completions auto-disables this; explicit is fine
      "requiresStringContent": false  // Rare legacy endpoints need string content
    }
  }
]
```

### Defaults when omitted

| Field           | Default           |
| --------------- | ----------------- |
| `reasoning`     | `false`           |
| `input`         | `["text"]`        |
| `cost`          | all 0             |
| `contextWindow` | `200000`          |
| `contextTokens` | = `contextWindow` |
| `maxTokens`     | `8192`            |

**Rule of thumb: only write fields where you deviate from the default.** For Foundry you typically only need `contextWindow` / `contextTokens` / `maxTokens` / `reasoning`; `cost` can usually be omitted.

### `contextWindow` vs `contextTokens`

- `contextWindow`: upstream original context window — metadata, shown in UI / diagnostics
- `contextTokens`: OpenClaw's actual packing cap per turn — **controls real billing**

Example: Azure o4 is 272K upstream, but you want to cap cost → `"contextTokens": 128000`.

### About "compact"

If you meant **conversation compaction (long-chat summarization)**, that lives at `agents.defaults.compaction`, not in provider / model blocks. See the operations manual.

---

## 6. Full example: chat + reasoning dual provider

Production-ready minimal config — one Foundry resource registered twice under different `api`:

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

Apply:

```bash
# Merge the snippet into ~/.openclaw/openclaw.json
sudo systemctl restart openclaw
openclaw models status --probe   # Expect all 4 green
```

Switch in Chat UI with `/model std`, `/model mini`, `/model think`.

---

## 7. Real-world example: one Azure AI Foundry resource, 4 models

This section is a **verified working config** from a live azure-claw deployment, with 4 deployments on a single Azure AI Foundry resource — OpenAI native and third-party models combined.

### 7.1 Scenario

- Foundry resource: `shuaihua-azureai-foundry.openai.azure.com`
- 4 deployments (name = `models[].id`):
  - `gpt-5.1-chat` — GPT-5.1 chat family
  - `gpt-4.1` — GPT-4.1
  - `Kimi-K2.5` — Moonshot Kimi K2.5 (third-party on Foundry)
  - `DeepSeek-V3.2` — DeepSeek V3.2 (third-party on Foundry)
- All 4 deployments require `max_completion_tokens`, not `max_tokens`
- All 4 deployments reject Responses API server-side `store`

### 7.2 Key findings

Lessons learned the hard way:

1. **Azure V1 endpoint accepts both `api` values for chat models.** GPT-4.1 returns 200 on either `openai-completions` or `openai-responses`, as long as you set both compat flags:
   - `"compat": { "maxTokensField": "max_completion_tokens", "supportsStore": false }`
2. **Third-party models** (Kimi / DeepSeek) on Azure Foundry **also require `max_completion_tokens`** — legacy `max_tokens` returns 400.
3. **`apiKey` and `headers.api-key` may hold the same value simultaneously.** OpenClaw prefers `headers.api-key` (pass-through), with `apiKey` as provider-level fallback; writing both is redundant but safe. Prefer at least `apiKey` so `openclaw doctor` recognizes it.
4. **Never install the user-level `openclaw-gateway.service`.** `openclaw onboard --install-daemon` installs a user-scope systemd unit that grabs port 18789 and conflicts with the system-scope `openclaw.service` installed by azure-claw. Symptom: endless restarts + `EADDRINUSE`. On an azure-claw VM, **never** run onboard with `--install-daemon`. If you did, clean up with:
   ```bash
   systemctl --user stop openclaw-gateway.service
   systemctl --user disable openclaw-gateway.service
   sudo systemctl restart openclaw
   ```

### 7.3 Complete config snippet

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
        "baseUrl": "https://shuaihua-azureai-foundry.openai.azure.com/openai/v1",
        "api": "openai-responses",                                 // openai-completions also works
        "apiKey": "<AZURE_OPENAI_KEY>",
        "headers": { "api-key": "<AZURE_OPENAI_KEY>" },            // Azure auth header
        "models": [
          {
            "id": "gpt-5.1-chat",                                  // = Azure deployment name
            "name": "gpt-5.1",
            "reasoning": false,
            "input": ["text", "image"],
            "contextWindow": 128000,
            "maxTokens": 16384,
            "compat": {
              "supportsStore": false,                              // Azure rejects Responses server-side store
              "maxTokensField": "max_completion_tokens"            // Required, else 400
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
        "baseUrl": "https://shuaihua-azureai-foundry.openai.azure.com/openai/v1",
        "api": "openai-completions",                               // completions is the safer default for 3rd-party models
        "apiKey": "<AZURE_OPENAI_KEY>",
        "headers": { "api-key": "<AZURE_OPENAI_KEY>" },
        "models": [
          {
            "id": "Kimi-K2.5",
            "name": "Kimi-K2.5",
            "reasoning": false,                                    // Kimi actually emits reasoning_content — see §7.4
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

> **Security note**: in production, replace inline keys with `${AZURE_OPENAI_API_KEY}` and inject via systemd `Environment=AZURE_OPENAI_API_KEY=...` instead of storing plaintext in `openclaw.json`.

### 7.4 Kimi-K2.5 reasoning behavior

Direct curl:

```bash
curl -sS "$BASE/chat/completions" -H "api-key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"Kimi-K2.5","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":50}'
```

Returns:

```jsonc
{
  "choices": [{
    "finish_reason": "length",               // ← truncated
    "message": {
      "content": null,                        // ← empty final answer
      "reasoning_content": "The user said hi..."  // ← reasoning trace
    }
  }]
}
```

So Kimi-K2.5 on Azure is effectively a **reasoning model** — 50 tokens get consumed entirely by reasoning, leaving `content` null. Options:

- Bump `maxTokens` to 4096+ (leaves room for both reasoning and answer)
- Or move Kimi into a dedicated provider with `api: "openai-responses"` and set `"reasoning": true` on the model

### 7.5 Verification checklist

After editing config, verify in order:

```bash
# 1. Restart and wait for ready
sudo systemctl restart openclaw
sudo journalctl -u openclaw -f | grep -m1 "gateway] ready"

# 2. curl Azure directly to confirm each deployment
BASE="https://<res>.openai.azure.com/openai/v1"
KEY="<your-key>"
for M in gpt-5.1-chat gpt-4.1 Kimi-K2.5 DeepSeek-V3.2; do
  printf "%-18s  " "$M"
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" "$BASE/chat/completions" \
    -H "api-key: $KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_completion_tokens\":50}"
done

# 3. Open Control UI, enter Gateway password, send a test message
```

---

## 8. curl probe: which `api` does my deployment want?

Verify before editing config:

```bash
BASE="https://my-foundry.openai.azure.com/openai/v1"
KEY="$AZURE_OPENAI_API_KEY"
DEPLOY="o4"   # Your Azure deployment name

# Probe openai-completions
curl -sS -o /tmp/a.json -w "completions: %{http_code}\n" \
  "$BASE/chat/completions" \
  -H "api-key: $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$DEPLOY\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16}"

# Probe openai-responses
curl -sS -o /tmp/b.json -w "responses:   %{http_code}\n" \
  "$BASE/responses" \
  -H "api-key: $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$DEPLOY\",\"input\":\"hi\",\"max_output_tokens\":16}"
```

**Interpretation**:

- Both `200` → chat family, pick `openai-completions` (more stable)
- Only `/responses` returns 200, `/chat/completions` returns 400 + `Use Responses API` → reasoning family, must use `openai-responses`
- Both `404` → deployment name typo or wrong resource URL
- `401` → bad `api-key`

---

## 9. Common errors

| Error | Cause | Fix |
| --- | --- | --- |
| `Model not allowed` | id not listed in `models[]` | Add the deployment name to `models[]` |
| `400 Unsupported parameter: 'max_tokens'` / `Use 'max_completion_tokens'` | Azure Foundry GPT-5.x / Kimi / DeepSeek no longer accept `max_tokens` | Add `"compat": { "maxTokensField": "max_completion_tokens" }` to that model |
| `EADDRINUSE 127.0.0.1:18789` + systemd restart loop | A user-scope `openclaw-gateway.service` grabbed the port | `systemctl --user stop/disable openclaw-gateway.service && sudo systemctl restart openclaw` |
| `404 DeploymentNotFound` | Case / spelling mismatch | Check Foundry portal for the exact deployment name |
| `400 The reasoning model requires the Responses API` | Reasoning model on `openai-completions` | Change provider `api` to `openai-responses` |
| `401 Unauthorized` | Wrong key or missing authHeader | Add `"headers": { "authHeader": "api-key" }` |
| `Messages content must be a string` | Legacy endpoint wants string content | Set `"compat": { "requiresStringContent": true }` on that model |
| `model not found: primary` at startup | `primary` ref doesn't resolve | Use full `provider/model` form |
| Reply is `content: null` + `finish_reason: "length"` | Model is actually reasoning-capable, `maxTokens` too small | Raise `maxTokens` to 4096+, or move to an `openai-responses` provider with `reasoning: true` |

---

## 10. Comparison with legacy `/openai/deployments` format

You may have seen this in old Azure docs or old OpenClaw samples. **Don't use it**:

```jsonc
// ❌ Legacy (not recommended)
{
  "baseUrl": "https://<res>.openai.azure.com/openai/deployments/gpt-4.1",
  "api": "openai-completions",
  "models": [{ "id": "gpt-4.1" }]
}
```

Problems: baseUrl hard-codes the deployment, **one provider = one model**, and each request needs `?api-version=...` which OpenClaw's built-in adapters don't append.

**Always use `/openai/v1` + `models[]`**, one provider handles N deployments cleanly.

---

## 11. Related

- Operations manual: [guide-operations.md](./guide-operations.md)
- Slack channel: [guide-slack.md](./guide-slack.md)
- Teams channel: [guide-teams.md](./guide-teams.md)
- OpenClaw Configuration Reference: <https://docs.openclaw.ai/gateway/configuration-reference>
- Azure OpenAI V1-compatible endpoint: <https://learn.microsoft.com/azure/ai-services/openai/reference>
