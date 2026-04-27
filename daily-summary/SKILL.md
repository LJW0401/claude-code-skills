---
name: daily-summary
description: 基于当天 Claude Code / Codex 活跃会话生成每日工作总结。扫描 ~/.claude/projects 下的 Claude Code .jsonl，以及 ~/.codex/state_5.sqlite 索引到的 Codex rollout-*.jsonl，从用户消息、助手回复、工具调用和命令结果中还原工作主题，按「主力项目 / 辅助项目 / 跨项目共识」组织成 md 文档。当用户说「总结今天的工作」「根据对话整理日报」「输出每日总结」或类似诉求时使用。
---

# daily-summary

从 Claude Code / Codex 本机会话记录中提炼每日工作总结。

## 数据源

### Claude Code

- **会话文件**：`~/.claude/projects/<项目路径转义>/<session-uuid>.jsonl`
  - 项目路径转义规则：绝对路径中 `/` 替换为 `-`，例如 `/home/penguin/Desktop/feishu` → `-home-penguin-Desktop-feishu`
  - 每行一条 JSON，`type=user` 的条目含用户消息；`message.content` 可能是字符串也可能是数组（取 `type=text` 的 `text` 字段）
- **用户消息元数据**（每条 `type=user` 都带）：
  - `timestamp`：ISO 8601 UTC（如 `2026-04-16T07:14:00.747Z`），可解析为本地时区还原时间线
  - `cwd`：工作目录，比目录名更精确地标识项目
  - `sessionId` / `gitBranch` / `permissionMode` / `version` / `promptId`

### Codex

- **线程索引**：`~/.codex/state_5.sqlite`
  - `threads` 表中重点读取 `id` / `title` / `cwd` / `rollout_path` / `created_at` / `updated_at`
  - 先按 `updated_at` 定位当天活跃线程，再读取对应 `rollout_path`
  - 如果本机没有 `sqlite3` 命令，可用 Python 标准库 `sqlite3` 读取
- **完整会话文件**：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
  - 旧会话可能在 `~/.codex/archived_sessions/rollout-*.jsonl`
  - 每行一条 JSON，顶层通常包含 `timestamp` / `type` / `payload`
  - `type=session_meta`：会话元信息，含 `cwd` / git / 模型等
  - `type=event_msg` 且 `payload.type=user_message`：用户消息，正文在 `payload.message`
  - `type=event_msg` 且 `payload.type=agent_message`：Codex 发给用户的可见回复，正文在 `payload.message`
  - `type=response_item` 且 `payload.type=function_call`：工具调用，含 `name` / `arguments` / `call_id`
  - `type=event_msg` 且 `payload.type=exec_command_end`：命令执行结果，含 `command` / `cwd` / `stdout` / `stderr` / `exit_code`
  - `type=response_item` 且 `payload.type=function_call_output`：工具调用输出，可用于和 `call_id` 对齐
- **用户输入历史**：`~/.codex/history.jsonl`
  - 只含 `session_id` / `ts` / `text`，适合补充用户问题索引
  - 不含助手回复和工具输出，不能单独作为工作总结主数据源
- **当前日期**：取 `currentDate` 上下文，没有则用 `date +%F`
- **日期边界**：日报按本地时区的自然日统计。Claude Code / Codex 的 `timestamp` 多为 UTC，抽取消息时要转成本地时区后再过滤，避免把凌晨或跨日会话归错日期

## 流程

### 第一步：定位当天活跃会话

Claude Code：

```bash
find ~/.claude/projects -name "*.jsonl" -newermt "YYYY-MM-DD 00:00" -printf "%T+ %s %p\n" | sort -r
```

Codex：

```python
import os, sqlite3, datetime
db = os.path.expanduser("~/.codex/state_5.sqlite")
con = sqlite3.connect(db)
con.row_factory = sqlite3.Row
start = int(datetime.datetime.fromisoformat("YYYY-MM-DDT00:00:00").timestamp())
end = start + 86400
for r in con.execute("""
    select id, title, cwd, rollout_path,
           datetime(created_at, 'unixepoch') as created,
           datetime(updated_at, 'unixepoch') as updated
    from threads
    where updated_at >= ? and updated_at < ?
    order by updated_at desc
""", (start, end)):
    print(dict(r))
```

按最后修改时间 + 文件大小初步判断权重：**大文件（≥几 MB）或消息条数多的，通常是当天主力项目**；KB 级的零散会话归入辅助或忽略。

### 第二步：抽取消息流

#### Claude Code 用户消息

对每个 Claude Code 会话文件跑以下 Python 片段，拉出首尾若干条真实用户提问（跳过以 `<` 开头的 system-reminder、skill 注入和 tool_result）：

