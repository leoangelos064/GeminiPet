#!/usr/bin/env python3
"""
Studio-grade chroma-key background removal & sprite normalizer for GeminiPet.
Removes solid lime-green (#00FF00) background with flood-fill + anti-aliased edge
alpha matting + green color despill, then centers and bottom-aligns all sprites
to crisp 512x512 transparent PNGs.
"""

import os
import sys
from collections import deque
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont


def remove_green_screen(img: Image.Image) -> Image.Image:
    rgba = img.convert("RGBA")
    arr = np.array(rgba, dtype=np.float32)
    h, w, _ = arr.shape

    r = arr[:, :, 0]
    g = arr[:, :, 1]
    b = arr[:, :, 2]

    # Measure how "green screen" each pixel is
    max_rb = np.maximum(r, b)
    green_excess = g - max_rb

    # Core chroma-key background candidate: strong green dominance
    # Gemini-chan has zero lime green in her palette (blue/purple/pink/gold/navy/white)
    strong_bg = (green_excess > 35.0) & (g > 110.0)
    soft_bg = (green_excess > 12.0) & (g > 75.0)

    # Flood-fill from borders on strong_bg to identify exterior background
    # Also detect interior enclosed bright green pockets (e.g. between hair/legs/sleeves)
    visited = np.zeros((h, w), dtype=bool)
    q = deque()

    # Seed from all 4 borders
    for x in range(w):
        if strong_bg[0, x]:
            visited[0, x] = True
            q.append((0, x))
        if strong_bg[h - 1, x]:
            visited[h - 1, x] = True
            q.append((h - 1, x))
    for y in range(h):
        if strong_bg[y, 0]:
            visited[y, 0] = True
            q.append((y, 0))
        if strong_bg[y, w - 1]:
            visited[y, w - 1] = True
            q.append((y, w - 1))

    # Also seed any interior pixels that are unmistakably pure chroma green
    pure_chroma = (green_excess > 75.0) & (g > 170.0) & (r < 110.0) & (b < 110.0)
    ys, xs = np.where(pure_chroma & ~visited)
    for y, x in zip(ys, xs):
        visited[y, x] = True
        q.append((int(y), int(x)))

    while q:
        cy, cx = q.popleft()
        for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
            if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx]:
                if strong_bg[ny, nx]:
                    visited[ny, nx] = True
                    q.append((ny, nx))

    # Dilate background mask by 2 pixels to capture anti-aliased fringe pixels
    fringe = visited.copy()
    for _ in range(3):
        padded = np.pad(fringe, 1, mode="edge")
        fringe = (
            padded[:-2, 1:-1]
            | padded[2:, 1:-1]
            | padded[1:-1, :-2]
            | padded[1:-1, 2:]
            | padded[:-2, :-2]
            | padded[:-2, 2:]
            | padded[2:, :-2]
            | padded[2:, 2:]
            | fringe
        )
    edge_band = fringe & ~visited

    alpha = arr[:, :, 3].copy()
    # Exterior / enclosed strong green -> fully transparent
    alpha[visited] = 0.0

    # Smooth partial transparency on anti-aliased edge band
    edge_green = np.clip((green_excess - 5.0) / 55.0, 0.0, 1.0)
    alpha[edge_band] = np.where(
        soft_bg[edge_band],
        255.0 * (1.0 - edge_green[edge_band]),
        alpha[edge_band],
    )

    # Despill green reflection on the edge band (and anywhere with noticeable green fringe)
    despill_mask = edge_band | ((green_excess > 8.0) & (alpha > 0) & (alpha < 255))
    new_g = np.minimum(g, max_rb)
    arr[:, :, 1] = np.where(despill_mask, new_g, g)

    # Also remove isolated 1-2px tiny green speckles left outside
    arr[:, :, 3] = np.clip(alpha, 0, 255)

    # Clean fully transparent pixels' RGB to 0 so resizing doesn't bleed green
    zero_alpha = arr[:, :, 3] < 8
    arr[zero_alpha] = 0

    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def normalize_sprite(img: Image.Image, canvas_size: int = 512, pad: int = 24) -> Image.Image:
    # Crop to non-transparent bounding box
    alpha = np.array(img.getchannel("A"))
    ys, xs = np.where(alpha > 20)
    if len(xs) == 0 or len(ys) == 0:
        return Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    x0, x1 = int(xs.min()), int(xs.max()) + 1
    y0, y1 = int(ys.min()), int(ys.max()) + 1
    cropped = img.crop((x0, y0, x1, y1))

    cw, ch = cropped.size
    max_dim = canvas_size - pad * 2
    scale = min(max_dim / cw, max_dim / ch)
    nw = max(1, int(round(cw * scale)))
    nh = max(1, int(round(ch * scale)))

    resized = cropped.resize((nw, nh), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    # Horizontally centered, bottom-aligned with small padding so feet stay grounded
    ox = (canvas_size - nw) // 2
    oy = canvas_size - pad - nh
    canvas.alpha_composite(resized, (ox, oy))
    return canvas


def make_checkerboard(w: int, h: int, tile: int = 16) -> Image.Image:
    grid = np.indices((h, w)).sum(axis=0)
    # Using tile division
    yy, xx = np.mgrid[0:h, 0:w]
    checker = ((xx // tile) + (yy // tile)) % 2
    c1 = np.array([235, 232, 245, 255], dtype=np.uint8)
    c2 = np.array([218, 214, 232, 255], dtype=np.uint8)
    bg = np.where(checker[:, :, None] == 0, c1, c2)
    return Image.fromarray(bg, "RGBA")


def main():
    base = Path(__file__).resolve().parent.parent
    raw_dir = base / "raw_sprites"
    out_sprites = base / "sprites"
    out_stickers = base / "stickers"
    out_sprites.mkdir(parents=True, exist_ok=True)
    out_stickers.mkdir(parents=True, exist_ok=True)

    names = ["idle", "happy", "working", "hiss", "sleep", "drag"]
    labels = {
        "idle": "待机 Idle",
        "happy": "摸头 Happy",
        "working": "干活 Working",
        "hiss": "哈气 Hiss",
        "sleep": "睡觉 Sleep",
        "drag": "拎起 Drag",
    }

    processed = []
    for name in names:
        src = raw_dir / f"{name}.png"
        if not src.exists():
            print(f"[WARN] Missing {src}")
            continue
        raw_img = Image.open(src)
        cut = remove_green_screen(raw_img)
        norm = normalize_sprite(cut, canvas_size=512, pad=22)

        # Save to sprites/ (for app) and stickers/ (for user's sticker pack)
        norm.save(out_sprites / f"{name}.png")
        norm.save(out_stickers / f"哈基米_{name}.png")
        processed.append((name, norm))
        print(f"[OK] Processed {name}.png -> transparent 512x512")

    if processed:
        cols = 3
        rows = (len(processed) + cols - 1) // cols
        cell = 340
        sheet = make_checkerboard(cols * cell, rows * cell, tile=17)
        draw = ImageDraw.Draw(sheet)

        for idx, (name, sp) in enumerate(processed):
            r_idx = idx // cols
            c_idx = idx % cols
            thumb = sp.resize((300, 300), Image.Resampling.LANCZOS)
            sheet.alpha_composite(thumb, (c_idx * cell + 20, r_idx * cell + 12))
            draw.rectangle(
                [c_idx * cell + 8, r_idx * cell + 312, (c_idx + 1) * cell - 8, (r_idx + 1) * cell - 6],
                fill=(40, 34, 68, 210),
            )
            draw.text((c_idx * cell + 18, r_idx * cell + 316), labels.get(name, name), fill=(255, 255, 255, 255))

        preview_path = base / "sprites_preview.png"
        sheet.convert("RGB").save(preview_path)
        print(f"[OK] Saved preview sheet -> {preview_path}")


if __name__ == "__main__":
    main()
