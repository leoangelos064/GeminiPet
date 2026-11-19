#!/usr/bin/env python3
"""
Antigravity Lifecycle Hook bridge for GeminiPet.
Writes live status to ~/.gemini/gemini_pet_status.json and echoes `{}` so the
agent loop and permission policies are never altered.
"""

import json
import os
import sys
import time
from pathlib import Path


def main():
    raw = sys.stdin.read().strip()
    try:
        payload = json.loads(raw) if raw else {}
    except Exception:
        payload = {}

    event = payload.get("hookEventName", "")
    status_path = Path.home() / ".gemini" / "gemini_pet_status.json"
    status_path.parent.mkdir(parents=True, exist_ok=True)

    state = None
    message = None

    if event == "PreInvocation":
        state = "working"
        message = "哈基米正在高速思考中… ✦"
    elif event == "PostToolUse":
        tool = (payload.get("toolCall") or {}).get("name", "")
        err = payload.get("error", "")
        if err:
            state = "hiss"
            message = "刚刚有一步报错了喵，正在排查…"
        else:
            state = "working"
            if "command" in tool:
                message = "终端命令跑完啦，继续处理喵~ 💻"
            elif "file" in tool or "edit" in tool or "write" in tool:
                message = "文件写好啦，继续干活中… ✦"
            elif "search" in tool:
                message = "查到资料啦，正在整理喵~"
            else:
                message = "正在稳步推进任务中… ✦"
    elif event == "Stop":
        reason = payload.get("terminationReason", "")
        if reason == "ERROR":
            state = "hiss"
            message = "哎呀出错了喵！快来看看 💢"
        else:
            state = "done"
            message = "任务搞定啦！快回来看看~ ✦"

    if state:
        data = {
            "state": state,
            "message": message,
            "updatedAt": time.time(),
        }
        tmp = status_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, status_path)

    print("{}")


if __name__ == "__main__":
    main()
