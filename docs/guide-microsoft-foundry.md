# 操作手册：配置 Azure OpenAI / Microsoft Foundry 作为 AI 模型提供商

本手册介绍如何将 OpenClaw Gateway 连接到 **Azure OpenAI Service** 或 **Microsoft Foundry**，使用 Azure 托管的 GPT-4.1、GPT-5.4-mini 等模型为你的 AI 助手提供能力。

---

## 目录

1. [前置条件](#一前置条件)
2. [创建 Azure OpenAI 资源](#二创建-azure-openai-资源)
3. [部署模型](#三部署模型)
4. [获取连接信息](#四获取连接信息)
5. [配置 OpenClaw](#五配置-openclaw)
6. [验证连接](#六验证连接)
7. [使用 Microsoft Foundry（可选）](#七使用-microsoft-foundry可选)
8. [Entra ID 免密认证（推荐生产环境）](#八entra-id-免密认证推荐生产环境)
9. [常见问题](#九常见问题)

---

## 一、前置条件

- 已完成 Azure Claw 部署（参见主 [README](../README.md)）
- Azure 订阅已开通 Azure OpenAI Service 访问权限
  > 如尚未开通，前往 [Azure OpenAI 申请页面](https://aka.ms/oai/access) 提交申请
- 已通过 SSH (Ubuntu) 或 RDP (Windows) 连接到 VM

---

## 二、创建 Azure OpenAI 资源

### 方式 A：Azure Portal

1. 登录 [Azure Portal](https://portal.azure.com/)
2. 搜索 **Azure OpenAI** → 点击 **创建**
3. 填写信息：
   - **订阅**: 选择你的 Azure 订阅
   - **资源组**: 可使用 `rg-openclaw` 或新建
   - **区域**: 选择支持所需模型的区域（如 `East US`、`Sweden Central`）
   - **名称**: 如 `openclaw-aoai`
   - **定价层**: `Standard S0`
4. 点击 **Review + create** → **Create**

### 方式 B：Azure CLI

在本地或 VM 上执行：

```bash
# 创建 Azure OpenAI 资源
az cognitiveservices account create \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --kind OpenAI \
  --sku S0 \
  --location eastus
```

> **区域选择提示**: 不同区域支持的模型不同。GPT-4o 建议选择 `eastus`、`eastus2`、`swedencentral` 或 `westus3`。完整区域模型矩阵参见 [Azure OpenAI 模型可用性](https://learn.microsoft.com/azure/ai-services/openai/concepts/models#model-summary-table-and-region-availability)。

---

## 三、部署模型

在 Azure OpenAI 资源中部署一个模型供 OpenClaw 使用。

### 方式 A：Azure Portal

1. 进入刚创建的 Azure OpenAI 资源
2. 左侧菜单 → **Model deployments** → **Manage Deployments**（跳转到 Microsoft Foundry）
3. 点击 **+ Create new deployment**
4. 填写信息：
   - **模型**: 选择 `gpt-4.1`（推荐）或 `gpt-5.4-mini`（轻量快速）
   - **部署名称**: 如 `gpt-4.1`（建议与模型名一致，方便配置）
   - **部署类型**: `Standard`
   - **TPM 配额**: 根据需求设置（个人使用 30K~80K 足够）
5. 点击 **Create**

### 方式 B：Azure CLI

```bash
# 部署 gpt-4.1 模型
az cognitiveservices account deployment create \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --deployment-name gpt-4.1 \
  --model-name gpt-4.1 \
  --model-version "2025-04-14" \
  --model-format OpenAI \
  --sku-capacity 30 \
  --sku-name Standard
```

> **推荐模型**:
>
> | 模型 | 特点 | 适合场景 |
> | --- | --- | --- |
> | `gpt-4.1` | 高质量推理，代码能力强 | 日常编码助手 |
> | `gpt-5.4-mini` | 快速响应，成本低 | 轻量问答、频繁调用 |

---

## 四、获取连接信息

配置 OpenClaw 需要以下两项信息：

### 获取 Endpoint 和 API Key

#### 方式 A：Azure Portal

1. 进入 Azure OpenAI 资源
2. 左侧菜单 → **Keys and Endpoint**
3. 记录以下信息：
   - **Endpoint**: 如 `https://openclaw-aoai.openai.azure.com/`
   - **Key 1**: 如 `abc123...`（任选 Key 1 或 Key 2）

#### 方式 B：Azure CLI

```bash
# 获取 Endpoint
az cognitiveservices account show \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --query properties.endpoint \
  --output tsv

# 获取 API Key
az cognitiveservices account keys list \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --query key1 \
  --output tsv
```

---

## 五、配置 OpenClaw

SSH 登录到 VM 后（Windows 则在 WSL 中操作），编辑 OpenClaw 配置文件：

### 方式 A：使用 `openclaw onboard` 交互式配置

```bash
openclaw onboard
```

在交互式向导中：
1. 选择 Model Provider → **Azure OpenAI**
2. 输入 Endpoint URL
3. 输入 API Key
4. 选择部署名称（如 `gpt-4.1`）
5. 完成配置

### 方式 B：手动编辑配置文件

```bash
nano ~/.openclaw/openclaw.json
```

写入以下内容：

```jsonc
{
  "agent": {
    // 格式: azure/<部署名称>
    "model": "azure/gpt-4.1"
  },
  "providers": {
    "azure": {
      "apiKey": "<你的 Azure OpenAI API Key>",
      "baseURL": "https://openclaw-aoai.openai.azure.com/openai/deployments/gpt-4.1",
      "apiVersion": "2024-12-01-preview"
      // 可选：如果使用 Microsoft Entra ID 认证，设为 true 并省略 apiKey
      // "useAzureAD": true
    }
  }
}
```

**配置说明**：

| 字段                         | 说明                    | 示例                                                      |
| ---------------------------- | ----------------------- | --------------------------------------------------------- |
| `agent.model`                | `azure/<部署名称>`      | `azure/gpt-4.1`                                           |
| `providers.azure.apiKey`     | Azure OpenAI 的 API Key | `CtQcuGGH...`                                             |
| `providers.azure.baseURL`    | Endpoint + 部署路径     | `https://xxx.openai.azure.com/openai/deployments/gpt-4.1` |
| `providers.azure.apiVersion` | API 版本                | `2024-12-01-preview`                                      |

> **Endpoint 格式说明**: Azure OpenAI 的 Endpoint 有两种格式，注意区分：
>
> | 格式 | 示例 | 用途 |
> | --- | --- | --- |
> | **OpenAI 终结点**（域名） | `https://xxx.openai.azure.com/` | SDK 或直接调用模型 |
> | **项目终结点**（含 `/api/projects/`） | `https://xxx.services.ai.azure.com/api/projects/...` | Foundry Agent 管理（OpenClaw 不使用） |
>
> OpenClaw 使用的是 **OpenAI 终结点** 加上部署路径。如果你在 Microsoft Foundry 门户看到的终结点带 `/openai/v1` 后缀，去掉后缀使用域名部分即可。

### 重启服务

```bash
# Ubuntu
sudo systemctl restart openclaw

# 检查状态
sudo systemctl status openclaw
```

---

## 六、验证连接

### 检查 Gateway 日志

```bash
# 查看实时日志
journalctl -u openclaw -f
```

正常启动应看到类似输出：

```
OpenClaw Gateway started on 0.0.0.0:18789
Model provider: Azure OpenAI (gpt-4o)
Ready to accept connections
```

### 发送测试消息

1. 浏览器打开 `http://<VM_PUBLIC_IP>:18789`
2. 在 WebChat 中发送一条消息
3. 确认收到 AI 回复

### 运行诊断

```bash
openclaw doctor
```

确保所有检查项通过，特别关注 `Model connectivity` 一项。

---

## 七、使用 Microsoft Foundry（可选）

如果你通过 **Microsoft Foundry**（[ai.azure.com](https://ai.azure.com/)）统一管理模型，可以直接使用 Foundry 的端点。

### 7.1 两种终结点说明

登录 ai.azure.com → 你的项目 → **Overview** 页面，会看到两个终结点：

```
项目终结点（Project endpoint）
  https://<resource>.services.ai.azure.com/api/projects/<project>
  → 用于 Microsoft Foundry Agent 管理（AIProjectClient），OpenClaw 不使用

Azure OpenAI 终结点
  https://<resource>.openai.azure.com/
  → 用于直接调用模型，OpenClaw 使用此终结点
```

| 终结点        | 格式                                                        | OpenClaw 是否使用 |
| ------------- | ----------------------------------------------------------- | ----------------- |
| 项目终结点    | `https://<resource>.services.ai.azure.com/api/projects/...` | **不使用**        |
| OpenAI 终结点 | `https://<resource>.openai.azure.com/`                      | **使用**          |

> OpenClaw 是 OpenAI 兼容 API 的客户端，只需要 OpenAI 终结点 + API Key + 部署名。项目终结点是给 Azure SDK（如 `AIProjectClient`）管理 Microsoft Foundry Agent 用的，与 OpenClaw 无关。

### 7.2 从 Microsoft Foundry 门户获取连接信息

1. 登录 [ai.azure.com](https://ai.azure.com/) → 选择你的项目
2. **Overview** 页面 → 复制 **Azure OpenAI 终结点**（不是项目终结点）
3. 复制 **API 密钥**
4. **Models + endpoints** 页面 → 查看已部署的模型名称（即部署名）

### 7.3 配置 OpenClaw

```jsonc
{
  "agent": {
    "model": "azure/gpt-4.1"
  },
  "providers": {
    "azure": {
      "apiKey": "<Microsoft Foundry 门户复制的 API Key>",
      "baseURL": "https://<resource>.openai.azure.com/openai/deployments/gpt-4.1",
      "apiVersion": "2024-12-01-preview"
    }
  }
}
```

> **注意**: Microsoft Foundry 门户显示的 OpenAI 终结点可能带 `/openai/v1` 后缀，OpenClaw 配置时需要改为 `/openai/deployments/<部署名>` 格式。

---

## 八、Entra ID 免密认证（推荐生产环境）

在生产环境中，推荐使用 **Microsoft Entra ID**（原 Azure AD）免密认证，而非 API Key。通过为 VM 配置**托管标识（Managed Identity）**，无需在配置文件中存储 API Key。

### 8.1 启用 VM 托管标识

```bash
# 为 VM 启用 System-Assigned Managed Identity
az vm identity assign \
  --name openclaw-vm \
  --resource-group rg-openclaw
```

### 8.2 分配 RBAC 角色

Managed Identity 需要被授予正确的角色才能调用模型：

| 操作                              | 最小角色                                | 说明                       |
| --------------------------------- | --------------------------------------- | -------------------------- |
| 调用模型（Chat/Completions）      | `Cognitive Services OpenAI User`        | 最常用，满足 OpenClaw 需求 |
| 创建/管理 Microsoft Foundry Agent | `Cognitive Services OpenAI Contributor` | 仅当需要管理 Agent 时      |
| 读取 Microsoft Foundry 项目配置   | `Azure AI Developer`                    | 仅当使用项目终结点时       |

> **最佳实践**: 始终使用最小权限原则。OpenClaw 仅调用模型，只需 `Cognitive Services OpenAI User` 角色。

```bash
# 获取 VM 的托管标识 Principal ID
VM_PRINCIPAL_ID=$(az vm show \
  --name openclaw-vm \
  --resource-group rg-openclaw \
  --query identity.principalId \
  --output tsv)

# 获取 Azure OpenAI 资源 ID
AOAI_RESOURCE_ID=$(az cognitiveservices account show \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --query id \
  --output tsv)

# 分配角色
az role assignment create \
  --assignee "$VM_PRINCIPAL_ID" \
  --role "Cognitive Services OpenAI User" \
  --scope "$AOAI_RESOURCE_ID"
```

### 8.3 配置 OpenClaw 使用 Entra ID

```jsonc
{
  "agent": {
    "model": "azure/gpt-4.1"
  },
  "providers": {
    "azure": {
      "baseURL": "https://openclaw-aoai.openai.azure.com/openai/deployments/gpt-4.1",
      "apiVersion": "2024-12-01-preview",
      "useAzureAD": true
      // 无需 apiKey，VM 的 Managed Identity 自动获取 Token
    }
  }
}
```

### 8.4 API Key vs Entra ID 对比

| 方式                        | 配置复杂度        | 安全性               | 适合场景           |
| --------------------------- | ----------------- | -------------------- | ------------------ |
| API Key                     | 简单（复制粘贴）  | 一般（密钥可能泄露） | 个人使用、快速验证 |
| Entra ID + Managed Identity | 需要额外配置 RBAC | 高（无需存储密钥）   | 生产环境           |

---

## 九、常见问题

### Q: 出现 `401 Unauthorized` 错误

- 检查 API Key 是否正确复制（无多余空格）
- 确认 Key 未过期或被轮转
- 如使用 Entra ID 认证，确认 VM 已分配 `Cognitive Services OpenAI User` 角色
- 多租户场景下，确认 `az login --tenant <正确租户ID>` 登录到了资源所在的租户

### Q: 出现 `404 Resource Not Found` 错误

- 检查 `baseURL` 中的**部署名称**是否与实际部署一致
- 确认 `apiVersion` 使用的是有效版本（推荐 `2024-12-01-preview`）
- 确认使用的是 **OpenAI 终结点**（`xxx.openai.azure.com`），而非项目终结点（`xxx.services.ai.azure.com/api/projects/...`）

### Q: 出现 `429 Rate Limit` 错误

- 当前 TPM 配额不足，前往 Azure Portal 增加部署的 TPM 配额
- 或等待速率限制窗口过期后自动恢复

### Q: 如何切换模型？

在 Azure OpenAI 中部署新模型后，修改配置文件中的 `model` 和 `baseURL` 中的部署名称即可。例如切换到 GPT-5.4-mini：

```jsonc
{
  "agent": {
    "model": "azure/gpt-5.4-mini"
  },
  "providers": {
    "azure": {
      "baseURL": "https://openclaw-aoai.openai.azure.com/openai/deployments/gpt-5.4-mini",
      // ...其余配置不变
    }
  }
}
```

### Q: Azure OpenAI 的费用？

Azure OpenAI 按 Token 用量计费，不同模型价格不同。个人轻度使用每月通常在 $5~$30 之间。详见 [Azure OpenAI 定价](https://azure.microsoft.com/pricing/details/cognitive-services/openai-service/)。

### Q: Microsoft Foundry 门户的 OpenAI 终结点带 `/openai/v1`，怎么填？

Microsoft Foundry 门户 Overview 页显示的 OpenAI 终结点可能类似 `https://xxx.openai.azure.com/openai/v1`。配置 OpenClaw 时，需要去掉 `/openai/v1`，改为 `/openai/deployments/<部署名>`：

```
门户显示: https://xxx.openai.azure.com/openai/v1
OpenClaw: https://xxx.openai.azure.com/openai/deployments/gpt-4.1
```

### Q: 多租户下 Entra ID 认证报 `Token tenant does not match`

说明 `az login` 或 Managed Identity 所属的租户与 Azure OpenAI 资源不在同一个租户。解决方法：

```bash
# 切换到正确的租户
az login --tenant <资源所在的租户ID>
```

---

## 参考链接

- [Azure OpenAI 官方文档](https://learn.microsoft.com/azure/ai-services/openai/)
- [Azure OpenAI REST API 参考](https://learn.microsoft.com/azure/ai-services/openai/reference)
- [Microsoft Foundry](https://ai.azure.com/)
- [Azure OpenAI 模型可用性](https://learn.microsoft.com/azure/ai-services/openai/concepts/models)
- [OpenClaw Models 文档](https://docs.openclaw.ai/concepts/models)
