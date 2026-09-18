#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
从 Wikimedia Commons 抓公有领域的中国碑帖扫描件。

用【分类枚举】而不是全文搜索 —— 搜索会把民国丛书里带「碑」字的书也捞进来。
每个文件都带回 LicenseShortName，非自由授权的直接跳过并打印出来。

用法：
    python fetch_calligraphy.py --out "D:\字源"                 # 抓默认分类
    python fetch_calligraphy.py --out "D:\字源" --cat "Category:宋拓九成宫醴泉铭册"
    python fetch_calligraphy.py --list-cats                     # 只看有哪些分类内容
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import urlparse

API = "https://commons.wikimedia.org/w/api.php"
UA = ("JiZi-Calligraphy-Builder/1.0 "
      "(personal offline calligraphy project; python-urllib)")

# 认可的自由授权（小写子串匹配）
OK_LICENSES = ("public domain", "cc0", "pd-", "cc-by", "cc by", "cc-by-sa", "cc by-sa")

# 体积上限，防止把整本丛书扫描件拖下来
MAX_BYTES = 40 * 1024 * 1024

# 默认抓这些分类（都核实过存在）
DEFAULT_CATS = [
    "Category:宋拓九成宫醴泉铭册",              # 欧阳询 楷书，PD-Art
    "Category:Calligraphy of the Southern and Northern Dynasties",
    "Category:Rubbings of inscriptions on Chinese monumental stones",
]


def api(params, retries=5):
    params = dict(params)
    params["format"] = "json"
    url = API + "?" + urllib.parse.urlencode(params)
    delay = 2.0
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and attempt < retries - 1:
                print("    HTTP %d，等 %.0fs 重试" % (e.code, delay))
                time.sleep(delay)
                delay *= 2
                continue
            raise
    raise RuntimeError("api 重试耗尽")


def cat_members(cat, limit=200, depth=1, _seen=None):
    """枚举分类下的文件（含一层子分类）。返回 title 列表。"""
    if _seen is None:
        _seen = set()
    if cat in _seen or depth < 0:
        return []
    _seen.add(cat)

    titles = []
    cont = None
    while True:
        p = {
            "action": "query", "list": "categorymembers",
            "cmtitle": cat, "cmlimit": "500", "cmtype": "file|subcat",
        }
        if cont:
            p["cmcontinue"] = cont
        j = api(p)
        for m in (j.get("query") or {}).get("categorymembers") or []:
            if m["title"].startswith("File:"):
                titles.append(m["title"])
            elif depth > 0 and m["title"].startswith("Category:"):
                titles.extend(cat_members(m["title"], limit, depth - 1, _seen))
        cont = (j.get("continue") or {}).get("cmcontinue")
        if not cont or len(titles) >= limit:
            break
        time.sleep(0.4)
    return titles[:limit]


def imageinfo(titles):
    """批量取 url / 尺寸 / 授权。"""
    out = {}
    for i in range(0, len(titles), 40):
        chunk = titles[i:i + 40]
        j = api({
            "action": "query",
            "titles": "|".join(chunk),
            "prop": "imageinfo",
            "iiprop": "url|size|extmetadata",
        })
        for p in ((j.get("query") or {}).get("pages") or {}).values():
            ii = (p.get("imageinfo") or [{}])[0]
            if not ii.get("url"):
                continue
            md = ii.get("extmetadata") or {}
            artist = (md.get("Artist", {}).get("value") or "")
            if "<" in artist:
                artist = artist.split("<")[0]
            out[p.get("title")] = {
                "url": ii["url"],
                "width": ii.get("width", 0),
                "height": ii.get("height", 0),
                "license": (md.get("LicenseShortName", {}).get("value") or "?"),
                "artist": artist.strip()[:70],
                "size": ii.get("size", 0),
            }
        time.sleep(0.4)
    return out


def is_ok(lic):
    low = lic.lower()
    return any(k in low for k in OK_LICENSES)


