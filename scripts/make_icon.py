#!/usr/bin/env python3
"""Generate app icon for BRAW Transcoder"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math
import os

SIZE = 1024
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(PROJECT, "src", "app", "AppIcon.png")
ICONSET = os.path.join(PROJECT, "src", "app", "AppIcon.iconset")
ICNS = os.path.join(PROJECT, "src", "app", "AppIcon.icns")

# Colors
BG_TOP = (30, 30, 50)
BG_BOT = (18, 18, 32)
FILM_COLOR = (50, 50, 70)
ACCENT = (245, 166, 35)      # warm amber
ACCENT_DIM = (200, 130, 20)
SPROCKET = (22, 22, 38)
WHITE = (220, 220, 230)

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Rounded rect background (macOS icon shape)
margin = 80
r = SIZE // 5  # corner radius

# Background gradient
for y in range(SIZE):
    t = y / SIZE
    r_val = int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t)
    g_val = int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t)
    b_val = int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t)
    for x in range(SIZE):
        draw.point((x, y), fill=(r_val, g_val, b_val, 255))

# Create rounded rectangle mask
mask = Image.new("L", (SIZE, SIZE), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.rounded_rectangle(
    [margin, margin, SIZE - margin, SIZE - margin],
    radius=r, fill=255
)
img.putalpha(mask)

# Smooth the mask
mask = mask.filter(ImageFilter.GaussianBlur(radius=2))
img.putalpha(mask)

# Re-draw on clean canvas with mask
final = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
for y in range(SIZE):
    t = y / SIZE
    r_val = int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t)
    g_val = int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t)
    b_val = int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t)
    for x in range(SIZE):
        a = mask.getpixel((x, y))
        if a > 0:
            final.putpixel((x, y), (r_val, g_val, b_val, a))

img = final
draw = ImageDraw.Draw(img)

# ── Film strip outline ──────────────────────────
cw = SIZE // 2   # center
ch = SIZE // 2
fw = int(SIZE * 0.62)   # film width
fh = int(SIZE * 0.40)   # film height
fx = cw - fw // 2
fy = ch - fh // 2
corner = 28

# Film body
draw.rounded_rectangle(
    [fx, fy, fx + fw, fy + fh],
    radius=corner,
    fill=FILM_COLOR,
    outline=(70, 70, 95),
    width=4
)

# Sprocket holes
hole_w = 18
hole_h = 22
hole_margin = 28
hole_spacing = (fh - 2 * hole_margin) // 5

for side in [-1, 1]:
    hx = fx + fw//2 + side * (fw//2 - hole_margin)
    for i in range(5):
        hy = fy + hole_margin + i * hole_spacing + hole_h // 2
        draw.rounded_rectangle(
            [hx - hole_w//2, hy - hole_h//2, hx + hole_w//2, hy + hole_h//2],
            radius=hole_w//3,
            fill=SPROCKET
        )

# ── Central frame symbol ──────────────────────
frame_w = int(fw * 0.38)
frame_h = int(fh * 0.55)
frame_x = cw - frame_w // 2
frame_y = ch - frame_h // 2

# Inner frame (image area)
draw.rectangle(
    [frame_x, frame_y, frame_x + frame_w, frame_y + frame_h],
    fill=(20, 20, 32),
    outline=ACCENT,
    width=5
)

# Play triangle in the center of the frame
tri_cx = cw
tri_cy = ch
tri_size = int(frame_h * 0.35)
tri = [
    (tri_cx - tri_size // 3, tri_cy - tri_size // 2),
    (tri_cx - tri_size // 3, tri_cy + tri_size // 2),
    (tri_cx + tri_size * 2 // 3, tri_cy),
]
draw.polygon(tri, fill=ACCENT)

# ── Subtle bottom glow line ────────────────────
glow_y = fy + fh + 30
for i in range(80):
    alpha = int(80 * (1 - i / 80))
    y = glow_y + i
    x0 = cw - 120 + i // 2
    x1 = cw + 120 - i // 2
    if x0 < x1:
        draw.line([(x0, y), (x1, y)], fill=(*ACCENT, alpha), width=2)

# ── Save ───────────────────────────────────────
img.save(OUT, "PNG")
print(f"Saved: {OUT}")

# ── Generate iconset ───────────────────────────
os.makedirs(ICONSET, exist_ok=True)

sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

for name, size in sizes.items():
    resized = img.resize((size, size), Image.LANCZOS)
    resized.save(os.path.join(ICONSET, name), "PNG")

print(f"Iconset created: {ICONSET}")

# Generate .icns
import subprocess
subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
print(f"ICNS created: {ICNS}")
