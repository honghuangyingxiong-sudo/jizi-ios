# -*- coding: utf-8 -*-
r"""把切出来的单字拼成一张索引图，用来肉眼验收。"""
import os, sys, json
from PIL import Image, ImageDraw, ImageFont

src = r"C:\Users\XIAOCAI\Documents\字库试切"
files = sorted(f for f in os.listdir(src) if f.endswith(".png"))
print("单字文件数:", len(files))

CELL, PAD = 150, 6
COLS = 8
rows = (len(files) + COLS - 1) // COLS
sheet = Image.new("RGB", (COLS * (CELL + PAD) + PAD, rows * (CELL + PAD + 18) + PAD), (235, 235, 235))
d = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("msyh.ttc", 13)
except Exception:
    font = ImageFont.load_default()

for i, f in enumerate(files):
    im = Image.open(os.path.join(src, f)).convert("RGB").resize((CELL, CELL), Image.LANCZOS)
    c, r = i % COLS, i // COLS
    x = PAD + c * (CELL + PAD)
    y = PAD + r * (CELL + PAD + 18)
    d.rectangle((x, y, x + CELL, y + CELL), fill=(255, 255, 255))
    sheet.paste(im, (x, y))
    d.text((x + 2, y + CELL + 2), str(i + 1), fill=(0, 0, 0), font=font)

out = os.path.join(src, "_索引图.png")
sheet.save(out)
print("已存:", out, sheet.size)
