#!/usr/bin/env python3
"""
Backend AI bridge for GeminiPet (ChatGPT-Desktop-Pet-parity Quick Chat, Screen Context & Voice Mode).
Calls the locally authenticated `~/.local/bin/gemini-api` CLI and returns clean JSON on stdout.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

GEMINI_API = str(Path.home() / ".local" / "bin" / "gemini-api")

SYSTEM_PROMPT = (
    "你是用户的桌面 AI 伙伴“哈基米”（Gemini 拟人猫娘桌宠）。"
    "回答要简洁、准确、实用、有温度，适合在桌面悬浮小卡片里快速阅读（一般 1~4 句话，必要时分点）。"
    "语气自然轻快，偶尔可以带一点点可爱的语气词，但不要过度卖萌影响效率。默认使用中文回复（除非用户用英文提问）。"
)


def extract_reply_text(resp: dict) -> str:
    # Handle Interactions API shape (.steps[] / .outputs[])
    texts = []
    for key in ("outputs", "steps"):
        for item in resp.get(key) or []:
            if not isinstance(item, dict):
                continue
            itype = item.get("type", "")
            if itype == "text" and item.get("text"):
                texts.append(item["text"])
            elif itype == "model_output":
                for c in item.get("content") or []:
                    if isinstance(c, dict) and c.get("type") == "text" and c.get("text"):
                        texts.append(c["text"])
    if texts:
        return "\n".join(texts).strip()
    # Fallback plain text fields
    for k in ("text", "output", "response"):
        if isinstance(resp.get(k), str) and resp[k].strip():
            return resp[k].strip()
    return ""


def run_generate(prompt: str, inputs: list[str], prev_id: str | None, model: str) -> tuple[str, str | None, str | None]:
    cmd = [
        GEMINI_API,
        "generate",
        prompt,
        "-m", model,
        "--system", SYSTEM_PROMPT,
        "--stream=false",
        "-o", "json",
    ]
    if prev_id:
        cmd += ["--previous-interaction-id", prev_id]
    for inp in inputs:
        if inp and Path(inp).exists():
            cmd += ["-i", inp]

    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
        return "", prev_id, err[:300]

    raw = proc.stdout.strip()
    try:
        data = json.loads(raw)
        text = extract_reply_text(data)
        new_id = data.get("id") or prev_id
        if not text:
            # Fallback: retry plain text output if JSON schema differed
            return raw[:800], new_id, None
        return text, new_id, None
    except Exception:
        return raw[:800], prev_id, None


def run_tts(text: str, voice: str = "Kore") -> str | None:
    if not text:
        return None
    # Keep TTS concise for snappy playback
    spoken = text.replace("*", "").replace("#", "").replace("`", "").strip()
    if len(spoken) > 220:
        spoken = spoken[:220] + "。"
    out_wav = os.path.join(tempfile.gettempdir(), f"geminipet_tts_{os.getpid()}.wav")
    cmd = [
        GEMINI_API,
        "tts",
        spoken,
        "-v", voice,
        "--out", out_wav,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
        if proc.returncode == 0:
            path = proc.stdout.strip().splitlines()[-1].strip() if proc.stdout.strip() else out_wav
            if Path(path).exists():
                return path
            if Path(out_wav).exists():
                return out_wav
    except Exception:
        pass
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", default="")
    parser.add_argument("--audio", default="")
    parser.add_argument("--image", default="")
    parser.add_argument("--prev-id", default="")
    parser.add_argument("--model", default="gemini-3.5-flash-lite")
    parser.add_argument("--speak", action="store_true")
    parser.add_argument("--voice", default="Kore")
    args = parser.parse_args()

    inputs = []
    if args.image:
        inputs.append(args.image)
    if args.audio:
        inputs.append(args.audio)

    prompt = args.prompt.strip()
    if not prompt and args.audio and args.image:
        prompt = "请结合这张屏幕截图，听取音频里用户的语音指令并直接简洁地回答。"
    elif not prompt and args.audio:
        prompt = "请直接听取音频里用户说的话并自然简洁地回复用户（不需要重复转写用户原话，直接回答即可）。"
    elif not prompt and args.image:
        prompt = "请看看这张屏幕截图，简洁总结当前内容或指出可能需要注意的问题。"

    if not prompt:
        print(json.dumps({"ok": False, "error": "empty prompt"}, ensure_ascii=False))
        return

    text, new_id, err = run_generate(prompt, inputs, args.prev_id or None, args.model)
    if err:
        print(json.dumps({"ok": False, "error": err}, ensure_ascii=False))
        return

    audio_path = None
    if args.speak and text:
        audio_path = run_tts(text, voice=args.voice)

    print(json.dumps({
        "ok": True,
        "text": text,
        "interaction_id": new_id or "",
        "audio_path": audio_path or "",
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
