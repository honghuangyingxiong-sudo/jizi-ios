#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
把碑帖扫描页切成单字。

针对「黑底白字」的拓本：
  1. 先找页面上的拓本块（大面积的暗区）
  2. 块内按列投影切列，列内按行投影切字
  3. 输出单字 PNG（白底黑字，方便集字时直接排版）
  4. 同时输出一张带框的标注图，用来肉眼核对切得对不对

用法：
    python segment_calligraphy.py --in "D:\字源\..." --out "D:\字库" --annotate
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

# ---------- 参数 ----------
RUBBING_DARK = 110      # 低于这个灰度算「拓本底」
INK_BRIGHT = 150        # 高于这个灰度算「字」（黑底白字里的字）
MIN_BLOCK_FRAC = 0.04   # 拓本块至少占页面这么多面积
COL_INK_FRAC = 0.008    # 一列里白点占比低于此值算空白列
ROW_INK_FRAC = 0.010    # 一行里白点占比低于此值算空白行
MIN_CHAR_FRAC = 0.020   # 单字最小边长（相对块高）
MAX_SEAL_FRAC = 0.75    # 红色像素占比超过这个，判为印章，丢弃


def load_gray(path):
    return np.array(Image.open(path).convert("L"))


def load_rgb(path):
    return np.array(Image.open(path).convert("RGB"))


def runs(mask, min_gap):
    """把布尔序列切成若干连续 True 的区间。"""
    out, start, gap = [], None, 0
    for i, v in enumerate(mask):
        if v:
            if start is None:
                start = i
            gap = 0
        elif start is not None:
            gap += 1
            if gap >= min_gap:
                out.append((start, i - gap + 1))
                start, gap = None, 0
    if start is not None:
        out.append((start, len(mask)))
    return [r for r in out if r[1] > r[0]]


def find_rubbing_blocks(gray):
    """找出页面上所有拓本块（暗区）的边界框。"""
    h, w = gray.shape
    dark = gray < RUBBING_DARK

    # 行方向：找出暗像素够多的行段
    row_ok = dark.sum(axis=1) > w * 0.10
    rows = runs(row_ok, max(3, int(h * 0.02)))

    blocks = []
    for y0, y1 in rows:
        band = dark[y0:y1, :]
        bh = y1 - y0
        if bh < h * 0.10:
            continue
        # 列方向：在行段内找暗像素够多的列段
        col_ok = band.sum(axis=0) > bh * 0.30
        cols = runs(col_ok, max(3, int(w * 0.015)))
        for x0, x1 in cols:
            bw = x1 - x0
            if bw < w * 0.08 or bh < h * 0.10:
                continue
            if bw * bh < gray.size * MIN_BLOCK_FRAC:
                continue
            blocks.append((x0, y0, x1, y1))

    # 合并重叠/贴得很近的块
    merged = []
    for b in sorted(blocks, key=lambda t: -((t[2]-t[0]) * (t[3]-t[1]))):
        for m in merged:
            if not (b[2] < m[0] - 10 or b[0] > m[2] + 10 or b[3] < m[1] - 10 or b[1] > m[3] + 10):
                m[0] = min(m[0], b[0]); m[1] = min(m[1], b[1])
                m[2] = max(m[2], b[2]); m[3] = max(m[3], b[3])
                break
        else:
            merged.append(list(b))
    return [tuple(m) for m in merged]


def segment_block(gray, rgb, box):
    """在拓本块内切出单字，返回 [(x, y, w, h)]。"""
    x0, y0, x1, y1 = box
    sub = gray[y0:y1, x0:x1]
    subrgb = rgb[y0:y1, x0:x1]
    bh, bw = sub.shape

    # 块内：字是亮的
    ink = sub > INK_BRIGHT
    # 红色印章像素：R 明显大于 G 和 B
    r = subrgb[:, :, 0].astype(int)
    g = subrgb[:, :, 1].astype(int)
    b = subrgb[:, :, 2].astype(int)
    reddish = (r - np.maximum(g, b)) > 40

    col_ok = ink.sum(axis=0) > bh * COL_INK_FRAC
    col_gap = max(2, int(bw * 0.012))
    cols = runs(col_ok, col_gap)

    chars = []
    for cx0, cx1 in cols:
        cw = cx1 - cx0
        if cw < bw * 0.02:
            continue
        col = ink[:, cx0:cx1]
        row_ok = col.sum(axis=1) > cw * ROW_INK_FRAC
        row_gap = max(2, int(bh * 0.008))
        rows = runs(row_ok, row_gap)
        for ry0, ry1 in rows:
            ch = ry1 - ry0
            if ch < bh * MIN_CHAR_FRAC:
                continue
            # 收紧到真实墨迹
            patch = ink[ry0:ry1, cx0:cx1]
            ys, xs = np.where(patch)
            if len(xs) == 0:
                continue
            nx0, nx1 = cx0 + xs.min(), cx0 + xs.max() + 1
            ny0, ny1 = ry0 + ys.min(), ry0 + ys.max() + 1

            # 印章检测：这块里红色像素占比太高就扔掉
            p = subrgb[ny0:ny1, nx0:nx1]
            if p.size:
                pr = p[:, :, 0].astype(int)
                pg = p[:, :, 1].astype(int)
                pb = p[:, :, 2].astype(int)
                red_frac = (((pr - np.maximum(pg, pb)) > 40).sum()) / (p.shape[0] * p.shape[1])
                if red_frac > MAX_SEAL_FRAC:
                    continue

            chars.append((x0 + nx0, y0 + ny0, nx1 - nx0, ny1 - ny0))
    return chars


