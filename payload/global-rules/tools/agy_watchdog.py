# -*- coding: utf-8 -*-
"""Antigravity (AGY) 全局单例终端防闪退看门狗。

核心能力：
1. `--ensure-daemon`:
   - 由右键启动器在选定代理并启动 Antigravity 时调用；
   - 等待 `agy.exe` 真实拉起并稳定运行后，通过 Windows 命名互斥锁确认单实例；
   - 若看门狗未运行，则在独立 Windows Terminal / 控制台窗口启动 `--mode daemon --auto-start`；
   - 若看门狗已在运行，则直接退出（不重复开窗，由既有看门狗自动纳管新窗口）。
2. `--entry [目标目录]`:
   - 手动入口：未运行看门狗时直接启动全局守护；已运行时进入快速新开独立窗口模式。
3. `--mode daemon`:
   - 每 2 秒巡检存活的 `agy.exe` 窗口、匹配 `cli-*.log` 与对话 ID；
   - 仅当某个对话真实闪退时按原对话或新开零步数窗口恢复，绝不干扰其他正常窗口；
   - 当全部 Antigravity 窗口正常关闭且不再有存活进程时，看门狗监听终端自动正常退出（退出码 0）。
4. `--self-test`:
   - 使用隔离互斥锁与临时子进程验证互斥锁、正常关闭/闪退判定及全窗关闭自动退出逻辑。
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any

if os.name == "nt":
    import msvcrt
    from ctypes import wintypes
else:  # pragma: no cover - non-Windows fallback
    msvcrt = None  # type: ignore[assignment]
    wintypes = None  # type: ignore[assignment]

HOME_DIR = Path.home()
GLOBAL_RULES_ROOT = Path(__file__).resolve().parent.parent
CLI_ROOT = HOME_DIR / ".gemini" / "antigravity-cli"
BRAIN_ROOT = CLI_ROOT / "brain"
CLI_LOG_DIR = CLI_ROOT / "log"
CRASH_ROOT = CLI_ROOT / "crashes"
DEFAULT_DESKTOP_DIR = HOME_DIR / "Desktop"
WATCHDOG_ROOT = Path(
    os.environ.get("LOCALAPPDATA", str(HOME_DIR / "AppData" / "Local"))
) / "AGYWatchdog"
DEFAULT_STATE_FILE = WATCHDOG_ROOT / "state.json"
DEFAULT_MULTI_STATE_FILE = WATCHDOG_ROOT / "multi_state.json"
DEFAULT_MUTEX_NAME = r"Local\AGY_Global_Watchdog_Mutex"
DEFAULT_PROCESS_NAME = "agy.exe"
DEFAULT_PROXY_URL = "http://127.0.0.1:7899"
DEFAULT_NO_PROXY = "localhost,127.0.0.1,::1"

_PATH_TOOL_ARG_KEYS = frozenset(
    {
        "path",
        "cwd",
        "commandline",
        "scriptpath",
        "dest",
        "destination",
        "source",
        "src",
        "dir",
        "directory",
        "workdir",
        "workingdirectory",
        "file",
        "filepath",
        "targetpath",
    }
)
_WIN_PATH_RE = re.compile(r"([a-z]:/(?:[^\s\"'`<>|*?;/]+/)*[^\s\"'`<>|*?;/]+)", re.I)
_CONV_ARG_RE = re.compile(r"--conversation(?:\s+|=)(?:\"([^\"]+)\"|'([^']+)'|(\S+))")
_LOGFILE_ARG_RE = re.compile(r"--log-file(?:\s+|=)(?:\"([^\"]+)\"|'([^']+)'|(\S+))")
_ADD_DIR_ARG_RE = re.compile(r"--add-dir(?:\s+|=)(?:\"([^\"]+)\"|'([^']+)'|(\S+))")

_LS_PID_RE = re.compile(r"Starting language server process with pid (\d+)")
_INIT_WS_RE = re.compile(r"Initializing CLI store manager for workspace (.+)")
_CONV_LOG_RE = re.compile(
    r"(?:Streaming conversation|Sending user message to conversation|Created conversation)\s+([0-9a-fA-F-]{36})"
)
_CRASH_FILE_RE = re.compile(r"^crash_(\d+)_([0-9a-fA-F-]+)\.log$", re.I)
_CLI_LOG_NAME_RE = re.compile(r"^cli-(\d{8})_(\d{6})\.log$", re.I)

_MANUAL_CLOSE_CODES = frozenset({-1073741510, 3221225786})  # 0xC000013A


def _norm_path(p: str | Path) -> str:
    raw = str(p).strip()
    if not raw:
        return ""
    return os.path.normcase(os.path.normpath(raw)).rstrip("\\/")


def _norm_slash(text: str) -> str:
    return text.replace("\\\\", "/").replace("\\", "/").lower()


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _parse_optional_int(value: Any) -> int | None:
    if value is None:
        return None
    raw = str(value).strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _parse_iso_ts(value: str) -> float:
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def _parse_wmi_creation_ts(value: Any) -> float:
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        val = float(value)
        return val / 1000.0 if val > 1e12 else val
    s = str(value).strip()
    if not s:
        return 0.0
    m = re.search(r"/Date\((\d+)(?:[+-]\d+)?\)/", s)
    if m:
        return float(m.group(1)) / 1000.0
    return _parse_iso_ts(s)


def _iter_str_values(val: Any):
    if isinstance(val, str):
        yield val
    elif isinstance(val, (list, tuple)):
        for item in val:
            yield from _iter_str_values(item)
    elif isinstance(val, dict):
        for item in val.values():
            yield from _iter_str_values(item)


def _read_json_lines(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.is_file():
        return rows
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def _extract_user_request_text(raw: str) -> str:
    m = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", raw, re.S)
    text = m.group(1) if m else raw
    return text.strip()


def _is_watchdog_boilerplate(text: str) -> bool:
    if not text:
        return True
    markers = (
        "[AGY看门狗动态续跑]",
        "[AGY看门狗可视化续跑]",
        "[AGY看门狗自动恢复]",
    )
    return any(
        text.startswith(m)
        or (m in text and len(text) < 2500 and "AGYWatchdog" in text)
        for m in markers
    )


def _sanitize_one_line(text: str, max_len: int) -> str:
    cleaned = re.sub(r"[\r\n\t]+", " ", text)
    cleaned = cleaned.replace('"', "'")
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    if len(cleaned) > max_len:
        cleaned = cleaned[: max_len - 3].rstrip() + "..."
    return cleaned


def _workspace_slug(path_str: str) -> str:
    cleaned = path_str.strip().rstrip("\\/")
    leaf = Path(cleaned).name or "workspace"
    safe_leaf = re.sub(r"[^A-Za-z0-9._\-\u4e00-\u9fff]+", "_", leaf).strip("_") or "workspace"
    digest = hashlib.sha1(cleaned.lower().encode("utf-8")).hexdigest()[:8]
    return f"{safe_leaf}_{digest}"


def _run_ps_json(ps_cmd: str) -> list[dict[str, Any]]:
    kwargs: dict[str, Any] = {
        "capture_output": True,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
        "timeout": 6,
    }
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        proc = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-Command", ps_cmd],
            **kwargs,
        )
    except Exception:
        return []
    if proc.returncode != 0:
        return []
    raw = (proc.stdout or "").strip()
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except Exception:
        return []
    if isinstance(parsed, dict):
        return [parsed]
    if isinstance(parsed, list):
        return [item for item in parsed if isinstance(item, dict)]
    return []


def _query_all_processes_snapshot() -> list[dict[str, Any]]:
    ps_cmd = (
        "Get-CimInstance Win32_Process "
        "| Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine "
        "| ConvertTo-Json -Compress"
    )
    return _run_ps_json(ps_cmd)


def _query_live_agy_processes(
    process_name: str = DEFAULT_PROCESS_NAME,
    watch_pids: set[int] | None = None,
) -> list[dict[str, Any]]:
    """查询当前存活的指定进程列表（默认 agy.exe），可选按 watch_pids 精确过滤。"""
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "", process_name or DEFAULT_PROCESS_NAME)
    if not safe_name:
        safe_name = DEFAULT_PROCESS_NAME
    ps_cmd = (
        f"Get-CimInstance Win32_Process -Filter \"Name = '{safe_name}'\" "
        "| Select-Object ProcessId, ParentProcessId, CreationDate, CommandLine | ConvertTo-Json -Compress"
    )
    rows = _run_ps_json(ps_cmd)
    if watch_pids is not None:
        rows = [r for r in rows if _safe_int(r.get("ProcessId"), 0) in watch_pids]
    return rows


def _extract_cli_flag_values(cmd_line: str, pattern: re.Pattern[str]) -> list[str]:
    results: list[str] = []
    for m in pattern.finditer(cmd_line or ""):
        val = (m.group(1) or m.group(2) or m.group(3) or "").strip()
        if val:
            results.append(val)
    return results


def _collect_candidate_log_files(
    log_dirs: list[Path] | None = None,
    limit: int = 80,
) -> list[Path]:
    files: list[Path] = []
    if log_dirs is not None:
        for d in log_dirs:
            if d.is_dir():
                files.extend(p for p in d.glob("*.log") if p.is_file())
    else:
        if CLI_LOG_DIR.is_dir():
            files.extend(p for p in CLI_LOG_DIR.glob("*.log") if p.is_file())
        if WATCHDOG_ROOT.is_dir():
            top_cli_dir = WATCHDOG_ROOT / "cli_logs"
            if top_cli_dir.is_dir():
                files.extend(p for p in top_cli_dir.glob("*.log") if p.is_file())
            files.extend(p for p in WATCHDOG_ROOT.glob("*/cli_logs/*.log") if p.is_file())

    def _safe_mtime(p: Path) -> float:
        try:
            return p.stat().st_mtime
        except OSError:
            return 0.0

    files.sort(key=_safe_mtime, reverse=True)
    return files[:limit]


def _parse_cli_log(log_path: Path) -> dict[str, Any]:
    """解析 cli-*.log / --log-file 日志，提取语言服务器 PID、启动目录、最新会话 ID 及正常退出标志。"""
    result: dict[str, Any] = {
        "ls_pid": 0,
        "launch_workspace": "",
        "conversation_id": "",
        "clean_exit": False,
    }
    if not log_path.is_file():
        return result
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return result

    for line in lines[:30]:
        m = _LS_PID_RE.search(line)
        if m:
            result["ls_pid"] = _safe_int(m.group(1), 0)
            break

    for line in lines:
        if not result["launch_workspace"]:
            mw = _INIT_WS_RE.search(line)
            if mw:
                result["launch_workspace"] = mw.group(1).strip()
        mc = _CONV_LOG_RE.search(line)
        if mc:
            result["conversation_id"] = mc.group(1).lower()

    for line in lines[-40:]:
        if "CLI program exited, shutting down" in line:
            result["clean_exit"] = True
            break

    return result


def _find_log_for_pids(
    candidate_pids: list[int],
    creation_ts: float = 0.0,
    log_files_cache: list[tuple[Path, dict[str, Any]]] | None = None,
    claimed_logs: set[str] | None = None,
) -> tuple[Path | None, dict[str, Any]]:
    pid_set = {p for p in candidate_pids if p > 0}
    entries = log_files_cache or []
    claimed = claimed_logs if claimed_logs is not None else set()

    if pid_set:
        for lf, parsed in entries:
            if parsed.get("ls_pid") in pid_set:
                return lf, parsed

    if creation_ts > 0:
        best_lf: Path | None = None
        best_parsed: dict[str, Any] = {}
        best_diff = 999.0
        for lf, parsed in entries:
            if str(lf) in claimed:
                continue
            m = _CLI_LOG_NAME_RE.match(lf.name)
            if not m:
                continue
            try:
                log_ts = datetime.strptime(f"{m.group(1)}_{m.group(2)}", "%Y%m%d_%H%M%S").timestamp()
            except ValueError:
                continue
            diff = abs(log_ts - creation_ts)
            if diff <= 4.0 and diff < best_diff:
                best_diff = diff
                best_lf = lf
                best_parsed = parsed
        if best_lf is not None:
            return best_lf, best_parsed

    return None, {}


def _read_transcript_details(
    conv_id: str,
    brain_root: Path | None = None,
) -> dict[str, Any]:
    """读取主会话 transcript.jsonl（含截断回退 transcript_full.jsonl）。"""
    root = brain_root if brain_root is not None else BRAIN_ROOT
    empty = {
        "exists": False,
        "transcript_path": "",
        "rows": [],
        "user_requests": [],
        "real_user_requests": [],
        "total_steps": 0,
        "last_step_at": "",
        "last_user_ts": 0.0,
        "last_user_at": "",
        "latest_user_msg": "",
        "recent_tools": [],
        "recent_tool_details": [],
        "referenced_subagents": [],
    }
    if not conv_id:
        return empty
    transcript = root / conv_id / ".system_generated" / "logs" / "transcript.jsonl"
    if not transcript.is_file():
        return empty

    rows = _read_json_lines(transcript)
    if not rows:
        return empty

    full_cache: dict[int, dict[str, Any]] | None = None
    user_requests: list[dict[str, Any]] = []
    subagents: list[str] = []
    recent_actions: list[str] = []
    recent_tool_details: list[str] = []
    last_step_at = ""

    for obj in rows:
        created_at = str(obj.get("created_at") or "")
        if created_at:
            last_step_at = created_at
        src = obj.get("source")
        typ = obj.get("type")
        if src == "USER_EXPLICIT" and typ == "USER_INPUT":
            content = str(obj.get("content") or "")
            if "content" in (obj.get("truncated_fields") or []):
                if full_cache is None:
                    full_rows = _read_json_lines(transcript.with_name("transcript_full.jsonl"))
                    full_cache = {_safe_int(r.get("step_index"), -1): r for r in full_rows}
                full_row = full_cache.get(_safe_int(obj.get("step_index"), -1))
                if full_row and full_row.get("content"):
                    content = str(full_row.get("content"))
            extracted = _extract_user_request_text(content)
            user_requests.append(
                {
                    "step": obj.get("step_index"),
                    "created_at": created_at,
                    "ts": _parse_iso_ts(created_at),
                    "text": extracted,
                    "is_boilerplate": _is_watchdog_boilerplate(extracted),
                }
            )
        elif typ == "PLANNER_RESPONSE":
            for tc in obj.get("tool_calls") or []:
                if not isinstance(tc, dict):
                    continue
                name = str(tc.get("name") or "")
                if name:
                    recent_actions.append(name)
                args = tc.get("args") or {}
                if isinstance(args, dict):
                    if name in ("invoke_subagent", "send_message"):
                        rec = str(args.get("Recipient") or args.get("Role") or "").strip('"')
                        if rec:
                            subagents.append(rec)
                    summary_arg = (
                        args.get("Path")
                        or args.get("ScriptPath")
                        or args.get("Cwd")
                        or args.get("CommandLine")
                        or args.get("Dest")
                        or ""
                    )
                    if name:
                        detail = f"{name}({str(summary_arg)[:140]})" if summary_arg else name
                        recent_tool_details.append(detail)

    real_reqs = [r for r in user_requests if not r["is_boilerplate"]]
    last_user = real_reqs[-1] if real_reqs else (user_requests[-1] if user_requests else None)
    max_step = max((_safe_int(r.get("step_index"), 0) for r in rows), default=0)
    total_steps = max(len(rows), max_step)
    latest_user_msg = real_reqs[-1]["text"] if real_reqs else (last_user["text"] if last_user else "")

    return {
        "exists": True,
        "transcript_path": str(transcript),
        "rows": rows,
        "user_requests": user_requests,
        "real_user_requests": real_reqs,
        "total_steps": total_steps,
        "last_step_at": last_step_at,
        "last_user_ts": float(last_user["ts"]) if last_user else 0.0,
        "last_user_at": str(last_user["created_at"]) if last_user else "",
        "latest_user_msg": latest_user_msg,
        "recent_tools": recent_actions[-12:],
        "recent_tool_details": recent_tool_details[-12:],
        "referenced_subagents": sorted(set(subagents))[-8:],
    }


def _to_native_existing_dir(raw_norm: str) -> str:
    if not raw_norm:
        return ""
    candidate = raw_norm.replace("/", os.sep)
    if len(candidate) >= 2 and candidate[1] == ":":
        candidate = candidate[0].upper() + candidate[1:]
    p = Path(candidate)
    if p.is_dir():
        try:
            return str(p.resolve())
        except OSError:
            return str(p)
    return ""


def _infer_project_dir_from_transcript(
    rows: list[dict[str, Any]],
    real_user_reqs: list[dict[str, Any]],
    launch_workspace: str = "",
) -> str:
    """优先使用启动工作区，再从工具路径推断实际项目目录。"""
    if launch_workspace:
        existing_lw = _to_native_existing_dir(_norm_slash(launch_workspace))
        if existing_lw and _norm_path(existing_lw) != _norm_path(DEFAULT_DESKTOP_DIR):
            return existing_lw

    home_norm = _norm_slash(str(HOME_DIR)).rstrip("/")
    desktop_norm = _norm_slash(str(DEFAULT_DESKTOP_DIR)).rstrip("/")
    ignored_prefixes = (
        "c:/windows",
        "c:/program files",
        f"{home_norm}/.gemini",
        f"{home_norm}/.ai-global-rules",
        f"{home_norm}/appdata",
    )
    scores: Counter[str] = Counter()
    paths: dict[str, str] = {}

    for obj in rows:
        if obj.get("type") != "PLANNER_RESPONSE":
            continue
        for tc in obj.get("tool_calls") or []:
            if not isinstance(tc, dict):
                continue
            args = tc.get("args")
            if not isinstance(args, dict):
                continue
            for key, val in args.items():
                if str(key).lower() not in _PATH_TOOL_ARG_KEYS:
                    continue
                for s in _iter_str_values(val):
                    s_norm = _norm_slash(s)
                    for m in _WIN_PATH_RE.finditer(s_norm):
                        cand = m.group(1).rstrip("/")
                        if any(cand.startswith(pfx) for pfx in ignored_prefixes):
                            continue
                        if cand == desktop_norm:
                            continue
                        p_native = cand.replace("/", os.sep)
                        if len(p_native) >= 2 and p_native[1] == ":":
                            p_native = p_native[0].upper() + p_native[1:]
                        p_obj = Path(p_native)
                        if p_obj.is_file():
                            p_obj = p_obj.parent
                        if p_obj.is_dir():
                            nk = _norm_path(p_obj)
                            scores[nk] += 1
                            paths[nk] = str(p_obj)

    if scores:
        best_k, _ = scores.most_common(1)[0]
        return paths[best_k]

    if launch_workspace:
        existing_lw = _to_native_existing_dir(_norm_slash(launch_workspace))
        return existing_lw or launch_workspace

    for req in real_user_reqs:
        s_norm = _norm_slash(str(req.get("text") or ""))
        for m in _WIN_PATH_RE.finditer(s_norm):
            cand = m.group(1).rstrip("/")
            if any(cand.startswith(pfx) for pfx in ignored_prefixes):
                continue
            existing = _to_native_existing_dir(cand)
            if existing:
                return existing

    return ""


def _check_goal_done(project_dir: str, last_user_ts: float = 0.0) -> bool:
    if not project_dir:
        return False
    done_flag = Path(project_dir) / ".ai-session" / "agy_goal_done.flag"
    if not done_flag.is_file():
        return False
    try:
        done_mtime = done_flag.stat().st_mtime
    except OSError:
        return False
    if last_user_ts > 0 and done_mtime < last_user_ts:
        return False
    return True


def read_git_summary(work_dir: Path) -> dict[str, Any]:
    summary: dict[str, Any] = {"status_lines": [], "head_commits": []}
    if not (work_dir / ".git").exists():
        return summary
    for key, cmd in (
        ("status_lines", ["git", "status", "--short"]),
        ("head_commits", ["git", "log", "-n", "3", "--oneline"]),
    ):
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(work_dir),
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=5,
            )
            if proc.returncode == 0:
                summary[key] = [ln for ln in proc.stdout.splitlines() if ln.strip()][:35]
        except Exception:
            pass
    return summary


def read_handoff_head(work_dir: Path, max_lines: int = 45) -> str:
    p = work_dir / ".ai-session" / "handoff.md"
    if not p.is_file():
        return ""
    lines = p.read_text(encoding="utf-8", errors="replace").splitlines()[:max_lines]
    return "\n".join(lines).strip()


def load_state(state_path: Path) -> dict[str, Any]:
    if not state_path.is_file():
        return {"recent_crashes": [], "recovered_crash_files": {}}
    try:
        data = json.loads(state_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            data.setdefault("recent_crashes", [])
            data.setdefault("recovered_crash_files", {})
            return data
    except Exception:
        pass
    return {"recent_crashes": [], "recovered_crash_files": {}}


def poll_windows(
    state_file: Path = DEFAULT_MULTI_STATE_FILE,
    brain_root: Path | None = None,
    crash_root: Path | None = None,
    log_dirs: list[Path] | None = None,
    process_name: str = DEFAULT_PROCESS_NAME,
    watch_pids: set[int] | None = None,
) -> dict[str, Any]:
    """扫描当前存活的 Antigravity 窗口及最近 30 分钟内尚未恢复的非空崩溃日志。"""
    b_root = brain_root if brain_root is not None else BRAIN_ROOT
    c_root = crash_root if crash_root is not None else CRASH_ROOT
    procs = _query_live_agy_processes(process_name=process_name, watch_pids=watch_pids)
    proc_by_pid: dict[int, dict[str, Any]] = {}
    for p in procs:
        pid = _safe_int(p.get("ProcessId"), 0)
        if pid > 0:
            proc_by_pid[pid] = p

    tui_procs = [
        p for pid, p in proc_by_pid.items()
        if _safe_int(p.get("ParentProcessId"), 0) not in proc_by_pid
    ]
    children_by_parent: dict[int, list[dict[str, Any]]] = {}
    for pid, p in proc_by_pid.items():
        ppid = _safe_int(p.get("ParentProcessId"), 0)
        if ppid in proc_by_pid:
            children_by_parent.setdefault(ppid, []).append(p)

    candidate_logs = _collect_candidate_log_files(log_dirs=log_dirs, limit=80)
    log_cache: list[tuple[Path, dict[str, Any]]] = [
        (lf, _parse_cli_log(lf)) for lf in candidate_logs
    ]

    windows: list[dict[str, Any]] = []
    active_convs: set[str] = set()
    claimed_logs: set[str] = set()
    live_pids = set(proc_by_pid.keys())

    for tp in sorted(tui_procs, key=lambda x: _safe_int(x.get("ProcessId"), 0)):
        tui_pid = _safe_int(tp.get("ProcessId"), 0)
        cmd_line = str(tp.get("CommandLine") or "")
        creation_ts = _parse_wmi_creation_ts(tp.get("CreationDate"))
        kids = children_by_parent.get(tui_pid, [])
        if kids:
            kids_sorted = sorted(
                kids, key=lambda k: _parse_wmi_creation_ts(k.get("CreationDate")), reverse=True
            )
            ls_pid = _safe_int(kids_sorted[0].get("ProcessId"), tui_pid)
        else:
            ls_pid = tui_pid

        explicit_logs = _extract_cli_flag_values(cmd_line, _LOGFILE_ARG_RE)
        matched_log: Path | None = None
        parsed_log: dict[str, Any] = {}
        if explicit_logs:
            exp_p = Path(explicit_logs[0])
            matched_log = exp_p
            if exp_p.is_file():
                parsed_log = _parse_cli_log(exp_p)
        if matched_log is None or not parsed_log.get("conversation_id"):
            found_log, found_parsed = _find_log_for_pids(
                [ls_pid, tui_pid],
                creation_ts=creation_ts,
                log_files_cache=log_cache,
                claimed_logs=claimed_logs,
            )
            if found_log is not None:
                matched_log = found_log
                parsed_log = found_parsed

        if matched_log is not None:
            claimed_logs.add(str(matched_log))

        cmd_convs = _extract_cli_flag_values(cmd_line, _CONV_ARG_RE)
        conv_id = str(parsed_log.get("conversation_id") or (cmd_convs[-1] if cmd_convs else "")).strip()
        if conv_id:
            active_convs.add(conv_id)

        cmd_add_dirs = _extract_cli_flag_values(cmd_line, _ADD_DIR_ARG_RE)
        launch_ws = str(parsed_log.get("launch_workspace") or "").strip()
        if not launch_ws and cmd_add_dirs:
            non_desktop = [d for d in cmd_add_dirs if _norm_path(d) != _norm_path(DEFAULT_DESKTOP_DIR)]
            launch_ws = non_desktop[0] if non_desktop else cmd_add_dirs[0]

        td = _read_transcript_details(conv_id, brain_root=b_root) if conv_id else {"exists": False}
        if td.get("exists"):
            proj_dir = _infer_project_dir_from_transcript(
                td["rows"], td["real_user_requests"], launch_workspace=launch_ws
            )
            total_steps = int(td["total_steps"])
            latest_user_msg = _sanitize_one_line(str(td["latest_user_msg"] or ""), 200)
            last_user_ts = float(td["last_user_ts"])
        else:
            proj_dir = launch_ws
            total_steps = 0
            latest_user_msg = ""
            last_user_ts = 0.0

        proj_label = Path(proj_dir).name if proj_dir else (Path(launch_ws).name if launch_ws else "unknown")
        goal_done = _check_goal_done(proj_dir, last_user_ts=last_user_ts)

        windows.append(
            {
                "tui_pid": tui_pid,
                "ls_pid": ls_pid,
                "creation_ts": creation_ts,
                "command_line": cmd_line,
                "add_dirs": cmd_add_dirs,
                "log_file": str(matched_log) if matched_log is not None else "",
                "conversation_id": conv_id,
                "launch_workspace": launch_ws,
                "project_dir": proj_dir,
                "project_label": proj_label,
                "total_steps": total_steps,
                "latest_user_msg": latest_user_msg,
                "last_user_ts": last_user_ts,
                "goal_done": goal_done,
                "clean_exit": bool(parsed_log.get("clean_exit", False)),
            }
        )

    now_ts = time.time()
    state = load_state(state_file)
    recovered_files = state.get("recovered_crash_files") or {}
    unrecovered: list[dict[str, Any]] = []
    seen_crash_convs: set[str] = set()

    if c_root.is_dir():
        crash_candidates: list[tuple[float, Path, int]] = []
        for cf in c_root.glob("crash_*.log"):
            if not cf.is_file():
                continue
            m = _CRASH_FILE_RE.match(cf.name)
            if not m:
                continue
            try:
                st = cf.stat()
            except OSError:
                continue
            if st.st_size <= 0 or (now_ts - st.st_mtime) > 1800.0:
                continue
            crash_pid = _safe_int(m.group(1), 0)
            if crash_pid <= 0 or crash_pid in live_pids:
                continue
            if cf.name in recovered_files:
                continue
            crash_candidates.append((st.st_mtime, cf, crash_pid))

        crash_candidates.sort(key=lambda item: item[0], reverse=True)
        for crash_mtime, cf, crash_pid in crash_candidates:
            found_log, parsed_log = _find_log_for_pids(
                [crash_pid], log_files_cache=log_cache
            )
            conv_id = str(parsed_log.get("conversation_id") or "").strip()
            if not conv_id or conv_id in active_convs or conv_id in seen_crash_convs:
                continue
            launch_ws = str(parsed_log.get("launch_workspace") or "").strip()
            td = _read_transcript_details(conv_id, brain_root=b_root)
            if td.get("exists"):
                proj_dir = _infer_project_dir_from_transcript(
                    td["rows"], td["real_user_requests"], launch_workspace=launch_ws
                )
                total_steps = int(td["total_steps"])
                latest_user_msg = _sanitize_one_line(str(td["latest_user_msg"] or ""), 200)
                last_user_ts = float(td["last_user_ts"])
            else:
                proj_dir = launch_ws
                total_steps = 0
                latest_user_msg = ""
                last_user_ts = 0.0

            if _check_goal_done(proj_dir, last_user_ts=last_user_ts):
                continue

            seen_crash_convs.add(conv_id)
            proj_label = Path(proj_dir).name if proj_dir else (Path(launch_ws).name if launch_ws else "unknown")
            unrecovered.append(
                {
                    "crash_file": cf.name,
                    "crash_pid": crash_pid,
                    "crash_mtime": crash_mtime,
                    "log_file": str(found_log) if found_log is not None else "",
                    "conversation_id": conv_id,
                    "launch_workspace": launch_ws,
                    "project_dir": proj_dir,
                    "project_label": proj_label,
                    "total_steps": total_steps,
                    "latest_user_msg": latest_user_msg,
                }
            )

    return {"windows": windows, "unrecovered_crashes": unrecovered}


def inspect_exited_window(
    tui_pid: int = 0,
    ls_pid: int = 0,
    log_file: str = "",
    exit_code: int | None = None,
    fallback_conv_id: str = "",
    fallback_project_dir: str = "",
    fallback_launch_workspace: str = "",
    brain_root: Path | None = None,
    crash_root: Path | None = None,
    log_dirs: list[Path] | None = None,
) -> dict[str, Any]:
    """结合退出码、cli-*.log、非空 crash_*.log 与完成标记，精准判断窗口是否真实闪退。"""
    b_root = brain_root if brain_root is not None else BRAIN_ROOT
    c_root = crash_root if crash_root is not None else CRASH_ROOT

    parsed_log: dict[str, Any] = {}
    used_log_path: Path | None = Path(log_file) if log_file else None
    if used_log_path is not None and used_log_path.is_file():
        parsed_log = _parse_cli_log(used_log_path)
    elif tui_pid > 0 or ls_pid > 0:
        cand_logs = _collect_candidate_log_files(log_dirs=log_dirs, limit=60)
        log_cache = [(lf, _parse_cli_log(lf)) for lf in cand_logs]
        found_lf, found_parsed = _find_log_for_pids(
            [p for p in (ls_pid, tui_pid) if p > 0], log_files_cache=log_cache
        )
        if found_lf is not None:
            used_log_path = found_lf
            parsed_log = found_parsed

    conv_id = str(parsed_log.get("conversation_id") or fallback_conv_id or "").strip()
    launch_ws = str(parsed_log.get("launch_workspace") or fallback_launch_workspace or "").strip()
    clean_exit = bool(parsed_log.get("clean_exit", False))

    target_pids = {p for p in (tui_pid, ls_pid) if p > 0}
    crash_files: list[str] = []
    if c_root.is_dir() and target_pids:
        for pid in sorted(target_pids):
            for cf in sorted(c_root.glob(f"crash_{pid}_*.log")):
                try:
                    if cf.is_file() and cf.stat().st_size > 0:
                        crash_files.append(cf.name)
                except OSError:
                    continue
    has_crash_dump = len(crash_files) > 0

    td = _read_transcript_details(conv_id, brain_root=b_root) if conv_id else {"exists": False}
    if td.get("exists"):
        proj_dir = _infer_project_dir_from_transcript(
            td["rows"], td["real_user_requests"], launch_workspace=launch_ws or fallback_project_dir
        )
        total_steps = int(td["total_steps"])
        last_user_ts = float(td["last_user_ts"])
    else:
        proj_dir = fallback_project_dir or launch_ws
        total_steps = 0
        last_user_ts = 0.0

    proj_label = Path(proj_dir).name if proj_dir else (Path(launch_ws).name if launch_ws else "unknown")
    goal_done = _check_goal_done(proj_dir, last_user_ts=last_user_ts)

    if has_crash_dump:
        is_crash = True
        reason = f"检测到非空崩溃日志 ({', '.join(crash_files)})"
    elif clean_exit:
        is_crash = False
        reason = "日志包含正常退出标记 (CLI program exited, shutting down)"
    elif exit_code in _MANUAL_CLOSE_CODES:
        is_crash = False
        reason = f"手动关闭终端窗口或 Ctrl+C (ExitCode={exit_code}，无崩溃日志)"
    elif exit_code == 0:
        is_crash = False
        reason = "进程正常退出 (ExitCode=0，无崩溃日志)"
    elif exit_code is not None:
        is_crash = True
        reason = f"进程异常退出且缺少正常退出日志 (ExitCode={exit_code})"
    else:
        is_crash = True
        reason = "进程退出码未知且日志缺少正常退出标记"

    return {
        "is_crash": is_crash,
        "clean_exit": clean_exit,
        "has_crash_dump": has_crash_dump,
        "crash_files": crash_files,
        "goal_done": goal_done,
        "conversation_id": conv_id,
        "project_dir": proj_dir,
        "project_label": proj_label,
        "launch_workspace": launch_ws,
        "log_file": str(used_log_path) if used_log_path is not None else "",
        "total_steps": total_steps,
        "reason": reason,
    }


def build_recovery_payload(
    conversation_id: str,
    project_dir: str = "",
    launch_workspace: str = "",
    record_crash: bool = False,
    crash_file: str = "",
    force_fresh: bool = False,
    custom_instruction: str = "",
    state_file: Path = DEFAULT_MULTI_STATE_FILE,
    dry_run: bool = False,
    brain_root: Path | None = None,
    watchdog_root: Path | None = None,
) -> dict[str, Any]:
    """为单个闪退对话构建隔离的上下文快照、续接策略及恢复提示词。"""
    b_root = brain_root if brain_root is not None else BRAIN_ROOT
    w_root = watchdog_root if watchdog_root is not None else WATCHDOG_ROOT
    conv_id = conversation_id.strip()
    td = _read_transcript_details(conv_id, brain_root=b_root) if conv_id else {"exists": False}

    resolved_proj = project_dir.strip()
    if not resolved_proj and td.get("exists"):
        resolved_proj = _infer_project_dir_from_transcript(
            td["rows"], td["real_user_requests"], launch_workspace=launch_workspace
        )
    if not resolved_proj:
        resolved_proj = launch_workspace.strip()

    proj_path = Path(resolved_proj) if resolved_proj else None
    proj_label = proj_path.name if proj_path and proj_path.name else (Path(launch_workspace).name if launch_workspace else "workspace")

    now_ts = time.time()
    state = load_state(state_file)
    recent_crashes = [
        c for c in state.get("recent_crashes", [])
        if isinstance(c, dict) and (now_ts - float(c.get("ts", 0))) <= 180.0
    ]
    if record_crash and conv_id:
        recent_crashes.append({"conv_id": conv_id, "ts": now_ts})
    state["recent_crashes"] = recent_crashes

    recovered_files = state.get("recovered_crash_files") or {}
    if crash_file:
        recovered_files[crash_file] = now_ts
    state["recovered_crash_files"] = recovered_files

    recent_conv_crash_count = sum(
        1 for c in recent_crashes if conv_id and c.get("conv_id") == conv_id
    )

    total_steps = int(td["total_steps"]) if td.get("exists") else 0
    real_reqs = list(td["real_user_requests"])[-8:] if td.get("exists") else []
    recent_tool_details = list(td["recent_tool_details"])[-12:] if td.get("exists") else []
    latest_user_msg = str(td["latest_user_msg"] or "") if td.get("exists") else ""
    transcript_path = str(td["transcript_path"] or "") if td.get("exists") else ""

    cli_custom = custom_instruction.strip()
    git_info = read_git_summary(proj_path) if proj_path and proj_path.is_dir() else {"status_lines": [], "head_commits": []}
    handoff_head = read_handoff_head(proj_path) if proj_path and proj_path.is_dir() else ""

    short_id = conv_id[:8] if conv_id else "fresh"
    snapshot_path = w_root / "snapshots" / f"上下文_{short_id}.md"
    snapshot_path.parent.mkdir(parents=True, exist_ok=True)

    snap_lines: list[str] = [
        f"# AGY 看门狗自动恢复上下文快照（生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}）",
        "",
        f"- 原对话 ID：`{conv_id or '无'}`",
        f"- 原对话记录：`{transcript_path or '无'}`",
        f"- 目标工作区：`{resolved_proj or launch_workspace or '未知'}`",
        f"- 原对话总步数：{total_steps}（近 180s 崩溃次数：{recent_conv_crash_count}）",
        "",
        "## 1. 用户补充指令",
    ]
    if cli_custom:
        snap_lines.append(f"- **看门狗本次附加指令**：{cli_custom}")
    else:
        snap_lines.append("- （无额外手写补充；以原对话最近真实要求为准）")

    snap_lines.extend(["", "## 2. 最近真实用户原话（最多 8 条，按时间从旧到新）"])
    if real_reqs:
        for idx, req in enumerate(real_reqs, 1):
            snap_lines.append(f"  {idx}. [{req['created_at']}] {req['text']}")
    else:
        snap_lines.append("- （未提取到历史真实用户消息）")

    snap_lines.extend(["", "## 3. 闪退前最后 12 次工具调用 / 触及路径"])
    if recent_tool_details:
        for td_line in recent_tool_details:
            snap_lines.append(f"- `{td_line}`")
    else:
        snap_lines.append("- （无记录）")

    snap_lines.extend(["", "## 4. 工作区 Git 与 Handoff 状态"])
    snap_lines.append("- Git 最近提交：")
    for c in git_info["head_commits"] or ["（无）"]:
        snap_lines.append(f"  - `{c}`")
    snap_lines.append("- Git 未提交改动：")
    if git_info["status_lines"]:
        for s in git_info["status_lines"]:
            snap_lines.append(f"  - `{s}`")
    else:
        snap_lines.append("  - （工作区干净或非 Git 仓库）")
    if handoff_head:
        snap_lines.extend(["", "### `.ai-session/handoff.md` 顶部状态", "```markdown", handoff_head, "```"])

    snapshot_path.write_text("\n".join(snap_lines) + "\n", encoding="utf-8")

    if not dry_run:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state["last_generated_at"] = now_ts
        state["last_conv_id"] = conv_id
        state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")

    if not force_fresh and conv_id and total_steps < 800 and recent_conv_crash_count <= 1:
        resume_mode = "conversation"
        resume_reason = f"原会话步数适中 ({total_steps} < 800) 且未反复崩溃，直接 --conversation 续接原对话"
    else:
        resume_mode = "fresh"
        resume_reason = (
            "强制新开零步数窗口" if force_fresh else
            f"原会话在 180s 内连续崩溃 {recent_conv_crash_count} 次，切换零步数新窗口防连环崩溃" if recent_conv_crash_count >= 2 else
            f"原会话步数较高 ({total_steps} >= 800)，自动切换零步数新窗口规避闪退" if total_steps >= 800 else
            "缺少原对话 ID，开启新窗口"
        )

    add_dirs: list[str] = []
    seen_dirs: set[str] = set()

    def _add_dir_once(d: str) -> None:
        if not d:
            return
        nd = _norm_path(d)
        if nd and nd not in seen_dirs and Path(d).is_dir():
            seen_dirs.add(nd)
            add_dirs.append(d)

    _add_dir_once(resolved_proj)
    if launch_workspace and _norm_path(launch_workspace) != _norm_path(DEFAULT_DESKTOP_DIR):
        _add_dir_once(launch_workspace)
    if not add_dirs and launch_workspace:
        _add_dir_once(launch_workspace)

    slug = _workspace_slug(resolved_proj or launch_workspace or short_id)
    log_file_suggestion = str(w_root / slug / "cli_logs" / f"agy_recover_{short_id}_{int(now_ts)}.log")

    global_claude = GLOBAL_RULES_ROOT / "CLAUDE.md"
    rules_hint = f"{global_claude}" if global_claude.is_file() else "全局规则 CLAUDE.md"
    work_display = resolved_proj or launch_workspace or "当前工作区"
    msg_part = _sanitize_one_line(latest_user_msg, 260) if latest_user_msg else "继续完成闪退前任务"
    extra_part = f" 用户附加要求：{_sanitize_one_line(cli_custom, 220)}。" if cli_custom else ""
    t_hint = f"（需要更早细节可读取原对话记录末尾 {transcript_path}）" if transcript_path else ""
    raw_prompt = (
        f"[AGY看门狗自动恢复] 原对话 {conv_id}（工作目录：{work_display}）刚刚发生闪退，"
        f"看门狗已按对话自动重开可视化窗口恢复。请先读取 {snapshot_path} 确认闪退前的完整上下文、"
        f"用户最近要求与修改过的文件{t_hint}，遵守 {rules_hint} 与工作区规则（如有 CLAUDE.md / AGENTS.md / .ai-session/handoff.md）。"
        f"{extra_part}用户最近原话：{msg_part}。请继续执行闪退前未完成的任务！"
    )
    interactive_prompt = _sanitize_one_line(raw_prompt, 1150)

    return {
        "conversation_id": conv_id,
        "project_dir": resolved_proj,
        "project_label": proj_label,
        "launch_workspace": launch_workspace,
        "snapshot_path": str(snapshot_path),
        "log_file_suggestion": log_file_suggestion,
        "add_dirs": add_dirs,
        "resume_mode": resume_mode,
        "resume_reason": resume_reason,
        "total_steps": total_steps,
        "recent_conv_crash_count": recent_conv_crash_count,
        "latest_user_msg": _sanitize_one_line(latest_user_msg, 200),
        "interactive_prompt": interactive_prompt,
    }


# ---------------------------------------------------------------------------
# Win32 Mutex, Proxy Helpers, Window Runner & Multi-Window Daemon
# ---------------------------------------------------------------------------

def _get_kernel32() -> Any:
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    if os.name == "nt":
        k32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
        k32.CreateMutexW.restype = wintypes.HANDLE
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.CloseHandle.restype = wintypes.BOOL
        k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k32.WaitForSingleObject.restype = wintypes.DWORD
        k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        k32.GetExitCodeProcess.restype = wintypes.BOOL
        k32.SetConsoleTitleW.argtypes = [wintypes.LPCWSTR]
        k32.SetConsoleTitleW.restype = wintypes.BOOL
    return k32


def acquire_single_instance_mutex(mutex_name: str = DEFAULT_MUTEX_NAME) -> tuple[Any, bool]:
    """创建或检测 Windows 命名互斥锁，返回 (handle, already_exists)。"""
    if os.name != "nt":  # pragma: no cover
        return None, False
    k32 = _get_kernel32()
    handle = k32.CreateMutexW(None, False, mutex_name)
    err = ctypes.get_last_error()
    already_exists = err == 183  # ERROR_ALREADY_EXISTS
    if already_exists:
        if handle:
            k32.CloseHandle(handle)
        return None, True
    return handle, False


def is_single_instance_held(mutex_name: str = DEFAULT_MUTEX_NAME) -> bool:
    """探测全局看门狗互斥锁是否已被持有（不长期占用锁）。"""
    handle, already_exists = acquire_single_instance_mutex(mutex_name)
    if already_exists:
        return True
    release_single_instance_mutex(handle)
    return False


def release_single_instance_mutex(handle: Any) -> None:
    if os.name == "nt" and handle:
        try:
            _get_kernel32().CloseHandle(handle)
        except Exception:
            pass


def open_process_handle(pid: int) -> Any:
    if os.name != "nt" or pid <= 0:
        return None
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    SYNCHRONIZE = 0x00100000
    handle = _get_kernel32().OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, False, pid)
    return handle or None


def poll_process_exit(handle: Any) -> tuple[bool, int | None]:
    if os.name != "nt" or not handle:
        return False, None
    k32 = _get_kernel32()
    wait_res = k32.WaitForSingleObject(handle, 0)
    if wait_res != 0:  # WAIT_OBJECT_0
        return False, None
    code = wintypes.DWORD(0)
    if k32.GetExitCodeProcess(handle, ctypes.byref(code)):
        return True, int(code.value)
    return True, None


def close_process_handle(handle: Any) -> None:
    if os.name == "nt" and handle:
        try:
            _get_kernel32().CloseHandle(handle)
        except Exception:
            pass


def _enable_console_utf8_and_vt() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass
    if os.name == "nt":
        try:
            k32 = _get_kernel32()
            for std_id in (-11, -12):
                h = k32.GetStdHandle(std_id)
                mode = wintypes.DWORD(0)
                if h and k32.GetConsoleMode(h, ctypes.byref(mode)):
                    k32.SetConsoleMode(h, mode.value | 0x0004)
        except Exception:
            pass


def _set_console_title(title: str) -> None:
    if os.name == "nt" and title:
        try:
            _get_kernel32().SetConsoleTitleW(title)
        except Exception:
            pass


def _apply_proxy_env(
    proxy_mode: str = "auto",
    proxy_url: str = "",
    no_proxy: str = "",
) -> tuple[str, str, str]:
    """按选定网络模式配置代理环境变量，返回 (resolved_mode, proxy, no_proxy)。"""
    mode = (proxy_mode or os.environ.get("AGY_PROXY_MODE") or "auto").strip().lower()
    if mode not in ("auto", "direct", "custom"):
        mode = "auto"
    if mode == "auto" and os.environ.get("AGY_PROXY_MODE", "").strip().lower() == "direct" and not proxy_url:
        mode = "direct"

    nop = (no_proxy or os.environ.get("NO_PROXY") or DEFAULT_NO_PROXY).strip()

    if mode == "direct":
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "AGY_PROXY_URL"):
            os.environ.pop(key, None)
        os.environ["AGY_PROXY_MODE"] = "direct"
        os.environ["NO_PROXY"] = nop
        os.environ["no_proxy"] = nop
        return "direct", "", nop

    proxy = (proxy_url or os.environ.get("AGY_PROXY_URL") or os.environ.get("HTTP_PROXY") or DEFAULT_PROXY_URL).strip()
    if mode == "custom" and not proxy:
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "AGY_PROXY_URL"):
            os.environ.pop(key, None)
        os.environ["AGY_PROXY_MODE"] = "direct"
        os.environ["NO_PROXY"] = nop
        os.environ["no_proxy"] = nop
        return "direct", "", nop

    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        os.environ[key] = proxy
    os.environ["AGY_PROXY_MODE"] = "custom" if mode == "custom" else "auto"
    os.environ["AGY_PROXY_URL"] = proxy
    os.environ["NO_PROXY"] = nop
    os.environ["no_proxy"] = nop
    return os.environ["AGY_PROXY_MODE"], proxy, nop


def _resolve_agy_exe() -> str:
    found = shutil.which("agy.exe") or shutil.which("agy")
    if found:
        return found
    cand = Path(os.environ.get("LOCALAPPDATA", "")) / "agy" / "bin" / "agy.exe"
    if cand.is_file():
        return str(cand)
    raise FileNotFoundError("未在 PATH 或 %LOCALAPPDATA%\\agy\\bin 中找到 agy.exe")


def _resolve_wt_exe() -> str:
    found = shutil.which("wt.exe")
    if found:
        return found
    alias = Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WindowsApps" / "wt.exe"
    if alias.is_file():
        return str(alias)
    return ""


def _clean_cli_dir_arg(raw_args: list[str]) -> str:
    if not raw_args:
        return ""
    joined = " ".join(a for a in raw_args if a is not None).strip()
    if not joined:
        return ""
    cleaned = joined.strip().strip('"').strip()
    if len(cleaned) > 3:
        cleaned = cleaned.rstrip("\\/")
    elif len(cleaned) == 2 and cleaned[1] == ":":
        cleaned = f"{cleaned}\\"
    p = Path(cleaned)
    if p.is_dir():
        try:
            return str(p.resolve())
        except OSError:
            return str(p)
    return ""


class WatchdogLogger:
    """将守护日志同时输出到控制台与 LOCALAPPDATA\\AGYWatchdog\\agy_watchdog.log。"""

    _COLORS = {
        "cyan": "\033[36m",
        "green": "\033[32m",
        "yellow": "\033[33m",
        "red": "\033[31m",
        "gray": "\033[90m",
        "reset": "\033[0m",
    }

    def __init__(self, log_paths: list[Path] | None = None) -> None:
        if log_paths is not None:
            self.log_paths = log_paths
        else:
            self.log_paths = [WATCHDOG_ROOT / "agy_watchdog.log"]
        for lp in self.log_paths:
            try:
                lp.parent.mkdir(parents=True, exist_ok=True)
            except Exception:
                pass

    def log(self, message: str, color: str = "gray") -> None:
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{ts}] {message}"
        prefix = self._COLORS.get(color, "")
        suffix = self._COLORS["reset"] if prefix else ""
        try:
            print(f"{prefix}{line}{suffix}", flush=True)
        except Exception:
            print(line, flush=True)
        for lp in self.log_paths:
            try:
                with lp.open("a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
            except Exception:
                pass


def _write_runner_status(
    status_file: Path | None,
    state: str,
    runner_pid: int,
    agy_pid: int,
    exit_code: int | None,
    error_text: str = "",
) -> None:
    if status_file is None:
        return
    try:
        status_file.parent.mkdir(parents=True, exist_ok=True)
        obj = {
            "state": state,
            "runner_pid": runner_pid,
            "agy_pid": agy_pid,
            "exit_code": exit_code,
            "error": error_text,
            "updated_at": datetime.now().isoformat(),
        }
        status_file.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass


def run_window_from_ticket(ticket_path: Path) -> int:
    """在新 Windows Terminal 窗口内原生交互运行 agy.exe。"""
    _enable_console_utf8_and_vt()
    if not ticket_path.is_file():
        print(f"[错误] 找不到启动票据：{ticket_path}", file=sys.stderr)
        return 1

    ticket = json.loads(ticket_path.read_text(encoding="utf-8"))
    project_dir = str(ticket.get("project_dir") or "")
    launch_ws = str(ticket.get("launch_workspace") or "")
    work_dir = str(ticket.get("work_dir") or "")
    project_label = str(ticket.get("project_label") or "")
    window_title = str(ticket.get("window_title") or "")
    agy_exe = str(ticket.get("agy_exe") or _resolve_agy_exe())
    args_list = [str(x) for x in (ticket.get("agy_args") or [])]
    round_no = _safe_int(ticket.get("round"), 1)
    resume_reason = str(ticket.get("resume_reason") or "")
    agy_log_file = str(ticket.get("agy_log_file") or "")
    conversation_id = str(ticket.get("conversation_id") or "")
    status_raw = str(ticket.get("status_file") or "")
    status_file = Path(status_raw) if status_raw else None

    _, proxy, nop = _apply_proxy_env(
        str(ticket.get("proxy_mode") or "auto"),
        str(ticket.get("proxy_url") or ""),
        str(ticket.get("no_proxy") or ""),
    )

    launch_dir = ""
    for cand in (project_dir, launch_ws, work_dir):
        if cand and Path(cand).is_dir():
            launch_dir = cand
            break
    if launch_dir:
        os.chdir(launch_dir)

    if not project_label:
        project_label = Path(launch_dir).name if launch_dir else "workspace"
    if not window_title:
        window_title = f"Antigravity [{project_label}] - 看门狗守护"
    _set_console_title(window_title)

    has_log_flag = any(a == "--log-file" or a.startswith("--log-file=") for a in args_list)
    final_args: list[str] = []
    if agy_log_file and not has_log_flag:
        Path(agy_log_file).parent.mkdir(parents=True, exist_ok=True)
        final_args.extend(["--log-file", agy_log_file])
    final_args.extend(args_list)

    print("============================================================")
    print(f"  [AGY 独立窗口 | {project_label} | 第 {round_no} 轮] {resume_reason or '交互运行'}")
    if conversation_id:
        print(f"  恢复对话：{conversation_id}")
    if launch_dir:
        print(f"  工作目录：{launch_dir}")
    if agy_log_file:
        print(f"  独立日志：{agy_log_file}")
    print(f"  网络模式：{proxy if proxy else '直连'} (NO_PROXY={nop})")
    print("  提示：本窗口可一直打字对话、随时插话调整或输入 /compact")
    print("============================================================")
    print("", flush=True)

    runner_pid = os.getpid()
    _write_runner_status(status_file, "running", runner_pid, 0, None)

    exit_code = 1
    agy_pid = 0
    err_msg = ""
    try:
        proc = subprocess.Popen([agy_exe, *final_args], cwd=launch_dir or None)
        agy_pid = int(proc.pid)
        _write_runner_status(status_file, "running", runner_pid, agy_pid, None)
        exit_code = int(proc.wait())
    except Exception as exc:
        err_msg = str(exc)
        print(f"[AGY 启动失败] {err_msg}", file=sys.stderr)
        exit_code = 1
    finally:
        _write_runner_status(status_file, "exited", runner_pid, agy_pid, exit_code, err_msg)

    if exit_code != 0:
        print("")
        print(f"[看门狗] 检测到异常退出 (ExitCode={exit_code})，2 秒后自动关闭本旧窗并由看门狗重开恢复...", flush=True)
        time.sleep(2)
    return exit_code


def spawn_wt_agy_window(
    project_dir: str,
    launch_workspace: str,
    project_label: str,
    agy_args: list[str],
    agy_log_file: str,
    resume_reason: str = "",
    conversation_id: str = "",
    round_no: int = 1,
    window_title: str = "",
    proxy_mode: str = "auto",
    proxy_url: str = "",
    logger: WatchdogLogger | None = None,
) -> dict[str, int]:
    """在独立 Windows Terminal 标签页中非阻塞拉起 AGY 交互窗口并返回 PID 信息。"""
    agy_exe = _resolve_agy_exe()
    wt_exe = _resolve_wt_exe()
    resolved_mode, proxy, nop = _apply_proxy_env(proxy_mode=proxy_mode, proxy_url=proxy_url)

    launch_cwd = ""
    for cand in (project_dir, launch_workspace, str(DEFAULT_DESKTOP_DIR), str(HOME_DIR)):
        if cand and Path(cand).is_dir():
            launch_cwd = cand
            break

    if not project_label:
        project_label = Path(launch_cwd).name if launch_cwd else "workspace"
    if not window_title:
        window_title = f"Antigravity [{project_label}] - 看门狗守护"

    WATCHDOG_ROOT.mkdir(parents=True, exist_ok=True)
    run_tag = f"{os.getpid()}-{round_no}-{int(time.time() * 1000)}"
    ticket_file = WATCHDOG_ROOT / f"ticket_{run_tag}.json"
    status_file = WATCHDOG_ROOT / f"status_{run_tag}.json"

    ticket = {
        "round": round_no,
        "work_dir": launch_cwd,
        "project_dir": project_dir,
        "launch_workspace": launch_workspace,
        "project_label": project_label,
        "window_title": window_title,
        "agy_exe": agy_exe,
        "agy_args": agy_args,
        "resume_reason": resume_reason,
        "status_file": str(status_file),
        "agy_log_file": agy_log_file,
        "conversation_id": conversation_id,
        "proxy_mode": resolved_mode,
        "proxy_url": proxy,
        "no_proxy": nop,
    }
    ticket_file.write_text(json.dumps(ticket, ensure_ascii=False, indent=2), encoding="utf-8")

    py_exe = sys.executable
    self_script = str(Path(__file__).resolve())
    runner_cmd = [
        py_exe,
        "-X",
        "utf8",
        self_script,
        "--mode",
        "run-window",
        "--ticket",
        str(ticket_file),
    ]

    if wt_exe:
        if logger:
            logger.log(f"使用 Windows Terminal 弹出窗口 [{project_label}]...", "cyan")
        wt_cmd = [wt_exe, "-w", "-1", "--title", window_title, "-d", launch_cwd, *runner_cmd]
        subprocess.Popen(wt_cmd, cwd=launch_cwd)
    else:
        if logger:
            logger.log(f"未找到 wt.exe，使用独立控制台弹出窗口 [{project_label}]...", "yellow")
        flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
        subprocess.Popen(runner_cmd, cwd=launch_cwd, creationflags=flags)

    runner_pid = 0
    agy_pid = 0
    deadline = time.time() + 6.0
    while time.time() < deadline:
        if status_file.is_file():
            try:
                st = json.loads(status_file.read_text(encoding="utf-8"))
                runner_pid = _safe_int(st.get("runner_pid"), 0)
                agy_pid = _safe_int(st.get("agy_pid"), 0)
                if runner_pid > 0 and agy_pid > 0:
                    break
            except Exception:
                pass
        time.sleep(0.15)

    if runner_pid > 0:
        try:
            ticket_file.unlink(missing_ok=True)
        except Exception:
            pass
    if agy_pid > 0:
        try:
            status_file.unlink(missing_ok=True)
        except Exception:
            pass

    return {"runner_pid": runner_pid, "agy_pid": agy_pid}


def launch_new_window_for_dir(
    target_dir: Path,
    logger: WatchdogLogger | None = None,
    round_no: int = 1,
    proxy_mode: str = "auto",
    proxy_url: str = "",
) -> dict[str, int]:
    """为任意项目目录打开一个新的独立 AGY Windows Terminal 窗口。"""
    resolved = str(target_dir.resolve())
    label = target_dir.name or "workspace"
    slug = _workspace_slug(resolved)
    log_dir = WATCHDOG_ROOT / "cli_logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = str(log_dir / f"agy_launch_{slug}_{int(time.time())}_{os.getpid()}.log")
    agy_args = ["--add-dir", resolved]
    return spawn_wt_agy_window(
        project_dir=resolved,
        launch_workspace=resolved,
        project_label=label,
        agy_args=agy_args,
        agy_log_file=log_file,
        resume_reason=f"新开独立项目窗口 ({label})",
        round_no=round_no,
        window_title=f"Antigravity [{label}] - 独立窗口",
        proxy_mode=proxy_mode,
        proxy_url=proxy_url,
        logger=logger,
    )


def _prompt_project_folder() -> Path | None:
    print("")
    print("请输入要新开独立 Antigravity 窗口的项目目录路径：")
    print(f"  直接输入 [D] 打开桌面 ({DEFAULT_DESKTOP_DIR})；直接回车取消")
    try:
        choice = input("> ").strip()
    except EOFError:
        return None
    if not choice:
        return None
    if choice.upper() == "D" and DEFAULT_DESKTOP_DIR.is_dir():
        return DEFAULT_DESKTOP_DIR.resolve()
    cand = Path(choice.strip().strip('"'))
    if cand.is_dir():
        return cand.resolve()
    print(f"[错误] 目录不存在：{cand}")
    return None


def _wait_key_timeout(timeout_seconds: int) -> str:
    if timeout_seconds <= 0 or msvcrt is None:
        return ""
    try:
        if not sys.stdin or not sys.stdin.isatty():
            return ""
    except Exception:
        return ""
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if msvcrt.kbhit():
            ch = msvcrt.getwch()
            if ch in ("\x00", "\xe0"):
                if msvcrt.kbhit():
                    _ = msvcrt.getwch()
                continue
            return ch.upper()
        time.sleep(0.1)
    return ""


def _read_single_key_nonblocking() -> str:
    if msvcrt is None:
        return ""
    try:
        if not sys.stdin or not sys.stdin.isatty():
            return ""
    except Exception:
        return ""
    if msvcrt.kbhit():
        ch = msvcrt.getwch()
        if ch in ("\x00", "\xe0"):
            if msvcrt.kbhit():
                _ = msvcrt.getwch()
            return ""
        return ch.upper()
    return ""


def _print_tracked_table(tracked: dict[int, dict[str, Any]]) -> None:
    print("")
    print(f"=== 当前受守护窗口汇总（共 {len(tracked)} 个）===")
    if not tracked:
        print("  （当前暂无运行中的 agy.exe 窗口，持续等待新窗口接入...）")
    else:
        for tpid in sorted(tracked.keys()):
            e = tracked[tpid]
            cid = str(e.get("conversation_id") or "")
            c_short = cid[:8] if cid else "未绑定"
            msg = str(e.get("latest_user_msg") or "")
            print(
                f"  - PID={tpid} (LS={e.get('ls_pid')}) | 对话={c_short} | 步数={e.get('total_steps', 0)} "
                f"| 项目={e.get('project_label')} ({e.get('project_dir')}) | 最近={msg[:60]}"
            )
    print("============================================", flush=True)


def run_quick_launcher(
    target_dir: str = "",
    proxy_mode: str = "auto",
    proxy_url: str = "",
) -> int:
    """看门狗已在后台运行时，作为快速多开窗口启动器执行并退出。"""
    _enable_console_utf8_and_vt()
    _apply_proxy_env(proxy_mode=proxy_mode, proxy_url=proxy_url)
    _set_console_title("AGY 快速新开独立窗口")

    print("============================================================")
    print("  检测到 AGY 全局看门狗已在守护运行（单例），进入【快速新开窗口】模式")
    print("  说明：新开窗口后看门狗将在 2 秒内自动纳入多对话守护")
    print("============================================================")

    chosen: Path | None = None
    if target_dir and Path(target_dir).is_dir():
        chosen = Path(target_dir).resolve()
    else:
        chosen = _prompt_project_folder()

    if chosen is None:
        print("已取消开窗。")
        return 0

    res = launch_new_window_for_dir(chosen, proxy_mode=proxy_mode, proxy_url=proxy_url)
    print(
        f"已在新 Windows Terminal 打开独立 AGY 窗口：{chosen} "
        f"(AgyPID={res.get('agy_pid', 0)}, RunnerPID={res.get('runner_pid', 0)})"
    )
    time.sleep(1.5)
    return 0


def _find_matching_target_pids(
    process_name: str = DEFAULT_PROCESS_NAME,
    launcher_pid: int = 0,
    watch_pids: set[int] | None = None,
) -> tuple[list[int], bool]:
    """返回 (匹配到的存活目标 PID 列表, launcher_pid 是否仍存活)。"""
    target_lower = (process_name or DEFAULT_PROCESS_NAME).lower()
    procs = _query_all_processes_snapshot()
    by_pid: dict[int, dict[str, Any]] = {}
    for p in procs:
        pid = _safe_int(p.get("ProcessId"), 0)
        if pid > 0:
            by_pid[pid] = p

    launcher_alive = launcher_pid <= 0 or (launcher_pid in by_pid)

    def _has_ancestor(pid: int, ancestor_pid: int) -> bool:
        if ancestor_pid <= 0:
            return True
        cur = pid
        seen: set[int] = set()
        while cur > 0 and cur not in seen:
            seen.add(cur)
            row = by_pid.get(cur)
            if not row:
                return False
            ppid = _safe_int(row.get("ParentProcessId"), 0)
            if ppid == ancestor_pid:
                return True
            cur = ppid
        return False

    matched: list[int] = []
    for pid, row in by_pid.items():
        if watch_pids is not None and pid not in watch_pids:
            continue
        name = str(row.get("Name") or "").lower()
        if name != target_lower:
            continue
        if launcher_pid > 0 and not _has_ancestor(pid, launcher_pid):
            continue
        matched.append(pid)

    return sorted(matched), launcher_alive


def ensure_daemon(
    launcher_pid: int = 0,
    wait_seconds: float = 15.0,
    proxy_mode: str = "auto",
    proxy_url: str = "",
    mutex_name: str = DEFAULT_MUTEX_NAME,
    process_name: str = DEFAULT_PROCESS_NAME,
    watch_pids: set[int] | None = None,
    no_wt: bool = False,
    dry_run: bool = False,
) -> int:
    """确认 Antigravity 正常拉起后，以单例形式打开可见终端运行看门狗守护。"""
    if is_single_instance_held(mutex_name):
        return 0

    deadline = time.time() + max(0.5, wait_seconds)
    confirmed = False
    while time.time() < deadline:
        matched, launcher_alive = _find_matching_target_pids(
            process_name=process_name,
            launcher_pid=launcher_pid,
            watch_pids=watch_pids,
        )
        if matched:
            time.sleep(0.6)
            matched_after, _ = _find_matching_target_pids(
                process_name=process_name,
                launcher_pid=launcher_pid,
                watch_pids=watch_pids,
            )
            if matched_after:
                confirmed = True
                break
        if launcher_pid > 0 and not launcher_alive:
            return 0
        time.sleep(0.25)

    if not confirmed:
        return 0

    if is_single_instance_held(mutex_name):
        return 0

    resolved_mode, resolved_proxy, _ = _apply_proxy_env(proxy_mode=proxy_mode, proxy_url=proxy_url)
    self_script = str(Path(__file__).resolve())
    daemon_cmd = [
        sys.executable,
        "-X",
        "utf8",
        self_script,
        "--mode",
        "daemon",
        "--auto-start",
        "--proxy-mode",
        resolved_mode,
    ]
    if resolved_proxy:
        daemon_cmd.extend(["--proxy-url", resolved_proxy])
    if mutex_name != DEFAULT_MUTEX_NAME:
        daemon_cmd.extend(["--mutex-name", mutex_name])
    if process_name != DEFAULT_PROCESS_NAME:
        daemon_cmd.extend(["--process-name", process_name])
    if watch_pids:
        for wp in sorted(watch_pids):
            daemon_cmd.extend(["--watch-pid", str(wp)])

    if dry_run:
        print(json.dumps({"would_spawn": daemon_cmd, "mutex": mutex_name}, ensure_ascii=False))
        return 0

    wt_exe = "" if no_wt else _resolve_wt_exe()
    launch_cwd = str(HOME_DIR) if HOME_DIR.is_dir() else str(Path(__file__).resolve().parent)
    if wt_exe:
        wt_cmd = [
            wt_exe,
            "-w",
            "-1",
            "--title",
            "AGY 看门狗守护终端",
            "-d",
            launch_cwd,
            *daemon_cmd,
        ]
        subprocess.Popen(wt_cmd, cwd=launch_cwd)
    else:
        flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
        subprocess.Popen(daemon_cmd, cwd=launch_cwd, creationflags=flags)
    return 0


def run_daemon(
    target_dir: str = "",
    force_fresh: bool = False,
    max_rapid_crashes: int = 3,
    rapid_window_seconds: int = 60,
    max_restarts: int = 50,
    prompt_timeout_seconds: int = 5,
    state_file: Path = DEFAULT_MULTI_STATE_FILE,
    mutex_handle: Any = None,
    mutex_name: str = DEFAULT_MUTEX_NAME,
    process_name: str = DEFAULT_PROCESS_NAME,
    proxy_mode: str = "auto",
    proxy_url: str = "",
    auto_start: bool = False,
    auto_exit_when_empty: bool = True,
    poll_interval_seconds: float = 2.0,
    startup_grace_seconds: float = 15.0,
    recovery_grace_seconds: float = 20.0,
    watch_pids: set[int] | None = None,
    logger: WatchdogLogger | None = None,
) -> int:
    """全局多窗口、多对话自动防闪退看门狗守护主循环（全部正常关闭后自动退出）。"""
    _enable_console_utf8_and_vt()
    resolved_mode, proxy, _ = _apply_proxy_env(proxy_mode=proxy_mode, proxy_url=proxy_url)
    _set_console_title("AGY 看门狗守护终端（全窗口单例守护中）")

    WATCHDOG_ROOT.mkdir(parents=True, exist_ok=True)
    pid_file = WATCHDOG_ROOT / "agy_watchdog.pid"
    my_pid = os.getpid()
    if watch_pids is None:
        try:
            pid_file.write_text(str(my_pid), encoding="ascii")
        except Exception:
            pass

    if logger is None:
        logger = WatchdogLogger()
    watch_start_ts = time.time()
    net_desc = proxy if proxy else "直连"
    logger.log(
        f"=== AGY 单例看门狗已启动 (WatchdogPID={my_pid}, 网络={net_desc}, 模式={resolved_mode}, Mutex={mutex_name}) ===",
        "cyan",
    )

    tracked: dict[int, dict[str, Any]] = {}
    crash_history: dict[str, list[float]] = {}
    launch_round = 0
    total_recoveries = 0
    recovery_grace_until = 0.0
    startup_grace_until = watch_start_ts + max(0.5, startup_grace_seconds)

    def _recover_conversation(
        conv_id: str,
        project_dir: str = "",
        launch_workspace: str = "",
        record_crash: bool = False,
        crash_file: str = "",
    ) -> None:
        nonlocal launch_round, total_recoveries, recovery_grace_until
        launch_round += 1
        total_recoveries += 1
        recovery_grace_until = max(recovery_grace_until, time.time() + recovery_grace_seconds)
        rec = build_recovery_payload(
            conversation_id=conv_id,
            project_dir=project_dir,
            launch_workspace=launch_workspace,
            record_crash=record_crash,
            crash_file=crash_file,
            force_fresh=force_fresh,
            state_file=state_file,
        )
        agy_args: list[str] = []
        for d in rec["add_dirs"]:
            agy_args.extend(["--add-dir", str(d)])
        if not agy_args:
            fallback_d = rec["project_dir"] or rec["launch_workspace"] or str(DEFAULT_DESKTOP_DIR)
            if Path(fallback_d).is_dir():
                agy_args.extend(["--add-dir", fallback_d])
        agy_args.append("--dangerously-skip-permissions")
        if rec["resume_mode"] == "conversation" and rec["conversation_id"]:
            agy_args.extend(["--conversation", rec["conversation_id"]])
        agy_args.extend(["-i", rec["interactive_prompt"]])

        logger.log(
            f"准备恢复对话 {rec['conversation_id'][:8] if rec['conversation_id'] else 'new'} "
            f"[{rec['project_label']}] | 策略={rec['resume_mode']}: {rec['resume_reason']}",
            "green",
        )
        if rec["latest_user_msg"]:
            logger.log(f"带入最近原话：{rec['latest_user_msg']}", "gray")

        res = spawn_wt_agy_window(
            project_dir=rec["project_dir"],
            launch_workspace=rec["launch_workspace"],
            project_label=rec["project_label"],
            agy_args=agy_args,
            agy_log_file=rec["log_file_suggestion"],
            resume_reason=rec["resume_reason"],
            conversation_id=rec["conversation_id"],
            round_no=launch_round,
            proxy_mode=resolved_mode,
            proxy_url=proxy,
            logger=logger,
        )
        logger.log(
            f"[已拉起恢复窗口] 项目={rec['project_label']} | 对话={rec['conversation_id'][:8] if rec['conversation_id'] else 'new'} "
            f"| AgyPID={res['agy_pid']} | RunnerPID={res['runner_pid']}",
            "green",
        )

    def _sync_windows(initial: bool = False) -> dict[str, Any]:
        poll = poll_windows(
            state_file=state_file,
            process_name=process_name,
            watch_pids=watch_pids,
        )
        for w in poll.get("windows", []):
            tpid = _safe_int(w.get("tui_pid"), 0)
            if tpid <= 0:
                continue
            ls_pid = _safe_int(w.get("ls_pid"), tpid)
            conv_id = str(w.get("conversation_id") or "")
            conv_short = conv_id[:8] if conv_id else "未绑定"
            proj_label = str(w.get("project_label") or "unknown")
            proj_dir = str(w.get("project_dir") or "")

            if tpid in tracked:
                entry = tracked[tpid]
                old_conv = str(entry.get("conversation_id") or "")
                if conv_id and old_conv and old_conv != conv_id:
                    logger.log(
                        f"[切换会话] 窗口 PID={tpid} 切换至对话 {conv_short} ({proj_label}, 步数={w.get('total_steps', 0)})",
                        "cyan",
                    )
                elif not old_conv and conv_id:
                    logger.log(
                        f"[绑定会话] 窗口 PID={tpid} 识别到对话 {conv_short} ({proj_label}, 步数={w.get('total_steps', 0)})",
                        "cyan",
                    )
                entry["ls_pid"] = ls_pid
                if w.get("log_file"):
                    entry["log_file"] = w["log_file"]
                if conv_id:
                    entry["conversation_id"] = conv_id
                if proj_dir:
                    entry["project_dir"] = proj_dir
                if proj_label:
                    entry["project_label"] = proj_label
                if w.get("launch_workspace"):
                    entry["launch_workspace"] = w["launch_workspace"]
                entry["total_steps"] = _safe_int(w.get("total_steps"), 0)
                entry["latest_user_msg"] = str(w.get("latest_user_msg") or "")
            else:
                handle = open_process_handle(tpid)
                if handle is not None:
                    exited, _ = poll_process_exit(handle)
                    if exited:
                        close_process_handle(handle)
                        continue
                    tracked[tpid] = {
                        "tui_pid": tpid,
                        "ls_pid": ls_pid,
                        "handle": handle,
                        "log_file": str(w.get("log_file") or ""),
                        "conversation_id": conv_id,
                        "project_dir": proj_dir,
                        "project_label": proj_label,
                        "launch_workspace": str(w.get("launch_workspace") or ""),
                        "total_steps": _safe_int(w.get("total_steps"), 0),
                        "latest_user_msg": str(w.get("latest_user_msg") or ""),
                    }
                    tag = "[发现已有窗口]" if initial else "[纳入新开窗口]"
                    logger.log(
                        f"{tag} PID={tpid} | LS={ls_pid} | 对话={conv_short} | 步数={w.get('total_steps', 0)} | 项目={proj_label} ({proj_dir})",
                        "green",
                    )
        return poll

    try:
        init_poll = _sync_windows(initial=True)
        ever_tracked_window = len(tracked) > 0

        if target_dir and Path(target_dir).is_dir():
            target_norm = _norm_path(target_dir)
            already_open = any(
                _norm_path(w.get("project_dir") or "") == target_norm
                or _norm_path(w.get("launch_workspace") or "") == target_norm
                or any(_norm_path(d) == target_norm for d in (w.get("add_dirs") or []))
                for w in init_poll.get("windows", [])
            )
            if not already_open:
                launch_round += 1
                logger.log(f"检测到传入目录 {target_dir} 暂无运行中窗口，立即打开独立 AGY 窗口...", "cyan")
                launch_new_window_for_dir(
                    Path(target_dir),
                    logger=logger,
                    round_no=launch_round,
                    proxy_mode=resolved_mode,
                    proxy_url=proxy,
                )
                recovery_grace_until = max(recovery_grace_until, time.time() + recovery_grace_seconds)

        if not auto_start and watch_pids is None:
            now_ts = time.time()
            recent_unrecovered = [
                uc for uc in init_poll.get("unrecovered_crashes", [])
                if (now_ts - float(uc.get("crash_mtime", 0))) <= 600.0
            ]
            if recent_unrecovered:
                logger.log(f"检测到 {len(recent_unrecovered)} 个最近 10 分钟内尚未恢复的崩溃对话：", "yellow")
                for uc in recent_unrecovered:
                    cid = str(uc.get("conversation_id") or "")
                    logger.log(
                        f"  - 对话 {cid[:8]} | 项目={uc.get('project_label')} ({uc.get('project_dir')}) | 崩溃日志={uc.get('crash_file')}",
                        "yellow",
                    )
                if tracked:
                    print(f"\n【启动选项】{prompt_timeout_seconds} 秒内按 [R] 立即恢复以上闪退对话，按其他键或等 {prompt_timeout_seconds} 秒跳过直接守护...", flush=True)
                    ch = _wait_key_timeout(prompt_timeout_seconds)
                    if ch in ("R", "Y"):
                        for uc in recent_unrecovered:
                            _recover_conversation(
                                conv_id=str(uc.get("conversation_id") or ""),
                                project_dir=str(uc.get("project_dir") or ""),
                                launch_workspace=str(uc.get("launch_workspace") or ""),
                                crash_file=str(uc.get("crash_file") or ""),
                            )
                    else:
                        logger.log(f"跳过启动前历史崩溃，持续守护当前运行中的 {len(tracked)} 个窗口。", "cyan")
                else:
                    print(f"\n【启动选项】当前无运行中窗口，{prompt_timeout_seconds} 秒后自动恢复上述闪退对话（按 [S] 跳过并进入守护）...", flush=True)
                    ch = _wait_key_timeout(prompt_timeout_seconds)
                    if ch != "S":
                        for uc in recent_unrecovered:
                            _recover_conversation(
                                conv_id=str(uc.get("conversation_id") or ""),
                                project_dir=str(uc.get("project_dir") or ""),
                                launch_workspace=str(uc.get("launch_workspace") or ""),
                                crash_file=str(uc.get("crash_file") or ""),
                            )

        logger.log(
            f"进入全窗口实时守护循环（每 {poll_interval_seconds:g} 秒巡检；闪退仅按原对话恢复；全部窗口正常关闭后自动退出）。",
            "cyan",
        )
        print("操作快捷键：[N] 新开独立项目窗口 | [S] 查看当前守护窗口 | [Q] 退出看门狗", flush=True)
        last_prune_ts = time.time()
        sleep_slices = max(1, int(round(poll_interval_seconds / 0.2)))
        slice_sec = poll_interval_seconds / sleep_slices

        while True:
            for _ in range(sleep_slices):
                key = _read_single_key_nonblocking()
                if key == "N":
                    chosen = _prompt_project_folder()
                    if chosen is not None:
                        launch_round += 1
                        res = launch_new_window_for_dir(
                            chosen,
                            logger=logger,
                            round_no=launch_round,
                            proxy_mode=resolved_mode,
                            proxy_url=proxy,
                        )
                        recovery_grace_until = max(recovery_grace_until, time.time() + recovery_grace_seconds)
                        logger.log(f"[手动开窗] 已为 {chosen} 打开新窗口 (AgyPID={res['agy_pid']})", "green")
                elif key == "S":
                    _print_tracked_table(tracked)
                elif key == "Q":
                    logger.log("收到退出快捷键 [Q]，看门狗正常退出。", "cyan")
                    return 0
                time.sleep(slice_sec)

            try:
                exited_list: list[tuple[dict[str, Any], int | None]] = []
                for tpid in list(tracked.keys()):
                    entry = tracked[tpid]
                    exited, exit_code = poll_process_exit(entry.get("handle"))
                    if exited:
                        exited_list.append((entry, exit_code))
                        tracked.pop(tpid, None)

                for entry, exit_code in exited_list:
                    close_process_handle(entry.get("handle"))
                    insp = inspect_exited_window(
                        tui_pid=_safe_int(entry.get("tui_pid"), 0),
                        ls_pid=_safe_int(entry.get("ls_pid"), 0),
                        log_file=str(entry.get("log_file") or ""),
                        exit_code=exit_code,
                        fallback_conv_id=str(entry.get("conversation_id") or ""),
                        fallback_project_dir=str(entry.get("project_dir") or ""),
                        fallback_launch_workspace=str(entry.get("launch_workspace") or ""),
                    )
                    conv_id = str(insp.get("conversation_id") or "")
                    conv_short = conv_id[:8] if conv_id else "unknown"
                    proj_label = str(insp.get("project_label") or "unknown")

                    if insp.get("goal_done"):
                        logger.log(
                            f"[任务完成] 窗口 PID={entry['tui_pid']} | 对话={conv_short} ({proj_label}) 已完成目标标记。",
                            "green",
                        )
                        continue

                    if insp.get("is_crash"):
                        fuse_key = conv_id or f"pid_{entry['tui_pid']}"
                        now_loop = time.time()
                        hist = [ts for ts in crash_history.get(fuse_key, []) if (now_loop - ts) <= rapid_window_seconds]
                        hist.append(now_loop)
                        crash_history[fuse_key] = hist

                        if len(hist) >= max_rapid_crashes:
                            logger.log(
                                f"[熔断保护] 对话 {conv_short} ({proj_label}) 在 {rapid_window_seconds} 秒内连续闪退达到 {max_rapid_crashes} 次，暂停该对话自动恢复（其他窗口不受影响）！",
                                "red",
                            )
                            continue
                        if total_recoveries >= max_restarts:
                            logger.log(f"[上限保护] 本次看门狗累计恢复已达上限 ({max_restarts})，暂停自动拉起。", "red")
                            continue

                        logger.log(
                            f"[闪退检测] 窗口 PID={entry['tui_pid']} | 对话={conv_short} ({proj_label}) 异常退出：{insp.get('reason')}",
                            "yellow",
                        )
                        time.sleep(2.0)
                        _recover_conversation(
                            conv_id=conv_id,
                            project_dir=str(insp.get("project_dir") or ""),
                            launch_workspace=str(insp.get("launch_workspace") or ""),
                            record_crash=True,
                        )
                    else:
                        logger.log(
                            f"[正常关闭] 窗口 PID={entry['tui_pid']} | 对话={conv_short} ({proj_label}) 已正常退出（{insp.get('reason')}），不自动拉起。",
                            "cyan",
                        )

                _sync_windows(initial=False)
                if tracked:
                    ever_tracked_window = True

                now_check = time.time()
                if (
                    auto_exit_when_empty
                    and not tracked
                    and now_check >= recovery_grace_until
                    and (ever_tracked_window or now_check >= startup_grace_until)
                ):
                    live_remaining = _query_live_agy_processes(
                        process_name=process_name,
                        watch_pids=watch_pids,
                    )
                    if not live_remaining:
                        logger.log(
                            "[自动退出] 全部 Antigravity 窗口均已正常关闭，看门狗监听终端正常退出。",
                            "cyan",
                        )
                        return 0

                if time.time() - last_prune_ts >= 120.0:
                    last_prune_ts = time.time()
                    cutoff = time.time() - 300.0
                    for pat in ("ticket_*.json", "status_*.json"):
                        for f in WATCHDOG_ROOT.glob(pat):
                            try:
                                if f.is_file() and f.stat().st_mtime < cutoff:
                                    f.unlink()
                            except Exception:
                                pass
            except Exception as exc:
                logger.log(f"巡检循环异常：{exc}", "red")
    except KeyboardInterrupt:
        logger.log("收到 Ctrl+C 中断信号，看门狗退出。", "cyan")
        return 0
    finally:
        for e in tracked.values():
            close_process_handle(e.get("handle"))
        if watch_pids is None:
            try:
                if pid_file.is_file() and pid_file.read_text(encoding="ascii", errors="ignore").strip() == str(my_pid):
                    pid_file.unlink()
            except Exception:
                pass
        release_single_instance_mutex(mutex_handle)


def handle_entry(
    raw_args: list[str],
    force_fresh: bool = False,
    mutex_name: str = DEFAULT_MUTEX_NAME,
    proxy_mode: str = "auto",
    proxy_url: str = "",
    auto_exit_when_empty: bool = True,
) -> int:
    """统一入口：未运行时启动看门狗守护；已运行时作为快捷开窗器运行。"""
    target_dir = _clean_cli_dir_arg(raw_args)
    handle, already_exists = acquire_single_instance_mutex(mutex_name)
    if already_exists:
        return run_quick_launcher(target_dir=target_dir, proxy_mode=proxy_mode, proxy_url=proxy_url)
    return run_daemon(
        target_dir=target_dir,
        force_fresh=force_fresh,
        mutex_handle=handle,
        mutex_name=mutex_name,
        proxy_mode=proxy_mode,
        proxy_url=proxy_url,
        auto_exit_when_empty=auto_exit_when_empty,
    )


def run_self_test() -> int:
    """隔离自检：验证单实例互斥锁、正常/闪退判定、以及全窗正常关闭后自动退出。"""
    _enable_console_utf8_and_vt()
    unique_mutex = rf"Local\AGY_Watchdog_SelfTest_{os.getpid()}_{int(time.time() * 1000)}"
    h1, exists1 = acquire_single_instance_mutex(unique_mutex)
    if exists1 or not h1:
        print("SELFTEST FAIL: primary mutex acquisition failed", file=sys.stderr)
        return 1
    try:
        h2, exists2 = acquire_single_instance_mutex(unique_mutex)
        if not exists2 or h2 is not None:
            release_single_instance_mutex(h2)
            print("SELFTEST FAIL: singleton mutex allowed duplicate lock", file=sys.stderr)
            return 1
        if not is_single_instance_held(unique_mutex):
            print("SELFTEST FAIL: is_single_instance_held returned False", file=sys.stderr)
            return 1
    finally:
        release_single_instance_mutex(h1)

    if is_single_instance_held(unique_mutex):
        print("SELFTEST FAIL: mutex remained held after release", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="agy_wd_selftest_") as tmp_dir:
        tmp = Path(tmp_dir)
        crash_dir = tmp / "crashes"
        crash_dir.mkdir(parents=True, exist_ok=True)
        log_dir = tmp / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)

        normal_insp = inspect_exited_window(
            tui_pid=999901,
            exit_code=0,
            crash_root=crash_dir,
            log_dirs=[log_dir],
        )
        if normal_insp["is_crash"]:
            print(f"SELFTEST FAIL: exit_code=0 misclassified as crash: {normal_insp}", file=sys.stderr)
            return 1

        ctrl_c_insp = inspect_exited_window(
            tui_pid=999902,
            exit_code=3221225786,
            crash_root=crash_dir,
            log_dirs=[log_dir],
        )
        if ctrl_c_insp["is_crash"]:
            print(f"SELFTEST FAIL: manual close misclassified as crash: {ctrl_c_insp}", file=sys.stderr)
            return 1

        crash_file = crash_dir / "crash_999903_00000000-0000-0000-0000-000000000000.log"
        crash_file.write_text("panic: test crash dump\n", encoding="utf-8")
        crash_insp = inspect_exited_window(
            tui_pid=999903,
            exit_code=1,
            crash_root=crash_dir,
            log_dirs=[log_dir],
        )
        if not crash_insp["is_crash"]:
            print(f"SELFTEST FAIL: crash dump not detected: {crash_insp}", file=sys.stderr)
            return 1

        # 1) Isolated ensure_daemon dry-run against a live child process
        proc_name = Path(sys.executable).name
        probe_proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(10.0)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            if ensure_daemon(
                launcher_pid=os.getpid(),
                wait_seconds=6.0,
                proxy_mode="direct",
                mutex_name=unique_mutex,
                process_name=proc_name,
                watch_pids={int(probe_proc.pid)},
                no_wt=True,
                dry_run=True,
            ) != 0:
                print("SELFTEST FAIL: ensure_daemon dry_run failed", file=sys.stderr)
                return 1
        finally:
            if probe_proc.poll() is None:
                probe_proc.terminate()
                probe_proc.wait(timeout=3)

        # 2) Isolated daemon lifecycle: start -> tracked -> exits cleanly -> daemon auto-exits 0
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(3.5)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            test_logger = WatchdogLogger(log_paths=[tmp / "selftest_daemon.log"])
            daemon_mutex, d_exists = acquire_single_instance_mutex(unique_mutex)
            if d_exists:
                print("SELFTEST FAIL: failed to re-acquire self-test mutex", file=sys.stderr)
                return 1
            rc = run_daemon(
                state_file=tmp / "state.json",
                mutex_handle=daemon_mutex,
                mutex_name=unique_mutex,
                process_name=proc_name,
                proxy_mode="direct",
                auto_start=True,
                auto_exit_when_empty=True,
                poll_interval_seconds=0.4,
                startup_grace_seconds=8.0,
                recovery_grace_seconds=1.0,
                watch_pids={int(proc.pid)},
                logger=test_logger,
            )
            if rc != 0:
                print(f"SELFTEST FAIL: daemon exited with {rc}", file=sys.stderr)
                return 1
            log_text = (tmp / "selftest_daemon.log").read_text(encoding="utf-8", errors="replace")
            if "[发现已有窗口]" not in log_text or "[正常关闭]" not in log_text or "[自动退出]" not in log_text:
                print(f"SELFTEST FAIL: expected lifecycle log markers missing:\n{log_text}", file=sys.stderr)
                return 1
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=3)

    print("SELFTEST PASS: agy_watchdog")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entry", action="store_true", help="统一单实例入口")
    parser.add_argument("--ensure-daemon", action="store_true", help="等待 agy 启动稳定后以单例终端启动看门狗")
    parser.add_argument("--self-test", action="store_true", help="运行隔离自检")
    parser.add_argument(
        "--mode",
        choices=("daemon", "poll-windows", "inspect-exited", "build-recovery", "run-window"),
        default="daemon",
    )
    parser.add_argument("entry_args", nargs="*")
    parser.add_argument("--state-file", default="")
    parser.add_argument("--custom-instruction", default="")
    parser.add_argument("--force-fresh", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--auto-start", action="store_true")
    parser.add_argument("--keep-alive", action="store_true", help="禁用全部窗口关闭后自动退出")
    parser.add_argument("--launcher-pid", type=int, default=0)
    parser.add_argument("--wait-for-agy", type=float, default=15.0)
    parser.add_argument("--proxy-mode", choices=("auto", "direct", "custom"), default="auto")
    parser.add_argument("--proxy-url", default="")
    parser.add_argument("--mutex-name", default=DEFAULT_MUTEX_NAME)
    parser.add_argument("--process-name", default=DEFAULT_PROCESS_NAME)
    parser.add_argument("--watch-pid", type=int, action="append", default=[])
    parser.add_argument("--no-wt", action="store_true")

    # Runner / inspection arguments
    parser.add_argument("--tui-pid", type=int, default=0)
    parser.add_argument("--ls-pid", type=int, default=0)
    parser.add_argument("--log-file", default="")
    parser.add_argument("--exit-code", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--project-dir", default="")
    parser.add_argument("--launch-workspace", default="")
    parser.add_argument("--record-crash", action="store_true")
    parser.add_argument("--crash-file", default="")
    parser.add_argument("--ticket", default="")

    args = parser.parse_args()
    watch_pids = {p for p in args.watch_pid if p > 0} if args.watch_pid else None
    auto_exit = not args.keep_alive

    if args.self_test:
        return run_self_test()

    if args.ensure_daemon:
        return ensure_daemon(
            launcher_pid=args.launcher_pid,
            wait_seconds=args.wait_for_agy,
            proxy_mode=args.proxy_mode,
            proxy_url=args.proxy_url,
            mutex_name=args.mutex_name,
            process_name=args.process_name,
            watch_pids=watch_pids,
            no_wt=args.no_wt,
            dry_run=args.dry_run,
        )

    if args.entry:
        return handle_entry(
            args.entry_args,
            force_fresh=args.force_fresh,
            mutex_name=args.mutex_name,
            proxy_mode=args.proxy_mode,
            proxy_url=args.proxy_url,
            auto_exit_when_empty=auto_exit,
        )

    if args.mode == "daemon":
        target = _clean_cli_dir_arg(args.entry_args)
        handle, already_exists = acquire_single_instance_mutex(args.mutex_name)
        if already_exists:
            if args.auto_start:
                return 0
            return run_quick_launcher(
                target_dir=target,
                proxy_mode=args.proxy_mode,
                proxy_url=args.proxy_url,
            )
        sf = Path(args.state_file) if args.state_file else DEFAULT_MULTI_STATE_FILE
        return run_daemon(
            target_dir=target,
            force_fresh=args.force_fresh,
            state_file=sf,
            mutex_handle=handle,
            mutex_name=args.mutex_name,
            process_name=args.process_name,
            proxy_mode=args.proxy_mode,
            proxy_url=args.proxy_url,
            auto_start=args.auto_start,
            auto_exit_when_empty=auto_exit,
            watch_pids=watch_pids,
        )

    if args.mode == "run-window":
        return run_window_from_ticket(Path(args.ticket))

    if args.mode == "poll-windows":
        sf = Path(args.state_file) if args.state_file else DEFAULT_MULTI_STATE_FILE
        payload = poll_windows(
            state_file=sf,
            process_name=args.process_name,
            watch_pids=watch_pids,
        )
    elif args.mode == "inspect-exited":
        payload = inspect_exited_window(
            tui_pid=args.tui_pid,
            ls_pid=args.ls_pid,
            log_file=args.log_file,
            exit_code=_parse_optional_int(args.exit_code),
            fallback_conv_id=args.conversation_id,
            fallback_project_dir=args.project_dir,
            fallback_launch_workspace=args.launch_workspace,
        )
    elif args.mode == "build-recovery":
        sf = Path(args.state_file) if args.state_file else DEFAULT_MULTI_STATE_FILE
        payload = build_recovery_payload(
            conversation_id=args.conversation_id,
            project_dir=args.project_dir,
            launch_workspace=args.launch_workspace,
            record_crash=args.record_crash,
            crash_file=args.crash_file,
            force_fresh=args.force_fresh,
            custom_instruction=args.custom_instruction,
            state_file=sf,
            dry_run=args.dry_run,
        )
    else:
        payload = {}

    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
