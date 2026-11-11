# AI 全局规则 + 右键启动（Windows 便携版）

当前版本：**0.0.1**（见 VERSION）。

这是一份可交给其他 Windows 用户使用的独立安装包，包含：

- 全局规则、记忆路由、模板和自检工具；
- “在此打开 AI 终端”右键菜单；
- Claude Code / Codex / Grok 与直连 / 7899 代理选择；
- Codex 账号列表、用量显示与启动前账号切换；
- 选完 AI 和代理后，直接在右键目录进入工具自身的交互界面；
- 一键安装、卸载、安装检查和 SHA-256 完整性清单。

包内不含作者的会话记录、Cookie、Token、历史索引、启动器状态、项目数据、备份或个人绝对路径。

## 最快安装

1. 完整解压 ZIP；不要只单独复制某个脚本。
2. 可先安装 Claude Code、Codex 或 Grok；未安装的工具在选择时会打开安装说明。
3. 双击 `安装.cmd`。Windows 10 未安装 Windows Terminal 时会打开包内安装程序；请完成安装，回到原窗口按回车。若安装未完成，按提示重新运行。
4. 安装完成后，在任意文件夹空白处或文件夹图标上右键，选择“在此打开 AI 终端”。Windows 11 通常位于“显示更多选项”中。
5. 双击 `检查安装.cmd` 可再次核验。

不需要管理员权限；右键菜单只写当前用户的 `HKCU`。

## 默认安装位置

| 内容 | 位置 |
|---|---|
| 全局规则 | `%USERPROFILE%\.ai-global-rules` |
| 启动器 | `%USERPROFILE%\.local\bin\ai-picker.ps1` |
| 启动器配置 | `%USERPROFILE%\.local\bin\ai-tools.json` |
| 安装状态 | `%USERPROFILE%\.ai-global-rules-install.json` |
| 可恢复备份 | `%USERPROFILE%\.ai-global-rules-backup\时间戳-*` |

安装器会在以下用户文件中维护一个带明确起止标记的受管块：

- `%USERPROFILE%\.claude\CLAUDE.md`
- `%USERPROFILE%\.codex\AGENTS.md`

已有内容不会被整文件覆盖；重复安装只更新本包自己的受管块。块缺失、重复或损坏时，安装器会停止并保留备份。Codex 的全局 `~/.codex/AGENTS.md` 发现机制见 [OpenAI 官方说明](https://developers.openai.com/codex/guides/agents-md)。

## 右键启动流程

```text
选择 AI（1 Claude、2 Codex、3 Grok）
  → 选择代理或直连
  → Codex：显示账号和用量，选择账号
  → 进入所选工具
```

- 选择代理时按键盘 `↑` 返回选择 AI；选择 AI 时按 `↑` 退出。
- 启动器不扫描、归类、恢复或清理历史会话，也不维护会话指针。
- 需要历史记录时，进入工具后使用 Claude Code 或 Codex 自己的会话命令。
- 启动目录就是右键点击的目录；启动器不会替你切换项目。
- 首次选择 Codex 且没有 `codex-auth` 时，会通过 npm 安装 `@loongphy/codex-auth`；需要 Node.js、npm 和网络。缺少 npm 时打开 Node.js 下载页面。
- 三个常用账号命令参见 [codex-auth 简明使用手册](codex-auth使用手册.md)。
- 请先使用 `codex-auth login` 添加账号；列表及额度由第三方 `codex-auth` 提供，刷新需要网络。账号默认选中当前账号，按上下方向键选择、回车确认、Esc 取消。
- 支持已由 `codex-auth` 管理的 OpenAI 官方 API Key；选择列表会标明 API Key 和脱敏指纹，以便区分同一邮箱下的多个密钥。若已有官方 API Key 格式的 Codex 认证文件，可通过 `codex-auth import <认证文件路径> --alias <名称>` 添加；导入需要联网验证。认证文件含密钥，不要分享或提交到仓库。API Key 使用 API 计费，额度信息与 ChatGPT 订阅不同。

## 工具探测与配置

安装器按以下顺序寻找工具：

1. 显式参数 `-ClaudeExe`、`-CodexExe`；
2. 当前 `PATH` 中的命令；
3. `%APPDATA%\npm` 下的常见 `.cmd` / `.exe`。

默认第一个网络选项是 `127.0.0.1:7899` 代理，第二个是“直连”。可编辑安装后的 `ai-tools.json` 调整代理、危险参数或工具路径。

> 当前 Claude/Codex 启动参数包含跳过权限确认的选项，只应在信任的目录使用。若希望每次确认权限，请从 `openArgs` 删除对应的 `dangerously-*` 参数。

## PowerShell 安装参数

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\安装.ps1
```

常用参数：

```powershell
# 明确指定工具
.\安装.ps1 -ClaudeExe C:\Tools\claude.exe -CodexExe C:\Tools\codex.exe

# 已有同名但非本安装器所有的目录时，确认覆盖（安装前仍会备份）
.\安装.ps1 -Force

# 隔离测试：所有文件写入测试根，不碰真实注册表
.\安装.ps1 -TestRoot C:\Temp\AI-Package-Test `
  -ClaudeExe C:\Temp\fake-claude.cmd -CodexExe C:\Temp\fake-codex.cmd
```

安装器不修改 Windows Terminal 的 `settings.json`。Windows 10 需要先安装 Windows Terminal；安装窗口可能需要联网或 Microsoft Store，完成后须启用 `wt.exe` 应用执行别名。Windows 11 检测到 `wt.exe` 时使用 Windows Terminal，否则回退到 Windows PowerShell。

## 卸载

双击 `卸载.cmd`，或运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\卸载.ps1
```

卸载器会：

- 只删除 Claude/Codex 文件中的本包受管块；
- 只恢复本包安装前记录的右键菜单状态；
- 将已安装规则和启动器移入可恢复卸载备份；
- 如安装前已有同名规则/脚本，恢复原副本；
- 保留 Claude/Codex 会话和项目文件。

## 包结构

```text
安装.cmd / 安装.ps1
卸载.cmd / 卸载.ps1
检查安装.cmd / 检查安装.ps1
payload/
  global-rules/
  launcher/
manifest.sha256
```

安装前会核对 `manifest.sha256`，任何缺失或哈希变化都会停止安装。安装后的规则目录也会生成独立哈希清单，供 `检查安装.ps1` 复核。

## 兼容边界

- 目标：Windows 10/11、Windows PowerShell 5.1 或 PowerShell 7。
- 使用某个 AI 前需先安装对应命令行工具；账号选择还需要 codex-auth 和已登录的账号。
- Windows 10 需要 Windows Terminal；Windows 11 可回退到 Windows PowerShell。
- 历史会话由 Claude Code/Codex 自己管理，启动器不依赖其本地会话文件布局。
- 全局规则是协作纪律与操作约束，仍服从平台系统/开发者指令。
