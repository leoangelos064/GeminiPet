#!/usr/bin/env python3
"""
Craft cohesive, supersampled (2x -> 1x LANCZOS) anime cel-shaded sprite variants
(working, hiss, sleep) + wrist-feathered happy sprite from the 3 generated base
sprites (idle, happy, drag), then render a crisp 3x2 preview sheet with Chinese labels.
"""

import math
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

BASE = Path(__file__).resolve().parent.parent
SPRITES = BASE / "sprites"
STICKERS = BASE / "stickers"
OUTLINE = (54, 40, 88, 255)  # Matches the dark-purple anime lineart of Gemini-chan


def draw_four_star(draw: ImageDraw.ImageDraw, cx: float, cy: float, r_outer: float, r_inner: float,
                   fill, outline=OUTLINE, width: int = 4):
    pts = []
    for i in range(8):
        angle = i * math.pi / 4.0 - math.pi / 2.0
        r = r_outer if i % 2 == 0 else r_inner
        pts.append((cx + math.cos(angle) * r, cy + math.sin(angle) * r))
    draw.polygon(pts, fill=fill)
    if outline and width > 0:
        draw.line(pts + [pts[0]], fill=outline, width=width, joint="curve")


def draw_anger_mark(layer: Image.Image, cx: float, cy: float, size: float, angle_deg: float = -12):
    """Draw a crisp anime cel-shaded 💢 anger mark on a supersampled RGBA layer."""
    patch_sz = int(size * 3.0)
    patch = Image.new("RGBA", (patch_sz, patch_sz), (0, 0, 0, 0))
    d = ImageDraw.Draw(patch)
    mid = patch_sz / 2.0
    gap = size * 0.24
    arm = size * 0.62
    r = size * 0.42
    stroke_out = max(4, int(size * 0.22))
    stroke_in = max(2, int(size * 0.11))

    # Four curved L-brackets facing outward
    quads = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    for sx, sy in quads:
        p1 = (mid + sx * (gap + arm), mid + sy * gap)
        p2 = (mid + sx * gap, mid + sy * gap)
        p3 = (mid + sx * gap, mid + sy * (gap + arm))
        # Dark outline
        d.line([p1, p2, p3], fill=(115, 22, 58, 255), width=stroke_out, joint="curve")
        for pt in (p1, p2, p3):
            rr = stroke_out / 2.0
            d.ellipse([pt[0] - rr, pt[1] - rr, pt[0] + rr, pt[1] + rr], fill=(115, 22, 58, 255))
    for sx, sy in quads:
        p1 = (mid + sx * (gap + arm), mid + sy * gap)
        p2 = (mid + sx * gap, mid + sy * gap)
        p3 = (mid + sx * gap, mid + sy * (gap + arm))
        # Bright coral-red inner stroke
        d.line([p1, p2, p3], fill=(255, 76, 112, 255), width=stroke_in, joint="curve")
        for pt in (p1, p2, p3):
            rr = stroke_in / 2.0
            d.ellipse([pt[0] - rr, pt[1] - rr, pt[0] + rr, pt[1] + rr], fill=(255, 76, 112, 255))

    patch = patch.rotate(angle_deg, resample=Image.Resampling.BICUBIC, expand=True)
    ox = int(round(cx - patch.width / 2.0))
    oy = int(round(cy - patch.height / 2.0))
    layer.alpha_composite(patch, (ox, oy))


def draw_spark_bolt(draw: ImageDraw.ImageDraw, pts, fill, outline=OUTLINE, width: int = 4):
    draw.polygon(pts, fill=fill)
    draw.line(pts + [pts[0]], fill=outline, width=width, joint="curve")


