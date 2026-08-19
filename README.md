# DeepSeek Harness Onboarding

面向团队分发的 **DeepSeek Harness（dsh）** 上手站点：快速启动页 + 使用手册 + 跨平台一键脚本。

## 快速启动地址

**推荐（Cloudflare Pages）**

- 快速启动：https://dsh-onboarding.pages.dev/
- 使用手册：https://dsh-onboarding.pages.dev/guide

**备用（GitHub Pages）**

- 快速启动：https://agents-group.github.io/dsh-onboarding/
- 使用手册：https://agents-group.github.io/dsh-onboarding/guide.html

> 日常请优先把 Cloudflare 地址发给用户；GitHub Pages 仅作备用。推送到 `main` 后，Actions 会自动同步到 Cloudflare。  
> 代码仓库：https://github.com/agents-group/dsh-onboarding  
> 组织共用 Secrets：https://github.com/organizations/agents-group/settings/secrets/actions

用户打开快速启动页，复制一条命令即可。脚本内是 **本地环境 Agent**（playbook，不是云端 LLM）：

1. **观察**本机 OS / Node / npm / npx / 凭据等事实  
2. **诊断**缺口并选择修复动作（多轮，失败会换策略或提示人工）  
3. 写入预置 `DEEPSEEK_API_KEY` 与 `DEEPSEEK_BASE_URL`  
4. 环境就绪后执行 `npx -y @deepseek-ai/dsh web`

CI：`.github/workflows/deploy-cloudflare-pages.yml`  
组织 Secrets（`agents-group` 下所有仓库可共用）：`CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID`

## 目录

```
.
  index.html           # 快速启动
  guide.html           # 使用手册
  assets/              # 样式与前端逻辑
  config/defaults.json # 预置 Key / 端点
  scripts/
    bootstrap.ps1      # Windows
    bootstrap.sh       # macOS / Linux
```

## 部署前必做

编辑 `config/defaults.json`：

```json
{
  "apiKey": "sk-你的真实密钥",
  "baseURL": "https://你的端点"
}
```

并同步修改：

- `scripts/bootstrap.ps1` 顶部 `$Script:DefaultApiKey` / `$Script:DefaultBaseURL`
- `scripts/bootstrap.sh` 顶部 `DEFAULT_API_KEY` / `DEFAULT_BASE_URL`

> 将真实密钥放在公开站点意味着任何人都可能获取该 Key。请使用可吊销、可限流的团队 Key。

## 本地预览

```bash
cd dsh-onboarding
python -m http.server 4173
# 浏览器打开 http://127.0.0.1:4173
```

## 用户命令（Cloudflare Pages）

打开 https://dsh-onboarding.pages.dev/ 复制即可；命令示例：

**Windows (PowerShell)**

```powershell
$env:DSH_ONBOARD_CONFIG_URL='https://dsh-onboarding.pages.dev/config/defaults.json'; irm 'https://dsh-onboarding.pages.dev/scripts/bootstrap.ps1' | iex
```

**macOS / Linux**

```bash
curl -fsSL 'https://dsh-onboarding.pages.dev/scripts/bootstrap.sh' | bash -s -- --config-url 'https://dsh-onboarding.pages.dev/config/defaults.json'
```

页面会根据当前访问 URL 自动生成可复制命令。

## 凭据落盘位置

| 文件 | 内容 |
|------|------|
| `~/.dsh/.credentials.yaml` | `DEEPSEEK_API_KEY` |
| `~/.dsh/.env` | `DEEPSEEK_BASE_URL`（及 Key 后备） |

可用环境变量 `DSH_HOME` 覆盖根目录。

## 参数与覆盖

| 方式 | Windows | Unix |
|------|---------|------|
| 仅检查 | `.\bootstrap.ps1 -CheckOnly` | `--check-only` |
| 只配置不启动 | `-NoLaunch` | `--no-launch` |
| 覆盖 Key | `-ApiKey` | `--api-key` |
| 覆盖端点 | `-BaseURL` | `--base-url` |
| 远程配置 | `-ConfigUrl` / `DSH_ONBOARD_CONFIG_URL` | 同左 |

## 静态托管注意

- 建议 HTTPS  
- 保证 `config/defaults.json` 与 `scripts/*` 可直接 GET  
- Nginx 无需特殊配置；GitHub Pages 将本目录作为发布根或子路径均可  