```python
import json
with open(path) as fp:
    users = []
    for line in fp:
        try: o = json.loads(line)
        except: continue
        if o.get('type') != 'user': continue
        c = o.get('message', {}).get('content', '')
        if isinstance(c, list):
            c = next((p.get('text','') for p in c if isinstance(p,dict) and p.get('type')=='text'), '')
        if isinstance(c, str) and c.strip() and not c.startswith('<') and 'tool_result' not in c[:20]:
            users.append(c.strip())
# 打印 len(users)、前 8 条、后 4 条
```

#### Codex 用户消息、助手回复与工具信号

对每个 Codex `rollout-*.jsonl` 抽取完整消息流。Codex 工作总结不能只看用户输入，还应结合助手回复、工具调用和命令结果判断实际完成了什么：

```python
import json
from datetime import datetime, timezone

events = []
with open(path) as fp:
    for line in fp:
        try:
            o = json.loads(line)
        except Exception:
            continue
        ts = o.get("timestamp")
        typ = o.get("type")
        p = o.get("payload", {})

        if typ == "session_meta":
            events.append((ts, "meta", {
                "cwd": p.get("cwd"),
                "git": p.get("git"),
                "model": p.get("model"),
            }))
        elif typ == "event_msg" and p.get("type") == "user_message":
            msg = (p.get("message") or "").strip()
            if msg and not msg.startswith("<"):
                events.append((ts, "user", msg))
        elif typ == "event_msg" and p.get("type") == "agent_message":
            msg = (p.get("message") or "").strip()
            if msg:
                events.append((ts, "assistant", msg))
        elif typ == "response_item" and p.get("type") == "function_call":
            events.append((ts, "tool_call", {
                "name": p.get("name"),
                "arguments": p.get("arguments"),
                "call_id": p.get("call_id"),
            }))
        elif typ == "event_msg" and p.get("type") == "exec_command_end":
            events.append((ts, "command", {
                "command": p.get("command"),
                "cwd": p.get("cwd"),
                "exit_code": p.get("exit_code"),
                "stdout": (p.get("stdout") or "")[:1000],
                "stderr": (p.get("stderr") or "")[:1000],
            }))

# 打印 user / assistant 首尾消息、失败命令、commit/PR/release 等工具节点
```

Codex 事件分析重点：

- **用户消息**：还原需求、纠正、追加要求和收尾确认
- **助手可见回复**：判断 Codex 向用户承诺了什么、最终交付说明是什么
- **工具调用**：识别读文件、改文件、跑测试、启动服务、创建图片、调用子 agent 等动作
- **命令结果**：识别测试是否通过、commit hash、git status 是否干净、失败命令和报错
- **session_meta / turn_context**：用 `cwd` / git 分支 / 模型 / sandbox / approval mode 辅助归类，不把系统指令当成工作内容
- **response_item.reasoning**：通常只作为内部推理或加密内容信号，默认不要写入总结

- **开头消息**反映主题立项；**结尾消息**反映当天收尾状态；中间的 skill 注入（以 `Base directory for this skill:` 开头）可用于识别调用了 commit / release / pr / merge 等节点，作为「交付节奏」信号。
- **为详细分析抽取完整消息流**：仅靠首尾消息不足以写出有信息量的复盘。应保留每条用户消息的 `(timestamp, 前 200 字)`，另外额外捕获以下信号：
  - `[Request interrupted by user]` → 用户打断点
  - 一个字符的消息（如 `a`、`2`、空回车）→ 半自动模式信号
  - 包含 `Traceback` / `ERROR` / `Exception` 的消息 → 报错点，贴首行异常
  - 用户粘贴的错误堆栈或命令输出 → 单独标记，不要误当成"用户提问"
  - 中文短否定词（「不对」「别」「停」「删掉」「错了」）→ 纠正点
- **利用 timestamp**：抽消息时一并带上 `timestamp`，转成本地时区（`datetime.fromisoformat(ts.replace('Z','+00:00')).astimezone()`），可用于：
  - 识别「今天几点到几点在做 X」的时间块
  - 过滤掉跨日会话里昨天的部分（只保留 `timestamp` 落在目标日期的条目）
  - 统计每个项目的投入时长（首条 → 末条 user 消息间的时间跨度）
  - 观察项目切换节奏（按 timestamp 排序所有项目的 user 消息，看上下文切换频率）

### 第三步：按项目归类并识别主题

- 每个项目一段：主题（在做什么） + 关键动作（发版 / 合并 / 立项 / 调研） + 结尾状态
- Claude Code 和 Codex 会话应按 `cwd` 合并到同一个项目下，避免同一项目被拆成两段；若 `cwd` 相同但主题明显不同，可在项目内分「任务线」
- Codex 会话的「实际产出」优先从工具和命令结果确认：文件修改、测试结果、commit hash、PR/release 操作、服务地址、生成文件路径等；不要只根据助手回复推断已完成
- 留意**跨项目共识**：相同数据格式、相同架构方向、相同技术选型在多个会话里反复出现的结论 —— 这些值得单独提一段
- 小会话（几十 KB 以下、几轮交互）合并到「辅助侧」一段带过