def feather_happy_wrist(happy_img: Image.Image) -> Image.Image:
    """Gently soften the left cut-edge of the headpat wrist in happy.png."""
    arr = np.array(happy_img, dtype=np.float32)
    # Wrist cut sits around x in [150..172], y in [62..106]
    for x in range(148, 174):
        t = (x - 148) / 26.0
        # Smooth cubic fade
        factor = t * t * (3.0 - 2.0 * t)
        # Only affect skin-colored pixels (warm R > B + 18) in the wrist band so cat ear stays untouched
        band = arr[62:108, x]
        is_skin = (band[:, 0] > 200) & (band[:, 1] > 160) & ((band[:, 0] - band[:, 2]) > 22)
        band[is_skin, 3] *= factor
        arr[62:108, x] = band
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def build_working(idle_img: Image.Image) -> Image.Image:
    """Create 'working' sprite: cute cyber-star round glasses + floating holographic Gemini code screen."""
    S = 1024
    canvas = idle_img.resize((S, S), Image.Resampling.LANCZOS)

    # 1) Soft cyan-lavender upward glow behind holographic screen
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([300, 350, 724, 650], fill=(118, 182, 255, 65))
    gd.ellipse([360, 410, 664, 600], fill=(176, 138, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=34))
    canvas.alpha_composite(glow)

    # 2) Cute round lavender-gold glasses on her eyes
    # 512 coords: left eye (216, 154), right eye (272, 150) -> 1024 coords: (432, 308), (544, 300)
    glass = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(glass)
    lx, ly, lr = 430, 310, 42
    rx, ry, rr = 546, 302, 42
    # Subtle translucent lens sheen (crystal clear so heterochromia shines through)
    d.ellipse([lx - lr, ly - lr, lx + lr, ly + lr], fill=(220, 240, 255, 22))
    d.ellipse([rx - rr, ry - rr, rx + rr, ry + rr], fill=(220, 240, 255, 22))
    # Specular diagonal shine lines inside lenses
    d.line([(lx - 22, ly - 15), (lx - 10, ly - 27)], fill=(255, 255, 255, 185), width=5)
    d.line([(rx - 22, ry - 15), (rx - 10, ry - 27)], fill=(255, 255, 255, 185), width=5)
    # Sleek thin dark-purple outer rim + warm gold inner rim
    for (cx, cy, r) in ((lx, ly, lr), (rx, ry, rr)):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=OUTLINE, width=6)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(248, 214, 135, 255), width=3)
    # Bridge
    d.arc([lx + lr - 6, ly - 14, rx - rr + 6, ly + 8], start=200, end=340, fill=OUTLINE, width=6)
    d.arc([lx + lr - 6, ly - 14, rx - rr + 6, ly + 8], start=200, end=340, fill=(248, 214, 135, 255), width=3)
    canvas.alpha_composite(glass)

    # 3) Floating translucent holographic Gemini code panel in front of her chest/hands
    holo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(holo)

    # Subtle outer bloom for screen
    bloom = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bloom)
    panel_box = [312, 416, 712, 608]
    bd.rounded_rectangle(panel_box, radius=28, fill=(108, 165, 255, 110))
    bloom = bloom.filter(ImageFilter.GaussianBlur(radius=18))
    canvas.alpha_composite(bloom)

    # Dark translucent indigo-glass window
    hd.rounded_rectangle(panel_box, radius=26, fill=(26, 22, 64, 215))
    # Subtle glass highlight behind content
    hd.polygon([(334, 422), (432, 422), (368, 602), (318, 602)], fill=(255, 255, 255, 22))
    # Top title bar strip
    hd.rounded_rectangle([318, 420, 706, 458], radius=20, fill=(52, 42, 114, 225))
    # Window traffic dots (pink, gold, cyan)
    for idx, col in enumerate(((255, 115, 165, 255), (255, 214, 102, 255), (105, 225, 255, 255))):
        cx = 346 + idx * 24
        cy = 439
        hd.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], fill=col)

    # Glowing Gemini 4-pointed star on the left side of screen (drawn cleanly ON TOP)
    draw_four_star(hd, 396, 528, 42, 15, fill=(158, 214, 255, 255), outline=(255, 255, 255, 255), width=4)
    draw_four_star(hd, 396, 528, 22, 8, fill=(238, 178, 255, 255), outline=None, width=0)

    # Cute glowing colorful syntax code bars on right side of screen
    code_lines = [
        (466, 480, 120, (120, 228, 255, 240)),
        (596, 480, 74, (238, 155, 255, 240)),
        (486, 506, 164, (195, 180, 255, 235)),
        (486, 532, 92, (255, 216, 128, 245)),
        (588, 532, 88, (125, 238, 215, 235)),
        (466, 558, 148, (255, 148, 200, 235)),
        (624, 558, 36, (150, 220, 255, 245)),
        (466, 582, 102, (165, 195, 255, 210)),
    ]
    for x, y, w, col in code_lines:
        hd.rounded_rectangle([x, y, x + w, y + 13], radius=6, fill=col)

    # Crisp double outline (dark purple outer + glowing sky-lavender inner)
    hd.rounded_rectangle(panel_box, radius=26, outline=OUTLINE, width=10)
    hd.rounded_rectangle([316, 420, 708, 604], radius=24, outline=(145, 215, 255, 255), width=5)

    # Floating little holo stars around panel
    draw_four_star(hd, 294, 420, 22, 8, fill=(168, 228, 255, 255), outline=OUTLINE, width=4)
    draw_four_star(hd, 728, 582, 24, 9, fill=(235, 168, 255, 255), outline=OUTLINE, width=4)
    draw_four_star(hd, 742, 434, 16, 6, fill=(255, 224, 130, 255), outline=OUTLINE, width=3)

    # Slight playful tilt (-3 deg)
    holo = holo.rotate(-3.0, resample=Image.Resampling.BICUBIC, center=(512, 510))
    canvas.alpha_composite(holo)

    return canvas.resize((512, 512), Image.Resampling.LANCZOS)


