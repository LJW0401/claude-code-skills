#!/usr/bin/env python3
# 职责：weekly-summary 的「双源数据采集」固化实现（周一~周六，周日不计）。
#   源1(主线)：飞书「汇报」里本人手写的日报/周报。lark-cli 现场取本人 open_id，
#              POST /open-apis/report/v1/tasks/query 拉区间内汇报，客户端按
#              from_user_id 过滤出本人（服务端 user_id 过滤无效，会返回全组），
#              按 rule_name 拆「工作日报 / 工作周报」，原样提取 form_contents。
#   源2(细节)：每个有日报的日期补一份 daily-summary 细节底稿 —— 先找本地
#              daily-summary-YYYY-MM-DD.html，本地缺则从飞书邮箱「每日工作总结」
#              邮件回退取 body_html。HTML 一律剥成纯文本。两处都没有标 source=none。
#   产出：一份按日组织的紧凑 JSON digest 打到 stdout，供 Claude 据此二次提炼周报。
#         撰写/归类判断不在本脚本职责内。
# 设计：fail-first —— lark-cli 不存在 / 调用失败 / 飞书返回非 0 code 直接抛出，
#       不静默兜底；某天无汇报或无细节源 = 显式 null，绝不臆造。open_id、邮箱等
#       敏感信息全部运行时现场获取，不硬编码。
# 依赖：Python 标准库(json/subprocess/re/datetime/os/glob) + 外部命令 lark-cli
#       (须已 `lark-cli auth login` 登录 user 身份)。
"""用法：
    python3 collect.py [--monday YYYY-MM-DD] [--mailbox-max N] [--pretty]

不带 --monday 时取今天(本地)所在 ISO 周的周一。统计窗口固定为该周周一 00:00
到周日 00:00(不含)，即只覆盖周一~周六。输出结构见文件末尾 build_digest。
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, time as dtime

DETAIL_TEXT_CAP = 8000      # 单日细节正文截断长度，控制 digest 体量(token)
RULE_DAILY = "工作日报"
RULE_WEEKLY = "工作周报"
MAIL_QUERY = "每日工作总结"  # 邮箱回退的宽查询词；精确匹配在客户端按 subject 做
WEEKDAY_EN = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
# 本地 daily-summary HTML 的候选位置（定时任务产物 + 手动运行常见落点）
LOCAL_HTML_DIRS = [
    os.path.expanduser("~/.local/state/daily-summary"),
    os.path.expanduser("~/Desktop"),
    os.getcwd(),
]


# ----- lark-cli 调用 -----------------------------------------------------

def run_lark(args, feishu_raw=False):
    """调用 lark-cli，解析 stdout 的 JSON 返回。
    feishu_raw=True 时按飞书原生包 {code,msg,data} 校验 code==0。
    任何失败(命令缺失/非零退出/JSON 解析失败/飞书 code 非 0)直接抛出。"""
    try:
        proc = subprocess.run(["lark-cli", *args], capture_output=True, text=True)
    except FileNotFoundError:
        raise RuntimeError("找不到 lark-cli，请确认已安装并在 PATH 中")
    if proc.returncode != 0:
        raise RuntimeError(f"lark-cli {' '.join(args)} 退出码 {proc.returncode}：{proc.stderr.strip()}")
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        raise RuntimeError(f"lark-cli {' '.join(args)} 输出非 JSON：{proc.stdout[:200]!r}")
    if feishu_raw and data.get("code") not in (0, None):
        raise RuntimeError(f"飞书接口报错 code={data.get('code')} msg={data.get('msg')}")
    return data


def get_open_id():
    """现场取本人 open_id（不硬编码）。裸调 authen/v1/user_info 的 data 直接是
    用户字段（data.open_id），无 data.user 这层；用 Python 解析（lark-cli 的
    -q jq 对裸调 api 取不到值）。"""
    d = run_lark(["api", "GET", "/open-apis/authen/v1/user_info", "--as", "user"],
                 feishu_raw=True)
    data = d.get("data") or {}
    oid = data.get("open_id") or data.get("user", {}).get("open_id")
    if not oid:
        raise RuntimeError("未取到本人 open_id，检查 user 身份是否已登录")
    return oid


# ----- 源1：飞书汇报 ------------------------------------------------------

def fetch_reports(open_id, start_epoch, end_epoch):
    """拉区间内本人的全部汇报。返回 (daily_by_date, weekly_list)。
    daily_by_date: {date_str: report_dict}（同日多份取 commit_time 最新）
    weekly_list:   [report_dict, ...]（按 commit_time 升序）"""
    items, page_token, guard = [], "", 0
    while True:
        d = run_lark(["api", "POST", "/open-apis/report/v1/tasks/query", "--as", "user",
                      "--data", json.dumps({
                          "commit_start_time": start_epoch,
                          "commit_end_time": end_epoch,
                          "page_token": page_token,
                          "page_size": 20,
                      })], feishu_raw=True)
        data = d.get("data") or {}
        items += data.get("items") or []
        # tasks/query 的 data 无独立 page_token 字段；has_more 为真时尝试续拉，
        # 取不到游标就停（避免死循环），实测一周数据量 has_more 基本为 False。
        page_token = data.get("page_token") or ""
        guard += 1
        if not data.get("has_more") or not page_token or guard >= 20:
            break
    daily_by_date, weekly = {}, []
    for it in items:
        if it.get("from_user_id") != open_id:  # 服务端 user_id 过滤无效，客户端兜底
            continue
        rec = _shape_report(it)
        if it.get("rule_name") == RULE_WEEKLY:
            weekly.append(rec)
        elif it.get("rule_name") == RULE_DAILY:
            prev = daily_by_date.get(rec["date"])
            if prev is None or rec["commit_time"] > prev["commit_time"]:
                daily_by_date[rec["date"]] = rec
    weekly.sort(key=lambda r: r["commit_time"])
    return daily_by_date, weekly


def _shape_report(item):
    ct = item.get("commit_time")
    date_str = datetime.fromtimestamp(ct).strftime("%Y-%m-%d") if ct else None
    fields = [{"name": (f.get("field_name") or "").strip(),
               "value": (f.get("field_value") or "").strip()}
              for f in item.get("form_contents") or []]
    return {
        "date": date_str,
        "commit_time": ct or 0,
        "rule": item.get("rule_name"),
        "fields": fields,
    }


# ----- 源2：本地 HTML / 邮箱回退 -----------------------------------------

def find_local_html(date_str):
    """在候选位置找 daily-summary-<date>.html，返回首个命中的路径或 None。"""
    name = f"daily-summary-{date_str}.html"
    for root in LOCAL_HTML_DIRS:
        if not os.path.isdir(root):
            continue
        hit = os.path.join(root, name)
        if os.path.isfile(hit):
            return hit
        # 桌面/工作目录可能放在子目录，浅层 glob 兜一层
        for p in glob.glob(os.path.join(root, "*", name)):
            return p
    return None


def index_mail(max_msgs):
    """一次性宽查询邮箱「每日工作总结」邮件，建 {date_str: message_id}（同日取最新）。
    精确匹配 subject「每日工作总结 — YYYY-MM-DD」在客户端做。"""
    d = run_lark(["mail", "+triage", "--as", "user", "--query", MAIL_QUERY,
                  "--max", str(max_msgs), "--format", "json"])
    by_date = {}
    for m in d.get("messages") or []:
        subj = m.get("subject") or ""
        mt = re.search(r"每日工作总结\s*[—-]\s*(\d{4}-\d{2}-\d{2})", subj)
        if not mt:
            continue
        ds, mid, sent = mt.group(1), m.get("message_id"), m.get("date") or ""
        prev = by_date.get(ds)
        if prev is None or sent > prev[1]:  # ISO 时间串可直接字典序比较取最新
            by_date[ds] = (mid, sent)
    return {ds: mid for ds, (mid, _sent) in by_date.items()}


def fetch_mail_html(message_id):
    d = run_lark(["mail", "+message", "--as", "user", "--message-id", message_id,
                  "--format", "json"])
    return (d.get("data") or {}).get("body_html") or ""


def html_to_text(html):
    """剥标签 + 压空白成纯文本，截断到 DETAIL_TEXT_CAP。"""
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"&nbsp;", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= DETAIL_TEXT_CAP else text[:DETAIL_TEXT_CAP] + "…"


def load_detail(date_str, mail_index):
    """为某天加载细节底稿：先本地，缺则邮箱回退，都没有 source=none。"""
    path = find_local_html(date_str)
    if path:
        with open(path, encoding="utf-8") as fp:
            return {"source": "local", "path": path, "text": html_to_text(fp.read())}
    mid = mail_index.get(date_str)
    if mid:
        return {"source": "mail", "message_id": mid, "text": html_to_text(fetch_mail_html(mid))}
    return {"source": "none", "text": None}


# ----- 组装 digest -------------------------------------------------------

def week_dates(monday):
    """周一~周六 6 个 date（周日不计）。"""
    return [monday + timedelta(days=i) for i in range(6)]


def build_digest(monday, mailbox_max):
    days = week_dates(monday)
    sunday = monday + timedelta(days=6)
    local_tz = datetime.now().astimezone().tzinfo
    start_epoch = int(datetime.combine(monday, dtime(0, 0), tzinfo=local_tz).timestamp())
    end_epoch = int(datetime.combine(sunday, dtime(0, 0), tzinfo=local_tz).timestamp())

    open_id = get_open_id()
    daily_by_date, weekly = fetch_reports(open_id, start_epoch, end_epoch)
    mail_index = index_mail(mailbox_max)

    out_days, stat = [], {"report": 0, "local": 0, "mail": 0, "none": 0}
    for i, d in enumerate(days):
        ds = d.isoformat()
        report = daily_by_date.get(ds)
        if report:
            stat["report"] += 1
        # 每天都尝试补细节：某天没写汇报但本地/邮箱有 daily-summary，
        # 往往正是「汇报漏掉的交付」，应纳入而非丢弃
        detail = load_detail(ds, mail_index)
        stat[detail["source"]] += 1
        out_days.append({
            "date": ds,
            "weekday": WEEKDAY_EN[i],
            "report": {"rule": report["rule"], "fields": report["fields"]} if report else None,
            "detail": detail,
        })

    return {
        "week": {"monday": monday.isoformat(),
                 "saturday": days[-1].isoformat(),
                 "note": "统计周一~周六，周日不计"},
        "me": open_id,
        "stats": {
            "report_days": stat["report"],
            "detail_local": stat["local"],
            "detail_mail": stat["mail"],
            "detail_none": stat["none"],
            "weekly_reports": len(weekly),
        },
        "days": out_days,
        # 区间内本人提交的「工作周报」（可能是上周周报在本周一交），供参考
        "weekly_reports": [{"date": w["date"], "fields": w["fields"]} for w in weekly],
    }


def main():
    ap = argparse.ArgumentParser(description="weekly-summary 双源数据采集(周一~周六)")
    ap.add_argument("--monday", help="本周周一 YYYY-MM-DD，默认今天所在 ISO 周的周一")
    ap.add_argument("--mailbox-max", type=int, default=60,
                    help="邮箱回退宽查询拉取的最大邮件数(默认 60)")
    ap.add_argument("--pretty", action="store_true", help="缩进输出")
    args = ap.parse_args()

    if args.monday:
        monday = datetime.strptime(args.monday, "%Y-%m-%d").date()
    else:
        today = datetime.now().astimezone().date()
        monday = today - timedelta(days=today.weekday())  # weekday(): Mon=0

    digest = build_digest(monday, args.mailbox_max)
    json.dump(digest, sys.stdout, ensure_ascii=False,
              indent=2 if args.pretty else None)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