### 第四步：输出 md（双层结构）

文档分**两部分**：顶部为可直接复制提交的摘要，底部为供本人复盘的详细分析。用明确的分割线或二级标题隔开。

```markdown
# 每日工作总结 — YYYY-MM-DD

## 摘要（可提交）

- **项目A**：做了什么（关键动作 1）；做了什么（关键动作 2）
- **项目B**：做了什么
- **项目C**：做了什么
- **环境 / 零散**：杂项 1、杂项 2、杂项 3
- **跨项目共识**：一句话结论（可选）

---

## 详细工作分析（本人复盘用）

### 项目A
- **时段**：HH:MM–HH:MM（跨度 ~Xh，N 轮用户输入；如有大段空白需注明「中间有 Xh idle」）
- **入口 skill**：以哪个 skill 启动（quick-feature / requirements-discuss / bug-fix / pr / release…），这条能看出项目处在什么阶段
- **起手问题**：引用首条用户消息原文（一两句），反映当天是「接着昨天做」还是「新立项」
- **推进主线**：按时间顺序 3-6 条，每条引用一句用户原话 + 一句你推断的意图；重点标注方向切换点（如「从 X 改为 Y 因为 Z」）
- **关键决策 / 取舍**：具体的技术选型、参数命名、接口形状；把被用户否决的方案也写进来
- **被打断 / 被纠正**：如果会话里出现 `[Request interrupted by user]` 或用户说「不对」「别这样」「停」，单列出来 —— 这些是最有复盘价值的信号
- **异常与报错**：遇到的 Traceback、hook 阻塞、工具失败，贴关键行
- **交付节点**：按时间列出 commit / PR / merge / release skill 的触发点
- **收尾状态**：末条用户消息原文；当前是已完成、已合并、还在 WIP、还是卡住
- **明日可跟进**：具体到函数/文件/PR号，而不是「继续做」

### 项目B
（同上结构）

### 跨项目观察
- **时间线还原**：把所有项目的用户消息按 timestamp 混合排序，列出 10-15 个关键节点，看出切换节奏（如「9:00 做 A → 11:00 切到 B → 11:30 被环境问题打断 → 12:00 切回 A」）
- **投入时长排序**：按 `末条 timestamp - 首条 timestamp` 排序所有项目，注意标注「期间有 Xh idle」以区分真实工作时长和跨度
- **上下文切换成本**：数一下每个项目被打断、换到别的项目又回来的次数；频繁切换的项目通常是被动响应而非计划推进
- **反复出现的技术共识**：同一结论在多个项目里浮现（如统一数据格式、统一 API 形状）
- **被搁置 / 未闭环**：有哪些问题今天问了但没给出结论、哪些 PR 没合、哪些报错没修
- **用户情绪信号**（可选）：大量 `a` / 空回车 / `继续` / 一个字符的消息往往表示在等工具结果或已进入半自动模式；密集的打断或否定表示今天方向调整多
```

- **摘要部分**：按项目分类的**无序列表**，一个项目一条 bullet，项目名加粗后跟冒号、再写当天做的事；不含时间戳/轮数/投入时长等统计；环境类/零散会话合并到「环境 / 零散」一条；跨项目共识可作为最后一条单独列出。目标是直接粘贴到日报里
- **详细部分**：每个项目的条目都应**引用原始用户消息**（加引号），而不只是概括；信息密度越高越好，宁可啰嗦也不要空话。重点放在：
  - 用户原话 vs 实际产出的差异（暴露沟通/执行偏差）
  - Codex 可见回复 vs 工具实际结果的差异（例如回复说完成，但测试失败或 git status 仍有未提交文件）
  - 被打断 / 被纠正的点（最有复盘价值）
  - 技术决策的具体内容（函数名、字段名、参数形状、报错栈的关键行）
  - 未闭环的问题清单（具体到 PR 号 / 文件 / 函数）
  - 目标是日后只看这份文档就能还原当天发生的事，不需要再翻 jsonl
- 技术细节要具体（函数名、状态名、API 形状等），避免「优化了若干功能」式空话
- 输出路径默认为当前工作目录下的 `daily-summary-YYYY-MM-DD.md`，除非用户指定别处
- 文末标注数据源：`数据源：Claude Code X 个会话 + Codex Y 个线程（Z 个 rollout）`。如果某类数据源不存在，明确写 0，不要假设

## 注意事项

- **不要臆造**：只写会话里真实出现过的工作。没抽到有价值的信号就承认没有，不要填充「应该做了什么」
- **尊重用户写作风格**：如果 memory 里有用户的写作风格偏好（如「简洁直白、技术细节充分、口语化」），按那个风格写
- **不要扩展成详细报告**：除非用户明确要长版本；默认一屏内读完
- **跳过当前会话本身**：生成总结的那个会话通常信息量有限，可不单列