def build_hiss(drag_img: Image.Image) -> Image.Image:
    """Create 'hiss' (哈气傲娇!) sprite from drag_img with furrowed angry brows, fangs, 💢, and sparks."""
    S = 1024
    canvas = drag_img.resize((S, S), Image.Resampling.LANCZOS)
    d = ImageDraw.Draw(canvas)

    # 1) Paint over the small blue sweat drop on her right cheek (512: x 308..334, y 142..182 -> 1024: x 614..668, y 282..368)
    # Actually place a bright coral-red cel-shaded 💢 anger mark slightly higher on her temple (right side) & a smaller one left!
    # Also draw fierce cute V-shaped furrowed eyebrows right above her eyes!
    # 1024 coords: left eye center (432, 336), right eye center (564, 336)
    # Soft warm-peach/hair-matched patch to clean subtle worried brows just above eyes?
    # Better: draw crisp bold cel-shaded angry V-eyebrows that sit prominently over her upper eye rims!
    left_brow = [(386, 278), (468, 308)]
    right_brow = [(608, 278), (526, 308)]
    d.line(left_brow, fill=OUTLINE, width=9)
    d.line(right_brow, fill=OUTLINE, width=9)
    # Round caps
    for pt in left_brow + right_brow:
        d.ellipse([pt[0] - 4, pt[1] - 4, pt[0] + 4, pt[1] + 4], fill=OUTLINE)

    # 2) Cute angry cat-hiss mouth with tiny sharp white fangs!
    # 1024 mouth center ~ (498, 396)
    mx, my = 498, 398
    # Open wide fierce cute cat mouth
    mouth_box = [mx - 28, my - 18, mx + 28, my + 24]
    d.ellipse(mouth_box, fill=(215, 78, 108, 255), outline=OUTLINE, width=6)
    # Tongue highlight at bottom
    d.chord([mx - 20, my - 2, mx + 20, my + 22], start=0, end=180, fill=(255, 148, 168, 255))
    # Two adorable sharp white cat fangs at top corners!
    d.polygon([(mx - 17, my - 14), (mx - 6, my - 14), (mx - 12, my + 4)], fill=(255, 255, 255, 255), outline=OUTLINE)
    d.polygon([(mx + 6, my - 14), (mx + 17, my - 14), (mx + 12, my + 4)], fill=(255, 255, 255, 255), outline=OUTLINE)

    # 3) Intense rosy blush streaks on cheeks
    blush = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blush)
    bd.ellipse([362, 358, 434, 396], fill=(255, 110, 145, 95))
    bd.ellipse([562, 358, 634, 396], fill=(255, 110, 145, 95))
    blush = blush.filter(ImageFilter.GaussianBlur(radius=10))
    canvas.alpha_composite(blush)

    # 4) Crisp anime 💢 anger marks (positioned clear of her iridescent star hairpin)
    draw_anger_mark(canvas, 742, 224, size=46, angle_deg=-12)
    draw_anger_mark(canvas, 266, 254, size=32, angle_deg=14)

    # 5) Dynamic cel-shaded pink-purple anime anger sparks around her raised paws & ears
    sparks = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sparks)
    # Left lightning bolt
    draw_spark_bolt(
        sd,
        [(182, 326), (222, 356), (204, 368), (242, 404), (192, 382), (206, 366)],
        fill=(255, 118, 178, 255),
        outline=OUTLINE,
        width=5,
    )
    # Right lightning bolt
    draw_spark_bolt(
        sd,
        [(836, 320), (792, 354), (810, 366), (772, 404), (824, 380), (808, 364)],
        fill=(255, 118, 178, 255),
        outline=OUTLINE,
        width=5,
    )
    # Top cute spiky exclamation/spark puffs
    draw_four_star(sd, 240, 210, 24, 9, fill=(255, 185, 220, 255), outline=OUTLINE, width=4)
    draw_four_star(sd, 764, 218, 20, 8, fill=(255, 215, 130, 255), outline=OUTLINE, width=4)
    canvas.alpha_composite(sparks)

    return canvas.resize((512, 512), Image.Resampling.LANCZOS)


