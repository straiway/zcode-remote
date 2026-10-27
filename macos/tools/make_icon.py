"""生成 macOS 应用图标：深色圆角底 + 白色 Z + 右下角屏幕射线角标，输出 AppIcon.icns。

遵循 Apple macOS 图标模板：1024 画布内放 824×824 的圆角方块（四周留白 100），
圆角半径 185，并带柔和投影。角标用于与官方 ZCode 客户端图标视觉区分。
"""
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "build" / "AppIcon.iconset"

S = 1024
MARGIN = 100
SQUARE = S - 2 * MARGIN  # 824
RADIUS = 185

base = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# 投影层
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle(
    [MARGIN, MARGIN + 12, MARGIN + SQUARE - 1, MARGIN + SQUARE + 11],
    radius=RADIUS, fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(22))
base.alpha_composite(shadow)

# 图标主体
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
td = ImageDraw.Draw(tile)
td.rounded_rectangle(
    [MARGIN, MARGIN, MARGIN + SQUARE - 1, MARGIN + SQUARE - 1],
    radius=RADIUS, fill=(26, 28, 34, 255))

# 白色 Z（与安卓 ic_launcher_foreground 同一形状），在整块图标内上下左右居中
zw, zh = int(SQUARE * 0.55), int(SQUARE * 0.44)
zx0, zy0 = (S - zw) / 2, (S - zh) / 2
sx, sy = zw / 40, zh / 32
pts = [(34, 38), (74, 38), (74, 46.5), (48.5, 61.5), (74, 61.5),
       (74, 70), (34, 70), (34, 61.5), (59.5, 46.5), (34, 46.5)]
poly = [(zx0 + (px - 34) * sx, zy0 + (py - 38) * sy) for px, py in pts]
td.polygon(poly, fill=(255, 255, 255, 255))

# 右下角屏幕射线角标：小显示器 + 信号波纹，遥控的隐喻。
# 角标缩小后收进底板右下角圆角内，与居中的 Z 保持间距、不遮挡。
badge_inset = 130  # 角标圆心距底板右/下边缘的距离
badge_center = (MARGIN + SQUARE - badge_inset, MARGIN + SQUARE - badge_inset)
badge_r = SQUARE * 0.113  # 角标整体半径
# 白色衬底圆（把角标和底色区分开）
td.ellipse(
    [badge_center[0] - badge_r, badge_center[1] - badge_r,
     badge_center[0] + badge_r, badge_center[1] + badge_r],
    fill=(255, 255, 255, 255))
# 显示器主体（深色），带圆角
m_w, m_h = badge_r * 1.02, badge_r * 0.74
mx, my = badge_center[0] - m_w / 2, badge_center[1] - m_h / 2 - badge_r * 0.12
td.rounded_rectangle([mx, my, mx + m_w, my + m_h], radius=badge_r * 0.14, fill=(26, 28, 34, 255))
# 显示器支架
td.rectangle(
    [badge_center[0] - badge_r * 0.08, my + m_h,
     badge_center[0] + badge_r * 0.08, my + m_h + badge_r * 0.16],
    fill=(26, 28, 34, 255))
# 底座
td.rounded_rectangle(
    [badge_center[0] - badge_r * 0.3, my + m_h + badge_r * 0.16,
     badge_center[0] + badge_r * 0.3, my + m_h + badge_r * 0.28],
    radius=badge_r * 0.05, fill=(26, 28, 34, 255))
# 屏幕上的信号波纹：三段同心弧
arc_c = (badge_center[0] - badge_r * 0.22, my + m_h * 0.78)
for i, r in enumerate((badge_r * 0.10, badge_r * 0.19, badge_r * 0.28)):
    alpha = 255 - i * 55
    arc_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arc_layer)
    bbox = [arc_c[0] - r, arc_c[1] - r, arc_c[0] + r, arc_c[1] + r]
    ad.arc(bbox, start=270, end=360, fill=(255, 255, 255, alpha), width=max(3, int(badge_r * 0.07)))
    tile.alpha_composite(arc_layer)
# 信号原点
dot_r = badge_r * 0.055
td.ellipse(
    [arc_c[0] - dot_r, arc_c[1] - dot_r, arc_c[0] + dot_r, arc_c[1] + dot_r],
    fill=(255, 255, 255, 255))

base.alpha_composite(tile)

ICONSET.mkdir(parents=True, exist_ok=True)
base.save(ICONSET / "icon_512x512@2x.png")
for size in (16, 32, 128, 256, 512):
    base.resize((size, size), Image.LANCZOS).save(ICONSET / f"icon_{size}x{size}.png")
    base.resize((size * 2, size * 2), Image.LANCZOS).save(ICONSET / f"icon_{size}x{size}@2x.png")

out = ROOT / "build" / "AppIcon.icns"
subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(out)], check=True)
print(f"icon written: {out}")
sys.exit(0)
