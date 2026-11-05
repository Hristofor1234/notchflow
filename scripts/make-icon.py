#!/usr/bin/env python3
"""Делает Resources/AppIcon.icns из design/icon/logo-original.png.

Вырезает тело значка из исходника, вписывает его в сетку значков macOS
(824×824 на холсте 1024, скругление 185) с прозрачными углами и собирает .icns через iconutil.
"""
import os, subprocess, shutil, tempfile
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "design/icon/logo-original.png")
MASTER = os.path.join(ROOT, "design/icon/AppIcon-1024.png")
ICNS = os.path.join(ROOT, "Resources/AppIcon.icns")

CROP = (30, 52, 994, 1016)   # тело значка в исходнике 1024×1024
BODY, CANVAS, RADIUS, SS = 824, 1024, 185, 4

body = Image.open(SRC).convert("RGB").crop(CROP).resize((BODY, BODY), Image.LANCZOS)
mask = Image.new("L", (BODY * SS, BODY * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, BODY * SS - 1, BODY * SS - 1), RADIUS * SS, fill=255)
mask = mask.resize((BODY, BODY), Image.LANCZOS)
icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
off = (CANVAS - BODY) // 2
icon.paste(body, (off, off), mask)
icon.save(MASTER)

tmp = tempfile.mkdtemp()
iconset = os.path.join(tmp, "AppIcon.iconset")
os.mkdir(iconset)
for s in (16, 32, 128, 256, 512):
    icon.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
    icon.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", ICNS], check=True)
shutil.rmtree(tmp)
print("Готово:", ICNS)
