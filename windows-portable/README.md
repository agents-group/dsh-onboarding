# Windows 便携引导包（下载即跑）

面向 **几乎裸机的 Windows**：下载 zip → 解压 → 双击 `start.cmd`。

## 它怎么工作

```
本 zip（临时环境）
  ├─ runtime/node     临时 Node（构建时打入，或首次自动下载）
  ├─ agent/           安装初始化 Agent（bootstrap.ps1）
  ├─ config/          预置 Key / 端点
  ├─ start.cmd        入口
  └─ cleanup.cmd      成功后删除本目录

        │  初始化 Agent
        ▼

本机持久化（保留）
  ├─ %LOCALAPPDATA%\dsh-onboarding\node\v*   持久 Node
  ├─ %LOCALAPPDATA%\dsh-onboarding\start-dsh.cmd
  ├─ %LOCALAPPDATA%\dsh-onboarding\install-state.json
  └─ %USERPROFILE%\.dsh\                     API Key / 端点
```

初始化完成后，**可以删掉整个便携目录**；以后用持久启动器或 `npx @deepseek-ai/dsh web`。

## 使用

1. 下载 `dsh-onboarding-windows-portable.zip`
2. 解压到任意目录（不要放需要管理员权限的路径）
3. 双击 `start.cmd`
4. 按提示完成（可自动打开 Web UI）
5. 可选：双击 `cleanup.cmd` 删除临时包

### 仅安装不启动

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -NoLaunch
```

## 本地构建 zip

在仓库根目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows-portable.ps1
```

产物：`dist/dsh-onboarding-windows-portable.zip`

## 设计取舍

| 项目 | 说明 |
|------|------|
| 临时环境 | zip 内 Node + Agent，只为完成初始化 |
| 持久环境 | LocalAppData Node + `.dsh` 凭据 + start-dsh.cmd |
| 为何不全部装进 zip 永久用 | zip 路径常变/易删；持久化到 LocalAppData 更稳 |
| 与在线 `irm \| iex` | 便携包弱网/无 winget 更稳；在线脚本更轻 |