def build_sleep(idle_img: Image.Image, happy_img: Image.Image) -> Image.Image:
    """
    Create 'sleep' (犯困打盹) sprite:
    - Seamlessly grafts idle's clean cat ear & forehead onto happy to remove the petting hand
    - Removes floating hearts/stars around head
    - Adds dreamy starry lavender cloud cushion, translucent anime sleep bubble, and cel-shaded Zzz!
    """
    idle_arr = np.array(idle_img, dtype=np.float32)
    happy_arr = np.array(happy_img, dtype=np.float32)

    # Align idle's upper-right ear/hair crown to happy's to compute exact (dx, dy) offset
    # Right ear region in happy is roughly x in [255..335], y in [30..105]
    best_score = -1e18
    best_shift = (0, 0)
    ref_patch = happy_arr[35:105, 258:332, :3]
    ref_alpha = happy_arr[35:105, 258:332, 3] > 128
    for dy in range(-10, 11):
        for dx in range(-14, 15):
            y0, y1 = 35 - dy, 105 - dy
            x0, x1 = 258 - dx, 332 - dx
            cand = idle_arr[y0:y1, x0:x1, :3]
            diff = np.abs(cand - ref_patch).mean(axis=2)
            score = -diff[ref_alpha].mean()
            if score > best_score:
                best_score = score
                best_shift = (dx, dy)

    dx, dy = best_shift
    print(f"[sleep] Aligned idle->happy head shift: dx={dx}, dy={dy}")

    # Shift idle image by (dx, dy)
    shifted_idle = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    shifted_idle.alpha_composite(idle_img, (dx, dy))
    s_arr = np.array(shifted_idle, dtype=np.float32)

    # Build smooth elliptical mask covering ONLY the petting hand area (x: 146..268, y: 40..106)
    yy, xx = np.mgrid[0:512, 0:512]
    # Hand sits roughly in x in [148..264], y in [44..106]
    # Also include the cat ear top behind the hand so it comes cleanly from idle!
    hand_mask = np.zeros((512, 512), dtype=np.float32)
    # Generous region over left ear + forehead top where the hand overlaps
    in_box = (xx >= 144) & (xx <= 262) & (yy >= 30) & (yy <= 102)
    hand_mask[in_box] = 1.0
    # Smooth feathered edge so hair merges invisibly
    mask_img = Image.fromarray((hand_mask * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(radius=8))
    m = (np.array(mask_img, dtype=np.float32) / 255.0)[:, :, None]

    # Blend shifted idle over happy in the hand region
    blended = happy_arr * (1.0 - m) + s_arr * m

    # Cleanly remove the floating pink hearts & yellow sparkles on left/right of happy's head
    # Left floating hearts: x < 166, y in [95..180]; Right floating hearts: x > 346, y in [95..180]
    blended[95:185, 110:166, 3] = 0
    blended[95:185, 346:405, 3] = 0
    blended[blended[:, :, 3] < 4] = 0

    base_sleep = Image.fromarray(np.clip(blended, 0, 255).astype(np.uint8), "RGBA")

    # Supersample to 1024 for dreamy cloud cushion + sleep bubble + Zzz!
    S = 1024
    char_hi = base_sleep.resize((S, S), Image.Resampling.LANCZOS)

    # Soft dreamy twilight tint (very subtle 5% lavender-blue cozy vibe)
    ca = np.array(char_hi, dtype=np.float32)
    ca[:, :, 0] *= 0.96
    ca[:, :, 1] *= 0.96
    ca[:, :, 2] = np.minimum(255.0, ca[:, :, 2] * 1.03)
    char_hi = Image.fromarray(ca.astype(np.uint8), "RGBA")

    # 1) Fluffy pastel lavender-blue starry cloud cushion behind her lower legs
    bg_cloud = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cd = ImageDraw.Draw(bg_cloud)
    # Soft glow behind cloud
    cglow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cgd = ImageDraw.Draw(cglow)
    cgd.ellipse([210, 660, 814, 960], fill=(155, 145, 255, 85))
    cglow = cglow.filter(ImageFilter.GaussianBlur(radius=36))
    bg_cloud.alpha_composite(cglow)

    # Cloud puffs (outer dark purple border first, then fluffy pastel fill)
    puffs = [
        (330, 800, 115, 84),
        (450, 770, 140, 100),
        (595, 778, 136, 96),
        (705, 810, 105, 78),
        (515, 845, 240, 86),
    ]
    for (cx, cy, rx, ry) in puffs:
        cd.ellipse([cx - rx - 6, cy - ry - 6, cx + rx + 6, cy + ry + 6], fill=(104, 88, 160, 220))
    for (cx, cy, rx, ry) in puffs:
        cd.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=(228, 222, 255, 240))
    # Soft lower lavender shadow on cloud
    cd.ellipse([300, 822, 745, 922], fill=(186, 174, 245, 160))
    # Tiny golden stars on cloud
    draw_four_star(cd, 326, 822, 18, 7, fill=(255, 224, 130, 255), outline=OUTLINE, width=3)
    draw_four_star(cd, 704, 834, 15, 6, fill=(255, 224, 130, 255), outline=OUTLINE, width=3)

    # Composite character on top of cloud cushion
    final = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    final.alpha_composite(bg_cloud)
    final.alpha_composite(char_hi)

    # 2) Cute shimmering anime sleep bubble near her face (1024: ~ (538, 356))
    fx = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fx)
    bx, by, br = 548, 366, 30
    fd.ellipse([bx - br, by - br, bx + br, by + br], fill=(190, 232, 255, 170), outline=(92, 135, 215, 235), width=5)
    # Glossy crescent highlight
    fd.ellipse([bx - 16, by - 18, bx - 2, by - 4], fill=(255, 255, 255, 230))
    fd.ellipse([bx + 6, by + 8, bx + 13, by + 15], fill=(255, 255, 255, 180))

    # 3) Crisp cel-shaded floating "Zzz" with dark-purple outlines
    font_paths = [
        "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    font_path = next((p for p in font_paths if Path(p).exists()), None)

    def draw_z(x, y, sz, color, tilt):
        zp = Image.new("RGBA", (sz * 2, sz * 2), (0, 0, 0, 0))
        zd = ImageDraw.Draw(zp)
        fnt = ImageFont.truetype(font_path, sz) if font_path else ImageFont.load_default()
        zd.text((sz // 2, sz // 3), "Z", font=fnt, fill=color, stroke_width=max(4, sz // 10), stroke_fill=OUTLINE)
        zp = zp.rotate(tilt, resample=Image.Resampling.BICUBIC, expand=True)
        fx.alpha_composite(zp, (int(x - zp.width / 2), int(y - zp.height / 2)))

    draw_z(706, 256, 52, (192, 220, 255, 255), -10)
    draw_z(766, 188, 70, (212, 192, 255, 255), -6)
    draw_z(836, 114, 90, (240, 198, 255, 255), -12)

    # Tiny sleepy crescent moon icon on left
    draw_four_star(fd, 252, 240, 22, 8, fill=(255, 232, 148, 255), outline=OUTLINE, width=4)
    draw_four_star(fd, 212, 312, 14, 5, fill=(195, 225, 255, 255), outline=OUTLINE, width=3)

    final.alpha_composite(fx)
    return final.resize((512, 512), Image.Resampling.LANCZOS)


def make_checkerboard(w: int, h: int, tile: int = 17) -> Image.Image:
    yy, xx = np.mgrid[0:h, 0:w]
    checker = ((xx // tile) + (yy // tile)) % 2
    c1 = np.array([236, 233, 248, 255], dtype=np.uint8)
    c2 = np.array([220, 216, 236, 255], dtype=np.uint8)
    bg = np.where(checker[:, :, None] == 0, c1, c2)
    return Image.fromarray(bg, "RGBA")


def main():
    idle_img = Image.open(SPRITES / "idle.png").convert("RGBA")
    happy_raw = Image.open(SPRITES / "happy.png").convert("RGBA")
    drag_img = Image.open(SPRITES / "drag.png").convert("RGBA")

    happy_img = feather_happy_wrist(happy_raw)
    working_img = build_working(idle_img)
    hiss_img = build_hiss(drag_img)
    sleep_img = build_sleep(idle_img, happy_raw)

    all_sprites = [
        ("idle", "待机卖萌 · Idle", idle_img),
        ("happy", "摸头开心 · Happy", happy_img),
        ("working", "认真干活 · Working", working_img),
        ("hiss", "哈气傲娇 · Hiss", hiss_img),
        ("sleep", "犯困打盹 · Sleep", sleep_img),
        ("drag", "被拎起来 · Drag", drag_img),
    ]

    STICKERS.mkdir(parents=True, exist_ok=True)
    for name, _, img in all_sprites:
        img.save(SPRITES / f"{name}.png")
        img.save(STICKERS / f"哈基米_{name}.png")
        print(f"[OK] Saved {name}.png & stickers/哈基米_{name}.png")

    # Build crisp 3x2 preview sheet with macOS PingFang Chinese font
    cols, rows, cell = 3, 2, 340
    sheet = make_checkerboard(cols * cell, rows * cell, tile=17)
    draw = ImageDraw.Draw(sheet)

    cn_fonts = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
    ]
    cn_font_path = next((p for p in cn_fonts if Path(p).exists()), None)
    label_font = ImageFont.truetype(cn_font_path, 16) if cn_font_path else ImageFont.load_default()

    for idx, (name, label, sp) in enumerate(all_sprites):
        r_idx = idx // cols
        c_idx = idx % cols
        thumb = sp.resize((300, 300), Image.Resampling.LANCZOS)
        sheet.alpha_composite(thumb, (c_idx * cell + 20, r_idx * cell + 8))
        draw.rounded_rectangle(
            [c_idx * cell + 14, r_idx * cell + 306, (c_idx + 1) * cell - 14, (r_idx + 1) * cell - 6],
            radius=10,
            fill=(38, 30, 72, 225),
        )
        draw.text((c_idx * cell + 28, r_idx * cell + 310), label, font=label_font, fill=(255, 255, 255, 255))

    preview_path = BASE / "sprites_preview.png"
    sheet.convert("RGB").save(preview_path)
    print(f"[OK] Saved 6-sprite preview -> {preview_path}")


if __name__ == "__main__":
    main()