def refine(chars, verbose=False):
    """
    按整页的中位数尺寸做一次清理：
      - 太小的丢掉（碎屑、印章里的字）
      - 长宽比离谱的丢掉（横线、竖线）
      - 明显比一个字高的，判为两三个字粘在一起，等分拆开
      - 墨迹太稀的丢掉（基本是空白）
    """
    if len(chars) < 6:
        return chars

    ws = np.array([c[2] for c in chars], dtype=float)
    hs = np.array([c[3] for c in chars], dtype=float)
    med_w = float(np.median(ws))
    med_h = float(np.median(hs))

    kept, split_off, tiny, shape = [], 0, 0, 0
    for c in chars:
        x, y, w, h = c
        if w < med_w * 0.45 or h < med_h * 0.45:
            tiny += 1
            continue
        ar = w / float(h)
        if ar < 0.34 or ar > 2.30:
            shape += 1
            continue
        n = int(round(h / med_h))
        if n >= 2 and h > med_h * 1.55:
            step = h / float(n)
            for i in range(n):
                kept.append((x, int(y + i * step), w, int(step)))
            split_off += 1
        else:
            kept.append(c)

    if verbose:
        print("    清理: 丢碎屑 %d, 丢畸形 %d, 拆开粘连 %d, 剩 %d"
              % (tiny, shape, split_off, len(kept)))
    return kept


def crop_char(gray, box, pad_frac=0.06, size=512):
    """裁字并转成白底黑字的正方形图。"""
    x, y, w, h = box
    pad = int(max(w, h) * pad_frac)
    gx0, gy0 = max(0, x - pad), max(0, y - pad)
    gx1, gy1 = min(gray.shape[1], x + w + pad), min(gray.shape[0], y + h + pad)
    sub = gray[gy0:gy1, gx0:gx1].astype(np.float32)

    # 拓本：反相，让字变黑、底变白
    sub = 255.0 - sub
    lo, hi = sub.min(), sub.max()
    if hi - lo > 1:
        sub = (sub - lo) / (hi - lo) * 255.0

    im = Image.fromarray(sub.astype(np.uint8), mode="L").convert("RGBA")
    # 四周留白，居中放进正方形
    target = size
    scale = min((target * 0.92) / im.width, (target * 0.92) / im.height)
    nw, nh = max(1, int(im.width * scale)), max(1, int(im.height * scale))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (target, target), (255, 255, 255, 255))
    canvas.paste(im, ((target - nw) // 2, (target - nh) // 2))
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True, help="输入图片或目录")
    ap.add_argument("--out", required=True, help="输出目录")
    ap.add_argument("--annotate", action="store_true", help="同时输出带框标注图")
    ap.add_argument("--min-chars", type=int, default=4, help="一页少于这么多字就跳过")
    args = ap.parse_args()

    if os.path.isdir(args.src):
        files = sorted(
            os.path.join(args.src, f) for f in os.listdir(args.src)
            if f.lower().endswith((".jpg", ".jpeg", ".png", ".tif", ".tiff"))
        )
    else:
        files = [args.src]

    os.makedirs(args.out, exist_ok=True)
    if args.annotate:
        os.makedirs(os.path.join(args.out, "_标注"), exist_ok=True)

    total = 0
    index = []
    for path in files:
        name = os.path.splitext(os.path.basename(path))[0]
        gray = load_gray(path)
        rgb = load_rgb(path)
        blocks = find_rubbing_blocks(gray)
        print("%s  ->  %d 个拓本块" % (os.path.basename(path), len(blocks)))

        page_chars = []
        for bi, b in enumerate(blocks):
            cs = segment_block(gray, rgb, b)
            print("    块%d %s  切出 %d 字" % (bi + 1, str(b), len(cs)))
            page_chars.extend(cs)

        page_chars = refine(page_chars, verbose=True)

        if len(page_chars) < args.min_chars:
            print("    字太少，跳过")
            continue

        for i, c in enumerate(page_chars):
            im = crop_char(gray, c)
            fn = "%s_%02d.png" % (name.replace(" ", "_"), i + 1)
            im.save(os.path.join(args.out, fn))
            index.append({"file": fn, "source": path, "box": [int(v) for v in c]})
        total += len(page_chars)

        if args.annotate:
            vis = Image.open(path).convert("RGB")
            d = ImageDraw.Draw(vis)
            for b in blocks:
                d.rectangle(b, outline=(0, 200, 0), width=4)
            for c in page_chars:
                d.rectangle((c[0], c[1], c[0] + c[2], c[1] + c[3]), outline=(255, 0, 0), width=3)
            vis.save(os.path.join(args.out, "_标注", name + "_标注.png"))

    with open(os.path.join(args.out, "_index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
    print("")
    print("共切出 %d 个字 -> %s" % (total, args.out))


if __name__ == "__main__":
    main()
