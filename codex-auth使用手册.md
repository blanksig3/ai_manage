# codex-auth 简明使用手册

在 PowerShell 或 Windows Terminal 中使用以下三个命令：

```powershell
codex-auth login
```

登录并添加一个 Codex 账号。需要添加其他账号时，再运行一次并完成登录。

```powershell
codex-auth list
```

查看已保存的账号和可用的额度信息。

```powershell
codex-auth switch
```

选择并切换已保存的账号。切换后重启 Codex，让新账号生效。

使用本便携版的右键启动器时，选择 Codex 后也可以在启动前选择已保存的账号。

导入 API Key、账号别名、导入导出及其他功能，请查看 [codex-auth 项目说明](https://github.com/Loongphy/codex-auth)和[完整命令文档](https://github.com/Loongphy/codex-auth/blob/main/docs/commands/README.md)。`codex-auth` 是第三方工具，请妥善保管账号认证文件和密钥。
