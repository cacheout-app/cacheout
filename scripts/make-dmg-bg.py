#!/usr/bin/env python3
"""Generate polished DMG background for Cacheout installer (660x400 @2x = 1320x800)."""
from PIL import Image, ImageDraw, ImageFont
import math, os

W, H = 1320, 800
img = Image.new("RGBA", (W, H), (0, 0, 0, 255))
draw = ImageDraw.Draw(img)

# Dark navy gradient background
for y in range(H):
    t = y / H
    r = int(18 + t * 12)
    g = int(22 + t * 14)
    b = int(32 + t * 18)
    draw.line([(0, y), (W, y)], fill=(r, g, b, 255))

# Subtle radial glow behind center
for radius in range(400, 0, -1):
    alpha = int(18 * (1 - radius / 400) ** 2)
    rc = int(100 + 60 * (1 - radius / 400))
    gc = int(120 + 80 * (1 - radius / 400))
    bc = int(180 + 75 * (1 - radius / 400))
    cx, cy = W // 2, H // 2 - 30
    draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius],
                 fill=(rc, gc, bc, alpha))

# Arrow from app icon (x=330) to Applications (x=990) at y=390
arrow_y = 390
for t_step in range(200):
    t = t_step / 199
    x = int(480 + t * 360)
    y_off = int(math.sin(t * math.pi) * -8)
    alpha = int(80 + 40 * math.sin(t * math.pi))
    for dy in range(-2, 3):
        draw.point((x, arrow_y + y_off + dy), fill=(180, 195, 240, alpha))

# Arrowhead
for i in range(20):
    for dy in range(-i, i + 1):
        draw.point((840 - i, arrow_y + dy), fill=(180, 195, 240, max(20, 80 - i * 3)))

# Try to find a nice font
font_large = font_small = None
font_paths = [
    "/System/Library/Fonts/SFNSDisplay.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
]
for fp in font_paths:
    if os.path.exists(fp):
        try:
            font_large = ImageFont.truetype(fp, 28)
            font_small = ImageFont.truetype(fp, 20)
            break
        except: pass
if not font_large:
    font_large = ImageFont.load_default()
    font_small = ImageFont.load_default()

# Labels under icon positions
for label, lx in [("Cacheout", 330), ("Applications", 990)]:
    bb = draw.textbbox((0, 0), label, font=font_small)
    draw.text((lx - (bb[2] - bb[0]) // 2, 480), label, fill=(200, 210, 240, 160), font=font_small)

# Bottom text
for text, font, y, alpha in [
    ("Drag Cacheout to Applications", font_large, 620, 200),
    ("Free up disk space on your Mac", font_small, 665, 150),
]:
    bb = draw.textbbox((0, 0), text, font=font)
    draw.text(((W - (bb[2] - bb[0])) // 2, y), text, fill=(160, 175, 210, alpha), font=font)

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources", "DMG", "background.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
img.save(out)
print(f"Created {W}x{H} → {out}")
