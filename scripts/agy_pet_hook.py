#!/usr/bin/env python3
"""
Antigravity Lifecycle Hook bridge for GeminiPet (v2.1 Multi-Task & Workspace Registry).
Tracks all active & recent Antigravity conversations in ~/.gemini/gemini_pet_tasks.json
(and legacy ~/.gemini/gemini_pet_status.json), then echoes `{}` so the agent loop
and permission policies are never altered.
"""

import json
import os
import sys
import time
from pathlib import Path


def summarize_tool(tool_call: dict) -> str:
    name = (tool_call or {}).get("name", "") or ""
    args = (tool_call or {}).get("args") or {}

    if "command" in name:
        summary = args.get("toolSummary") or ""
        if summary:
            return f"执行：{summary}"
        cmd = (args.get("CommandLine") or "").strip().splitlines()[0][:28] if args.get("CommandLine") else ""
        return f"执行命令：{cmd}" if cmd else "运行终端命令"
    if "edit" in name:
        p = args.get("Path") or ""
        return f"修改：{Path(p).name}" if p else "修改文件"
    if "write" in name:
        p = args.get("Path") or ""
        return f"写入：{Path(p).name}" if p else "写入文件"
    if "read" in name or "view" in name:
        p = args.get("Path") or ""
        return f"阅读：{Path(p).name}" if p else "读取文件"
    if "search_web" in name:
        q = (args.get("query") or "")[:22]
        return f"联网搜索：{q}" if q else "联网搜索中"
    if "subagent" in name:
        role = args.get("Role") or args.get("TypeName") or "子任务"
        return f"调度子代理：{role}"
    return f"处理工具：{name}" if name else "推进任务中"


def extract_last_reply(transcript_path: str) -> str:
    if not transcript_path:
        return ""
    p = Path(transcript_path)
    if not p.exists():
        return ""
    try:
        # Read tail ~64KB for fast extraction
        size = p.stat().st_size
        with p.open("rb") as f:
            if size > 65536:
                f.seek(size - 65536)
            raw = f.read().decode("utf-8", errors="ignore")
        lines = [ln for ln in raw.splitlines() if ln.strip()]
        for ln in reversed(lines[-40:]):
            try:
                obj = json.loads(ln)
            except Exception:
                continue
            if obj.get("type") == "PLANNER_RESPONSE" and isinstance(obj.get("content"), str):
                txt = obj["content"].strip()
                if txt:
                    return txt[:420]
    except Exception:
        pass
    return ""


def clean_title(text: str) -> str:
    if not text:
        return "Antigravity 任务"
    line = " ".join(text.strip().split())
    return (line[:34] + "…") if len(line) > 34 else line


def main():
    raw = sys.stdin.read().strip()
    try:
        payload = json.loads(raw) if raw else {}
    except Exception:
        payload = {}

    event = payload.get("hookEventName", "")
    conv_id = payload.get("conversationId") or "default-agy-session"
    cwd = payload.get("cwd") or ""
    ws_paths = payload.get("workspacePaths") or []
    ws_dir = cwd or (ws_paths[0] if ws_paths else "")
    workspace_name = Path(ws_dir).name if ws_dir else "默认工作区"
    user_input = (payload.get("lastUserInput") or "").strip()
    transcript_path = payload.get("transcriptPath") or ""

    gemini_dir = Path.home() / ".gemini"
    gemini_dir.mkdir(parents=True, exist_ok=True)
    tasks_path = gemini_dir / "gemini_pet_tasks.json"
    status_path = gemini_dir / "gemini_pet_status.json"

    now = time.time()

    # Load existing task registry
    tasks = []
    if tasks_path.exists():
        try:
            loaded = json.loads(tasks_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and isinstance(loaded.get("tasks"), list):
                tasks = loaded["tasks"]
        except Exception:
            tasks = []

    task = next((t for t in tasks if t.get("id") == conv_id), None)
    if task is None:
        task = {
            "id": conv_id,
            "source": "antigravity",
            "title": clean_title(user_input),
            "workspace": workspace_name,
            "workspacePath": ws_dir,
            "state": "running",
            "currentAction": "准备中…",
            "lastReply": "",
            "startedAt": now,
            "updatedAt": now,
            "steps": [],
        }
        tasks.insert(0, task)
    else:
        tasks = [task] + [t for t in tasks if t.get("id") != conv_id]

    if user_input:
        task["title"] = clean_title(user_input)
    if workspace_name:
        task["workspace"] = workspace_name
    if ws_dir:
        task["workspacePath"] = ws_dir

    legacy_state = None
    legacy_msg = None

    if event == "PreInvocation":
        if task.get("state") != "running":
            task["startedAt"] = now
        task["state"] = "running"
        task["currentAction"] = "思考规划中…"
        task["updatedAt"] = now
        legacy_state = "working"
        legacy_msg = f"{workspace_name} · 思考中…"

    elif event == "PostToolUse":
        tool_call = payload.get("toolCall") or {}
        err = (payload.get("error") or "").strip()
        step_desc = summarize_tool(tool_call)
        if task.get("state") != "running":
            task["startedAt"] = now
        task["updatedAt"] = now
        steps = task.get("steps") or []
        if err:
            task["state"] = "running"
            task["currentAction"] = f"排查错误：{step_desc}"
            steps.append({"text": f"⚠ {step_desc}（出错排查中）", "time": now})
            legacy_state = "hiss"
            legacy_msg = f"步骤报错，排查中…"
        else:
            task["state"] = "running"
            task["currentAction"] = step_desc
            steps.append({"text": f"✓ {step_desc}", "time": now})
            legacy_state = "working"
            legacy_msg = step_desc
        task["steps"] = steps[-12:]

    elif event == "Stop":
        reason = payload.get("terminationReason", "")
        task["updatedAt"] = now
        reply = extract_last_reply(transcript_path)
        if reply:
            task["lastReply"] = reply
        if reason == "ERROR":
            task["state"] = "error"
            task["currentAction"] = "执行出错"
            legacy_state = "hiss"
            legacy_msg = "任务出错，请查看"
        else:
            task["state"] = "done"
            task["currentAction"] = "已完成"
            legacy_state = "done"
            legacy_msg = f"{task['title']} · 已完成"

    # Keep latest 12 tasks; auto-expire stuck "running" tasks older than 15 minutes
    cleaned = []
    for t in tasks[:12]:
        if t.get("state") == "running" and (now - float(t.get("updatedAt", now))) > 900:
            t["state"] = "done"
            t["currentAction"] = "已暂停/结束"
        cleaned.append(t)

    tmp_tasks = tasks_path.with_suffix(".tmp")
    tmp_tasks.write_text(
        json.dumps({"updatedAt": now, "tasks": cleaned}, ensure_ascii=False),
        encoding="utf-8",
    )
    os.replace(tmp_tasks, tasks_path)

    if legacy_state:
        tmp_st = status_path.with_suffix(".tmp")
        tmp_st.write_text(
            json.dumps({"state": legacy_state, "message": legacy_msg, "updatedAt": now}, ensure_ascii=False),
            encoding="utf-8",
        )
        os.replace(tmp_st, status_path)

    print("{}")


if __name__ == "__main__":
    main()
