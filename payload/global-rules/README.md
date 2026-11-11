---
scope: human-readme
status: active
owner: user
created: 2026-08-31
updated: 2026-09-29
review_after: 2027-09-01
source: 2026-09-02 通用合并版
---

# 全局 AI 协作规则

这是面向人阅读的入口。强制执行入口是 [CLAUDE.md](CLAUDE.md)。

本规则库是本机唯一的全局规则，Claude 和 Codex 共用：用户级 `~/.claude/CLAUDE.md` 和 `~/.codex/AGENTS.md` 各只保存一句指向 [CLAUDE.md](CLAUDE.md)，项目自己的 `CLAUDE.md` / `AGENTS.md` 只管自己的项目。

核心流程只有一条：

`用户请求 → 复述范围 → 任务设计清单 → 四维路由/联动图 → 备份 → 受控操作 → 节点与边验证 → 最终完成清单 → 结果报告`

按问题进入：

- 规则模块与读取路由：[memory/README.md](memory/README.md)
- 五类业务的通用小票模板字段接口（不是原票字段清单）：[通用小票字段约定.md](通用小票字段约定.md)
- 清单填写载体：[templates/README.md](templates/README.md)
- 设计依据与证据原则：[sources/依据_理论与实践.md](sources/依据_理论与实践.md)
- 动态状态与最近验证：[STATE.md](STATE.md)
- 本库的改动历史与回退点：[变更记录.md](变更记录.md)
- 文档完整性检查：[tools/check_docs.ps1](tools/check_docs.ps1)

本库不使用 git。改动前按 [备份规则](memory/02_操作与变更控制.md#备份铁律) 仅保存受改文件的回退内容，改完在 [变更记录.md](变更记录.md) 记一条。

检查器用法：

- `powershell -File tools/check_docs.ps1` 全库检查
- `powershell -File tools/check_docs.ps1 -SelfTest` 反例自检
- `powershell -File tools/check_docs.ps1 -AsOf 2027-06-01` 按指定日期判断复审到期
