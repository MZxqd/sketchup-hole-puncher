import os
import re
import zipfile
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(ROOT, "src")
ICON_DIR = os.path.join(SRC_DIR, "cyl_hole_puncher", "icons")
DIST_DIR = os.path.join(ROOT, "dist")
RBZ_PATH = os.path.join(DIST_DIR, "cyl_hole_puncher.rbz")


def generate_icons():
    os.makedirs(ICON_DIR, exist_ok=True)
    S = 256  # 4x supersampling -> resize to 64x64

    # 1. side_hole.png: 圆柱侧面下方打洞图标
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # 圆柱主体
    d.rounded_rectangle([54, 34, 202, 222], radius=24, fill=(235, 242, 250, 255), outline=(45, 75, 115, 255), width=12)
    # 顶部椭圆
    d.ellipse([54, 20, 202, 66], fill=(205, 222, 242, 255), outline=(45, 75, 115, 255), width=12)
    # 底部弧线强调
    d.arc([54, 194, 202, 234], start=0, end=180, fill=(45, 75, 115, 255), width=12)
    # 下方三个红色圆孔
    for cx in (92, 128, 164):
        r = 16 if cx == 128 else 12
        d.ellipse([cx - r, 168 - r, cx + r, 168 + r], fill=(225, 65, 65, 255), outline=(145, 25, 25, 255), width=6)
    img.resize((64, 64), Image.LANCZOS).save(os.path.join(ICON_DIR, "side_hole.png"))

    # 2. bottom_hole.png: 圆柱底面多孔图标
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([26, 26, 230, 230], fill=(235, 242, 250, 255), outline=(45, 75, 115, 255), width=14)
    # 分布圆虚线效果（淡蓝圈）
    d.ellipse([66, 66, 190, 190], outline=(140, 175, 215, 255), width=6)
    # 四个对称孔
    for (cx, cy) in [(128, 66), (190, 128), (128, 190), (66, 128)]:
        r = 19
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(225, 65, 65, 255), outline=(145, 25, 25, 255), width=6)
    # 中心小点
    d.ellipse([119, 119, 137, 137], fill=(45, 75, 115, 255))
    img.resize((64, 64), Image.LANCZOS).save(os.path.join(ICON_DIR, "bottom_hole.png"))

    # 3. click_hole.png: 点哪打哪（准星+红孔）
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # 外靶环
    d.ellipse([40, 40, 216, 216], fill=(255, 242, 242, 255), outline=(225, 65, 65, 255), width=14)
    # 中心孔
    d.ellipse([96, 96, 160, 160], fill=(225, 65, 65, 255), outline=(145, 25, 25, 255), width=6)
    # 十字准星线
    d.line([128, 16, 128, 72], fill=(45, 75, 115, 255), width=12)
    d.line([128, 184, 128, 240], fill=(45, 75, 115, 255), width=12)
    d.line([16, 128, 72, 128], fill=(45, 75, 115, 255), width=12)
    d.line([184, 128, 240, 128], fill=(45, 75, 115, 255), width=12)
    img.resize((64, 64), Image.LANCZOS).save(os.path.join(ICON_DIR, "click_hole.png"))


def check_ruby_files():
    for dirpath, _, filenames in os.walk(SRC_DIR):
        for fn in filenames:
            if not fn.endswith(".rb"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, "r", encoding="utf-8").read()
            # 简单检查括号匹配
            pairs = {"(": ")", "[": "]", "{": "}"}
            stack = []
            in_str = None
            escaped = False
            for line_no, raw_line in enumerate(text.splitlines(), 1):
                line = raw_line.strip()
                if line.startswith("#"):
                    continue
                for ch in raw_line:
                    if escaped:
                        escaped = False
                        continue
                    if ch == "\\" and in_str:
                        escaped = True
                        continue
                    if in_str:
                        if ch == in_str:
                            in_str = None
                        continue
                    if ch in ("'", '"'):
                        in_str = ch
                    elif ch == "#":
                        break
                    elif ch in pairs:
                        stack.append((ch, line_no))
                    elif ch in pairs.values():
                        if not stack or pairs[stack[-1][0]] != ch:
                            raise SyntaxError(f"Mismatched {ch} in {path}:{line_no}")
                        stack.pop()
            if stack:
                raise SyntaxError(f"Unclosed {stack[-1]} in {path}")
            print(f"OK (brackets/UTF-8): {os.path.relpath(path, ROOT)}")


def build_rbz():
    os.makedirs(DIST_DIR, exist_ok=True)
    with zipfile.ZipFile(RBZ_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
        for dirpath, _, filenames in os.walk(SRC_DIR):
            for fn in sorted(filenames):
                full_path = os.path.join(dirpath, fn)
                arc_name = os.path.relpath(full_path, SRC_DIR).replace("\\", "/")
                zf.write(full_path, arc_name)
                print(f"  + {arc_name}")
    print(f"\nBuilt: {RBZ_PATH} ({os.path.getsize(RBZ_PATH)} bytes)")


if __name__ == "__main__":
    generate_icons()
    check_ruby_files()
    build_rbz()
