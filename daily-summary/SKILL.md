---
name: daily-summary
description: 基于当天 Claude Code 活跃会话生成每日工作总结。扫描 ~/.claude/projects 下当天修改的 .jsonl 会话文件，从中提取用户消息还原工作主题，按「主力项目 / 辅助项目 / 跨项目共识」组织成简要的 md 文档。当用户说「总结今天的工作」「根据对话整理日报」「输出每日总结」或类似诉求时使用。
---

# daily-summary

从 Claude Code 本机会话记录中提炼每日工作总结。

## 数据源

- **会话文件**：`~/.claude/projects/<项目路径转义>/<session-uuid>.jsonl`
  - 项目路径转义规则：绝对路径中 `/` 替换为 `-`，例如 `/home/penguin/Desktop/feishu` → `-home-penguin-Desktop-feishu`
  - 每行一条 JSON，`type=user` 的条目含用户消息；`message.content` 可能是字符串也可能是数组（取 `type=text` 的 `text` 字段）
- **用户消息元数据**（每条 `type=user` 都带）：
  - `timestamp`：ISO 8601 UTC（如 `2026-04-16T07:14:00.747Z`），可解析为本地时区还原时间线
  - `cwd`：工作目录，比目录名更精确地标识项目
  - `sessionId` / `gitBranch` / `permissionMode` / `version` / `promptId`
- **当前日期**：取 `currentDate` 上下文，没有则用 `date +%F`

## 流程

### 第一步：定位当天活跃会话

```bash
find ~/.claude/projects -name "*.jsonl" -newermt "YYYY-MM-DD 00:00" -printf "%T+ %s %p\n" | sort -r
```

按最后修改时间 + 文件大小初步判断权重：**大文件（≥几 MB）或消息条数多的，通常是当天主力项目**；KB 级的零散会话归入辅助或忽略。

### 第二步：抽取用户消息

对每个会话文件跑以下 Python 片段，拉出首尾若干条真实用户提问（跳过以 `<` 开头的 system-reminder、skill 注入和 tool_result）：

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

- **开头消息**反映主题立项；**结尾消息**反映当天收尾状态；中间的 skill 注入（以 `Base directory for this skill:` 开头）可用于识别调用了 commit / release / pr / merge 等节点，作为「交付节奏」信号。
- **利用 timestamp**：抽消息时一并带上 `timestamp`，转成本地时区（`datetime.fromisoformat(ts.replace('Z','+00:00')).astimezone()`），可用于：
  - 识别「今天几点到几点在做 X」的时间块
  - 过滤掉跨日会话里昨天的部分（只保留 `timestamp` 落在目标日期的条目）
  - 统计每个项目的投入时长（首条 → 末条 user 消息间的时间跨度）
  - 观察项目切换节奏（按 timestamp 排序所有项目的 user 消息，看上下文切换频率）

### 第三步：按项目归类并识别主题

- 每个项目一段：主题（在做什么） + 关键动作（发版 / 合并 / 立项 / 调研） + 结尾状态
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
- 时段：HH:MM–HH:MM（N 轮交互）
- 主题 / 立项动机
- 关键决策与取舍（含被用户打断、被纠正的点）
- 交付节点：commit / PR / release 等
- 结尾状态 & 明日可跟进

### 项目B
……

### 跨项目观察
- 时间线 / 切换频率 / 投入时长分布
- 反复出现的技术共识
- 被搁置或未闭环的问题
```

- **摘要部分**：按项目分类的**无序列表**，一个项目一条 bullet，项目名加粗后跟冒号、再写当天做的事；不含时间戳/轮数/投入时长等统计；环境类/零散会话合并到「环境 / 零散」一条；跨项目共识可作为最后一条单独列出。目标是直接粘贴到日报里
- **详细部分**：可以用列表、时间、数字、引用用户原话；目标是帮本人回忆当天发生了什么、有哪些未解决的点
- 技术细节要具体（函数名、状态名、API 形状等），避免「优化了若干功能」式空话
- 输出路径默认为当前工作目录下的 `daily-summary-YYYY-MM-DD.md`，除非用户指定别处

## 注意事项

- **不要臆造**：只写会话里真实出现过的工作。没抽到有价值的信号就承认没有，不要填充「应该做了什么」
- **尊重用户写作风格**：如果 memory 里有用户的写作风格偏好（如「简洁直白、技术细节充分、口语化」），按那个风格写
- **不要扩展成详细报告**：除非用户明确要长版本；默认一屏内读完
- **跳过当前会话本身**：生成总结的那个会话通常信息量有限，可不单列
