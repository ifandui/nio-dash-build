# -*- coding: utf-8 -*-
"""
sniff_3d_model.py - 蔚来 App 3D 车模资产抓取插件 (mitmproxy)
配合 sniff_3d_model.sh 使用：iPhone/Mac 上打开蔚来 App 的 3D 车模视图，
本插件自动捕获：
  1. 配置响应里的 model3d_url / model3d_md5 / framework_url / data_url / loader_url 等；
  2. 任意域名下的 .unity3d / .assetbundle / unity / model3d 下载请求（CDN 不限 nio.com）；
  3. 抓到模型资产 URL 后自动下载到 sniff_3d_out/ 目录。
结果写入 nio_3d_model.json，成功时播放提示音并复制 JSON 到剪贴板。
"""

from mitmproxy import http
import json
import os
import re
import subprocess
import threading
import time

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sniff_3d_out")
JSON_DIR = os.path.join(OUT_DIR, "json")
RESULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nio_3d_model.json")

captured = {}
seen_urls = set()
downloaded = set()
lock = threading.Lock()

# 配置 JSON 里关心的键（递归搜索）
CONFIG_KEYS = [
    "model3d_url", "model3d_md5", "model_url", "model_md5", "model_code",
    "model_list", "generation_code", "draw3d_switch_type",
    "framework_url", "data_url", "loader_url", "code_url",
    "unity_url", "unity3d_url", "asset_url", "assetbundle_url",
    "three_d_url", "3d_url", "car_model_url", "vehicle_model_url",
]

# 请求 URL 特征（任意域名）
URL_PATTERNS = re.compile(
    r"\.unity3d($|\?)|\.unity3d$|\.assetbundle($|\?)|\.assetbundle$"
    r"|unity3d|assetbundle|model3d|model_3d|3dmodel|/3d/|/model3d/|vehiclemodel",
    re.IGNORECASE,
)

# 蔚来 CDN / OSS 域名特征（大文件下载兜底）
CDN_HOSTS = re.compile(r"cdn|udp-public|niodata|nextev|nio-|oss-|aliyun|qiniu", re.IGNORECASE)


def notify_sound():
    try:
        subprocess.Popen(["afplay", "/System/Library/Sounds/Glass.aiff"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def copy_clipboard(text):
    try:
        p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
        p.communicate(text.encode("utf-8"))
    except Exception:
        pass


def search_keys(obj, keys):
    """递归搜索 JSON 中的目标键，返回 {key: value}"""
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = str(k).lower()
            for tk in keys:
                if tk.lower() in kl and isinstance(v, (str, int, float)) and v:
                    out[k] = v if isinstance(v, str) else str(v)
            if isinstance(v, (dict, list)):
                out.update(search_keys(v, keys))
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, list)):
                out.update(search_keys(item, keys))
    return out


def persist():
    with lock:
        with open(RESULT_PATH, "w", encoding="utf-8") as f:
            json.dump(captured, f, indent=2, ensure_ascii=False)


def try_download(url):
    """自动下载模型资产到 sniff_3d_out/"""
    if url in downloaded:
        return
    downloaded.add(url)
    os.makedirs(OUT_DIR, exist_ok=True)
    fname = url.split("?")[0].rstrip("/").split("/")[-1] or "model_asset"
    dest = os.path.join(OUT_DIR, fname)
    print(f"\n[⬇️] 自动下载模型资产: {url[:100]}")
    subprocess.Popen(["curl", "-sL", "-m", "600", "-o", dest, url],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def announce(kind, detail):
    print(f"\n[★ 3D] {kind}: {detail}")


def response(flow: http.HTTPFlow):
    if not flow.response or not flow.response.content:
        return
    host = flow.request.pretty_host
    url = flow.request.url

    # 0) 全量落盘：nio 域名的 JSON 响应全部存档（离线兜底搜索 3d/model 关键词）
    if "nio" in host:
        ctype0 = flow.response.headers.get("Content-Type", "")
        body = None
        if "json" in ctype0 or "text" in ctype0:
            try:
                body = flow.response.get_text()
            except Exception:
                body = None
        if body:
            os.makedirs(JSON_DIR, exist_ok=True)
            slug = re.sub(r"[^A-Za-z0-9._-]", "_", flow.request.path.split("?")[0])[-60:]
            with open(os.path.join(JSON_DIR, f"{time.strftime('%H%M%S')}_{slug}.json"), "w") as f:
                f.write(f"// {url}\n{body}")

    # 1) JSON 配置响应：递归搜 model3d 配置键
    ctype = flow.response.headers.get("Content-Type", "")
    if "json" in ctype:
        try:
            obj = json.loads(flow.response.get_text())
        except Exception:
            obj = None
        if obj is not None:
            found = search_keys(obj, CONFIG_KEYS)
            if found:
                for k, v in found.items():
                    if k not in captured or captured[k] != v:
                        captured[k] = v
                        announce("配置字段", f"{k} = {str(v)[:120]}")
                        persist()
                urls = [v for k, v in found.items() if isinstance(v, str) and v.startswith("http")]
                if urls:
                    notify_sound()
                    copy_clipboard(json.dumps(captured, indent=2, ensure_ascii=False))
                    print("\n" + "═" * 66)
                    print("  🎉 捕获 3D 车模配置！model3d_url 等字段已写入 nio_3d_model.json")
                    for u in urls:
                        print(f"     • {u[:110]}")
                    print("═" * 66 + "\n")
                    for u in urls:
                        if URL_PATTERNS.search(u):
                            try_download(u)

    # 2) 模型资产直下：任意域名的 unity3d/assetbundle 请求
    if URL_PATTERNS.search(url):
        size = flow.response.headers.get("Content-Length", "?")
        if url not in seen_urls:
            seen_urls.add(url)
            captured.setdefault("asset_urls", [])
            if url not in captured["asset_urls"]:
                captured["asset_urls"].append(url)
            captured.setdefault("assets", []).append({
                "url": url, "host": host, "size": size,
                "time": time.strftime("%H:%M:%S"),
            })
            announce("资产请求", f"{host} {flow.request.path[:80]} (size={size})")
            persist()
            try:
                if size != "?" and int(size) > 100_000:
                    try_download(url)
                    notify_sound()
            except ValueError:
                pass


def request(flow: http.HTTPFlow):
    # 大文件请求的早期发现（配置接口可能漏检时兜底记录 URL）
    url = flow.request.url
    host = flow.request.pretty_host
    if URL_PATTERNS.search(url) and url not in seen_urls:
        seen_urls.add(url)
        announce("资产请求(请求侧)", f"{host}{flow.request.path[:90]}")
