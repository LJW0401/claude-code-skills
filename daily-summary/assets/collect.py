#!/usr/bin/env python3
# 职责：daily-summary 的「数据采集 + 自动归类」固化实现。
#   采集：扫描本机 Claude Code(~/.claude/projects/**.jsonl)与 Codex
#         (~/.codex/state_5.sqlite 索引 → rollout-*.jsonl)的当天会话，按本地
#         时区 09:00–21:00 复盘窗口逐条过滤用户消息 / 助手回复 / 工具与命令信号。
#   归类：按 cwd 把 Claude Code 与 Codex 会话合并成项目分组，算出时段跨度、
#         用户轮数、体量权重(主力/辅助)，挂上 commit/报错/打断等信号。
#   产出：一份紧凑 JSON digest 打到 stdout，供 Claude 据此提炼主题、撰写摘要 /
#         明日计划 / 详细分析。撰写判断不在本脚本职责内。
# 设计：fail-first —— 缺数据源(目录/库不存在)= 该源 0 个会话，显式置 0；其余
#       异常(损坏的库、无法读取)直接抛出，不静默兜底。单行 JSON 解析失败按噪音跳过。
# 依赖：仅 Python 标准库(json / sqlite3 / datetime / os)。
"""用法：
    python3 collect.py [--date YYYY-MM-DD] [--start HH:MM] [--end HH:MM] [--pretty]

不带 --date 时取今天(本地)。输出 JSON 结构见文件末尾 build_digest 的返回值。
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, time as dtime, date as ddate

TEXT_CAP = 220          # 单条消息正文截断长度，控制 digest 体量(token)
PRIMARY_SIZE = 300_000  # 项目体量权重阈值：原始字节
PRIMARY_ROUNDS = 8      # 项目体量权重阈值：用户轮数
AUX_SIZE = 50_000       # 低于此体量且轮数少 → 辅助
SKILL_MARK = "Base directory for this skill:"


# ----- 通用工具 ----------------------------------------------------------

def parse_ts(raw):
    """把 ISO8601(常带 Z)解析为带时区的本地时间；失败返回 None。"""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.astimezone()  # 朴素时间按本地解释
    return dt.astimezone()    # 统一转本地时区


def cap(text):
    text = " ".join(str(text).split())
    return text if len(text) <= TEXT_CAP else text[:TEXT_CAP] + "…"


def hm(dt):
    return dt.strftime("%H:%M")


def detect_signals(text):
    """从一条用户消息正文里识别复盘信号，返回 (signal_list, is_real_prompt)。
    skill/命令注入不算真实提问，但要登记为入口信号。"""
    sigs = []
    stripped = text.strip()
    if stripped.startswith(SKILL_MARK):
        # 形如 "Base directory for this skill: /…/skills/commit\n\n…"
        head = stripped[len(SKILL_MARK):].strip().splitlines()[0].strip()
        sigs.append("skill:" + os.path.basename(head.rstrip("/")))
        return sigs, False
    if "[Request interrupted by user]" in text:
        sigs.append("interrupt")
    if len(stripped) <= 2:
        sigs.append("terse")  # 单字符 / 空回车：半自动模式信号
    for kw in ("Traceback", "Exception", "ERROR", "Error:"):
        if kw in text:
            sigs.append("error:" + cap(stripped.splitlines()[0]))
            break
    for neg in ("不对", "别这样", "停", "删掉", "错了", "撤销", "回退"):
        if neg in text:
            sigs.append("correction")
            break
    return sigs, True


# ----- Claude Code 采集 --------------------------------------------------

def collect_claude(win_start, win_end):
    """扫描 ~/.claude/projects 下窗口内有活动的 jsonl，逐条过滤用户消息。
    返回 session 列表，每个 session 是一个 dict。"""
    root = os.path.expanduser("~/.claude/projects")
    if not os.path.isdir(root):
        return []  # 源不存在 = 0，显式空
    start_epoch = win_start.timestamp()
    sessions = []
    for dirpath, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            st = os.stat(path)
            if st.st_mtime < start_epoch:
                continue  # 窗口起点前就没再动过的文件，跳过(per-msg 仍会兜底过滤)
            sess = _read_claude_file(path, win_start, win_end, st.st_size)
            if sess:
                sessions.append(sess)
    return sessions


def _read_claude_file(path, win_start, win_end, size):
    cwd = branch = None
    msgs, signals = [], []
    with open(path, encoding="utf-8") as fp:
        for line in fp:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") != "user":
                continue
            dt = parse_ts(o.get("timestamp"))
            if dt is None or not (win_start <= dt < win_end):
                continue
            cwd = cwd or o.get("cwd")
            branch = branch or o.get("gitBranch")
            content = o.get("message", {}).get("content", "")
            if isinstance(content, list):
                # tool_result 等结构化内容不是真实提问
                if any(isinstance(p, dict) and p.get("type") == "tool_result" for p in content):
                    continue
                content = next((p.get("text", "") for p in content
                                if isinstance(p, dict) and p.get("type") == "text"), "")
            if not isinstance(content, str) or not content.strip() or content.startswith("<"):
                continue
            sigs, is_prompt = detect_signals(content)
            signals += [f"{s}@{hm(dt)}" for s in sigs]
            if is_prompt:
                msgs.append({"t": hm(dt), "text": cap(content)})
    if not msgs and not signals:
        return None
    return _finish_session("claude-code", path, cwd, branch, msgs, signals, size)


# ----- Codex 采集 --------------------------------------------------------

def collect_codex(win_start, win_end):
    """先查 state_5.sqlite 定位窗口内活跃线程，再读各自 rollout。"""
    db = os.path.expanduser("~/.codex/state_5.sqlite")
    if not os.path.exists(db):
        return []
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    start_epoch = int(win_start.timestamp())
    end_epoch = int(win_end.timestamp())
    rows = con.execute(
        "select rollout_path, cwd, git_branch, title "
        "from threads where updated_at >= ? and updated_at < ? order by updated_at desc",
        (start_epoch, end_epoch),
    ).fetchall()
    con.close()
    sessions = []
    for r in rows:
        path = r["rollout_path"]
        if not path or not os.path.exists(path):
            continue
        sess = _read_codex_file(path, win_start, win_end,
                                r["cwd"], r["git_branch"], r["title"])
        if sess:
            sessions.append(sess)
    return sessions


def _read_codex_file(path, win_start, win_end, cwd, branch, title):
    msgs, signals = [], []
    agent_first = agent_last = None
    calls = commands = failed = 0
    with open(path, encoding="utf-8") as fp:
        for line in fp:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            dt = parse_ts(o.get("timestamp"))
            if dt is None or not (win_start <= dt < win_end):
                continue
            typ = o.get("type")
            p = o.get("payload") or {}
            pt = p.get("type")
            if typ == "event_msg" and pt == "user_message":
                m = str(p.get("message") or "").strip()
                if not m or m.startswith("<"):
                    continue
                sigs, is_prompt = detect_signals(m)
                signals += [f"{s}@{hm(dt)}" for s in sigs]
                if is_prompt:
                    msgs.append({"t": hm(dt), "text": cap(m)})
            elif typ == "event_msg" and pt == "agent_message":
                m = str(p.get("message") or "").strip()
                if m:
                    if agent_first is None:
                        agent_first = cap(m)
                    agent_last = cap(m)
            elif typ == "response_item" and pt == "function_call":
                calls += 1
            elif typ == "event_msg" and pt == "exec_command_end":
                commands += 1
                cmd = str(p.get("command") or "")
                code = p.get("exit_code")
                if code not in (0, None):
                    failed += 1
                    err = (str(p.get("stderr") or "").strip().splitlines() or [""])[0]
                    signals.append(f"cmd-fail@{hm(dt)}:{cap(cmd)} -> {cap(err)}")
                elif any(k in cmd for k in ("git commit", "git push", "gh pr", "release")):
                    signals.append(f"deliver@{hm(dt)}:{cap(cmd)}")
    if not msgs and not signals and agent_last is None:
        return None
    sess = _finish_session("codex", path, cwd, branch, msgs, signals,
                           os.stat(path).st_size)
    sess["title"] = title
    sess["agent_first"] = agent_first
    sess["agent_last"] = agent_last
    sess["tools"] = {"calls": calls, "commands": commands, "failed": failed}
    return sess


# ----- 组装 session / 项目归类 -------------------------------------------

def _finish_session(source, path, cwd, branch, msgs, signals, size):
    times = [m["t"] for m in msgs]
    span = None
    if times:
        s, e = min(times), max(times)
        span = {"start": s, "end": e,
                "minutes": _span_minutes(s, e)}
    return {
        "source": source,
        "file": path,
        "cwd": cwd,
        "branch": branch,
        "rounds": len(msgs),
        "size_kb": round(size / 1024, 1),
        "span": span,
        "user_msgs": msgs,
        "signals": signals,
    }


def _span_minutes(start_hm, end_hm):
    s = datetime.strptime(start_hm, "%H:%M")
    e = datetime.strptime(end_hm, "%H:%M")
    return int((e - s).total_seconds() // 60)


def group_by_cwd(sessions):
    """按 cwd 合并成项目分组，算体量权重。"""
    groups = {}
    for s in sessions:
        key = s.get("cwd") or "unknown"
        groups.setdefault(key, []).append(s)
    projects = []
    for cwd, sess in groups.items():
        rounds = sum(s["rounds"] for s in sess)
        size = sum(s["size_kb"] for s in sess) * 1024
        starts = [s["span"]["start"] for s in sess if s["span"]]
        ends = [s["span"]["end"] for s in sess if s["span"]]
        span = None
        if starts and ends:
            s0, e0 = min(starts), max(ends)
            span = {"start": s0, "end": e0, "minutes": _span_minutes(s0, e0)}
        if size >= PRIMARY_SIZE or rounds >= PRIMARY_ROUNDS:
            weight = "primary"
        elif size < AUX_SIZE and rounds <= 2:
            weight = "aux"
        else:
            weight = "normal"
        projects.append({
            "project": os.path.basename(cwd.rstrip("/")) if cwd != "unknown" else "unknown",
            "cwd": cwd,
            "weight": weight,
            "rounds": rounds,
            "span": span,
            "sessions": sess,
        })
    # 主力在前，再按轮数降序
    order = {"primary": 0, "normal": 1, "aux": 2}
    projects.sort(key=lambda p: (order[p["weight"]], -p["rounds"]))
    return projects


def build_digest(target_date, win_start, win_end):
    cc = collect_claude(win_start, win_end)
    cx = collect_codex(win_start, win_end)
    projects = group_by_cwd(cc + cx)
    return {
        "date": target_date.isoformat(),
        "window": {"start": hm(win_start), "end": hm(win_end)},
        "stats": {
            "claude_code_sessions": len(cc),
            "codex_rollouts": len(cx),
            "projects": len(projects),
        },
        "projects": projects,
    }


def main():
    ap = argparse.ArgumentParser(description="daily-summary 数据采集 + 自动归类")
    ap.add_argument("--date", help="复盘日期 YYYY-MM-DD，默认今天(本地)")
    ap.add_argument("--start", default="09:00", help="复盘窗口起点 HH:MM")
    ap.add_argument("--end", default="21:00", help="复盘窗口终点 HH:MM")
    ap.add_argument("--pretty", action="store_true", help="缩进输出")
    args = ap.parse_args()

    target = (datetime.strptime(args.date, "%Y-%m-%d").date()
              if args.date else datetime.now().astimezone().date())
    local_tz = datetime.now().astimezone().tzinfo
    sh, sm = map(int, args.start.split(":"))
    eh, em = map(int, args.end.split(":"))
    win_start = datetime.combine(target, dtime(sh, sm), tzinfo=local_tz)
    win_end = datetime.combine(target, dtime(eh, em), tzinfo=local_tz)

    digest = build_digest(target, win_start, win_end)
    json.dump(digest, sys.stdout, ensure_ascii=False,
              indent=2 if args.pretty else None)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
