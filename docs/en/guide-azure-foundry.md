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

## 7. curl probe: which `api` does my deployment want?

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

## 8. Common errors

| Error                                                | Cause                                   | Fix                                                             |
| ---------------------------------------------------- | --------------------------------------- | --------------------------------------------------------------- |
| `Model not allowed`                                  | id not listed in `models[]`             | Add the deployment name to `models[]`                           |
| `404 DeploymentNotFound`                             | Case / spelling mismatch                | Check Foundry portal for the exact deployment name              |
| `400 The reasoning model requires the Responses API` | Reasoning model on `openai-completions` | Change provider `api` to `openai-responses`                     |
| `401 Unauthorized`                                   | Wrong key or missing authHeader         | Add `"headers": { "authHeader": "api-key" }`                    |
| `Messages content must be a string`                  | Legacy endpoint wants string content    | Set `"compat": { "requiresStringContent": true }` on that model |
| `model not found: primary` at startup                | `primary` ref doesn't resolve           | Use full `provider/model` form                                  |

---

## 9. Comparison with legacy `/openai/deployments` format

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

## 10. Related

- Operations manual: [guide-operations.md](./guide-operations.md)
- Slack channel: [guide-slack.md](./guide-slack.md)
- Teams channel: [guide-teams.md](./guide-teams.md)
- OpenClaw Configuration Reference: <https://docs.openclaw.ai/gateway/configuration-reference>
- Azure OpenAI V1-compatible endpoint: <https://learn.microsoft.com/azure/ai-services/openai/reference>