def ext_of(url):
    """从 URL 路径取扩展名（先砍掉 ?query，否则会拿到 .org&utm_... 这种东西）。"""
    path = urlparse(url).path
    ext = os.path.splitext(path)[1].lower()
    if ext not in (".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"):
        ext = ".jpg"
    return ext


def download(url, dest, retries=5):
    delay = 3.0
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=180) as r, open(dest, "wb") as f:
                while True:
                    chunk = r.read(65536)
                    if not chunk:
                        break
                    f.write(chunk)
            return True
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and attempt < retries - 1:
                print("      限流 %d，等 %.0fs" % (e.code, delay))
                time.sleep(delay)
                delay *= 2
                continue
            print("      失败 HTTP %d" % e.code)
            return False
        except Exception as e:
            print("      失败 %s" % e)
            return False
    return False


def safe(name):
    for ch in '\\/:*?"<>|':
        name = name.replace(ch, "_")
    return name.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="输出根目录")
    ap.add_argument("--cat", action="append", default=None, help="分类名，可重复")
    ap.add_argument("--per-cat", type=int, default=30, help="每个分类最多下几张")
    ap.add_argument("--min-side", type=int, default=1000, help="最短边下限")
    ap.add_argument("--list-cats", action="store_true", help="只列出分类里的文件，不下载")
    args = ap.parse_args()

    cats = args.cat or DEFAULT_CATS

    if args.list_cats:
        for c in cats:
            print("")
            print("=== %s ===" % c)
            try:
                ts = cat_members(c, 300, depth=1)
                info = imageinfo(ts[:60])
                print("  %d 个文件（显示前 60）" % len(ts))
                for t, d in list(info.items())[:60]:
                    flag = "OK " if is_ok(d["license"]) else "跳过"
                    print("  [%s] %-22s %5dx%-5d %s" % (flag, d["license"][:22], d["width"], d["height"], t))
            except Exception as e:
                print("  失败: %s" % e)
        return

    if not args.out:
        ap.error("--out 是必须的（除非用 --list-cats）")

    os.makedirs(args.out, exist_ok=True)
    manifest = []

    for c in cats:
        print("")
        print("=== %s ===" % c)
        try:
            titles = cat_members(c, args.per_cat * 4, depth=1)
        except Exception as e:
            print("  枚举失败: %s" % e)
            continue
        if not titles:
            print("  (空)")
            continue

        info = imageinfo(titles)
        print("  候选 %d 个" % len(info))

        folder = os.path.join(args.out, safe(c.replace("Category:", "")))
        got = 0
        for title, d in info.items():
            if got >= args.per_cat:
                break
            if not is_ok(d["license"]):
                print("  跳过 [%s] %s" % (d["license"], title))
                continue
            if d["size"] > MAX_BYTES:
                print("  太大 %.0fMB  %s" % (d["size"] / 1048576, title))
                continue
            if min(d["width"], d["height"]) < args.min_side:
                print("  太小 %dx%d  %s" % (d["width"], d["height"], title))
                continue

            base = safe(os.path.splitext(title.replace("File:", ""))[0])
            dest = os.path.join(folder, base + ext_of(d["url"]))
            if os.path.exists(dest) and os.path.getsize(dest) > 4096:
                print("  已有 %s" % base)
                got += 1
                continue

            os.makedirs(folder, exist_ok=True)
            print("  下载 %4dx%-5d [%s] %s" % (d["width"], d["height"], d["license"][:20], base))
            if download(d["url"], dest):
                manifest.append({
                    "category": c, "file": dest, "title": title,
                    "license": d["license"], "artist": d["artist"],
                    "width": d["width"], "height": d["height"], "source": d["url"],
                })
                got += 1
            time.sleep(1.2)

        print("  -> %d 张" % got)

    mf = os.path.join(args.out, "_manifest.json")
    with open(mf, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("")
    print("共 %d 张。授权清单: %s" % (len(manifest), mf))


if __name__ == "__main__":
    main()
