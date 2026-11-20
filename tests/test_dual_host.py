#!/usr/bin/env python3
"""
Unit & integration tests for scripts/agy_pet_hook.py dual-host source detection.
Runs with macOS system `/usr/bin/python3` as well as Python 3.10+.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import agy_pet_hook  # noqa: E402


def test_process_tree_detection() -> None:
    # 1. Gemini.app built-in agy helper chain
    gemini_tree = {
        300: (200, "python3 /Applications/GeminiPet.app/Contents/Resources/agy_pet_hook.py"),
        200: (100, "/Applications/Gemini.app/Contents/Helpers/agy --stdio"),
        100: (1, "/Applications/Gemini.app/Contents/MacOS/Gemini"),
    }
    assert agy_pet_hook.detect_source_from_process_tree(300, resolver=lambda p: gemini_tree.get(p, (0, ""))) == "gemini"

    # 2. Antigravity IDE chain
    ide_tree = {
        400: (300, "sh -c python3 agy_pet_hook.py"),
        300: (200, "/Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE"),
    }
    assert agy_pet_hook.detect_source_from_process_tree(400, resolver=lambda p: ide_tree.get(p, (0, ""))) == "antigravity-ide"

    # 3. Antigravity.app chain
    agy_tree = {
        500: (400, "/bin/zsh -c hook"),
        400: (1, "/Applications/Antigravity.app/Contents/MacOS/Antigravity"),
    }
    assert agy_pet_hook.detect_source_from_process_tree(500, resolver=lambda p: agy_tree.get(p, (0, ""))) == "antigravity"

    # 4. Fallback when launched from unknown shell
    unknown_tree = {600: (1, "/bin/zsh")}
    assert agy_pet_hook.detect_source_from_process_tree(600, resolver=lambda p: unknown_tree.get(p, (0, ""))) == "antigravity"


def test_hook_end_to_end_isolated_home() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        env = os.environ.copy()
        env["HOME"] = tmp
        script = str(ROOT / "scripts" / "agy_pet_hook.py")

        payload = {
            "hookEventName": "PreInvocation",
            "conversationId": "conv-test-123",
            "cwd": "/tmp/demo_project",
            "lastUserInput": "检查双端监控是否正常",
        }
        proc = subprocess.run(
            ["/usr/bin/python3", script],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "{}", f"Unexpected hook stdout: {proc.stdout!r}"

        tasks_file = Path(tmp) / ".gemini" / "gemini_pet_tasks.json"
        status_file = Path(tmp) / ".gemini" / "gemini_pet_status.json"
        assert tasks_file.exists() and status_file.exists()

        data = json.loads(tasks_file.read_text(encoding="utf-8"))
        assert len(data["tasks"]) == 1
        t = data["tasks"][0]
        assert t["id"] == "conv-test-123"
        assert t["source"] in ("antigravity", "antigravity-ide", "gemini")
        assert t["state"] == "running"

        # Stop event transitions cleanly to done and still outputs {}
        stop_payload = {
            "hookEventName": "Stop",
            "conversationId": "conv-test-123",
            "cwd": "/tmp/demo_project",
            "terminationReason": "NO_TOOL_CALL",
        }
        proc2 = subprocess.run(
            ["/usr/bin/python3", script],
            input=json.dumps(stop_payload),
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        assert proc2.returncode == 0
        assert proc2.stdout.strip() == "{}"
        data2 = json.loads(tasks_file.read_text(encoding="utf-8"))
        assert data2["tasks"][0]["state"] == "done"


if __name__ == "__main__":
    test_process_tree_detection()
    test_hook_end_to_end_isolated_home()
    print("✅ test_dual_host.py PASSED")
