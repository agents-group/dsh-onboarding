# DeepSeek Harness Onboarding

面向团队分发的 **DeepSeek Harness（dsh）** 上手站点：快速启动页 + 使用手册 + 跨平台一键脚本。

用户复制一条命令即可：

1. 检测本机 Node.js / npm / npx  
2. 尝试安装缺失依赖  
3. 写入预置 `DEEPSEEK_API_KEY` 与 `DEEPSEEK_BASE_URL`  
4. 执行 `npx -y @deepseek-ai/dsh web`

## 目录

```
dsh-onboarding/
  index.html           # 快速启动
  guide.html           # 使用手册
  assets/              # 样式与前端逻辑
  config/defaults.json # 预置 Key / 端点（部署前必改）
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

## 用户命令（部署后）

**Windows (PowerShell)**

```powershell
irm https://<你的域名>/dsh-onboarding/scripts/bootstrap.ps1 | iex
```

**macOS / Linux**

```bash
curl -fsSL https://<你的域名>/dsh-onboarding/scripts/bootstrap.sh | bash
```

页面会根据当前访问 URL 自动生成可复制命令。若通过 `file://` 打开，可在首页填写「站点根 URL」。

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
