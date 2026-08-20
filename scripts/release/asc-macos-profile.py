#!/usr/bin/env python3
"""取回并安装 macOS「直接分发」(Developer ID) 的 provisioning profile。

只读 App Store Connect，除了往本机 ~/Library 写一份描述文件之外不改任何东西。
给 `build-macos-dmg.sh` 当前置步骤用。

**为什么不让 Xcode 自动签名去申请**（2026-08-20 实测，别再走回头路）：
自动签名走的是「云端托管发布证书」（DEVELOPER_ID_APPLICATION_MANAGED）。
本机这个账号申请它会被 Apple 挡回来：

    403 FORBIDDEN_ERROR / "You haven't been given access to cloud-managed
    distribution certificates."

而我们**本机和后台都有**一张正常的 Developer ID Application 证书，也有一张
手工建好的 `MAC_APP_DIRECT` 描述文件。所以正解是 exportArchive 用**手工
签名**、把这张文件显式指给它 —— 这不是降级：证书、hardened runtime、公证
一步不少，只是不让 Xcode 去申请一张我们要不到的证书。

**为什么每次都从 Apple 重拉，而不是用本机已经装着的那份**：
描述文件是会被重新生成的（比如给它补一项能力之后）。用本机旧副本会出现
「后台已经改好了、构建还在用老的」这种查起来很费劲的错位。每次重拉，
本机副本永远只是缓存。

拿不到数据一律 exit 非 0 —— 绝不打印一个能被当成「没有描述文件」的空值。
（同 asc_highest_build.py 的口径。）

凭据来源（按优先级）：环境变量 → ~/.appstoreconnect/pendingbot.env
  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH

用法:
  asc-macos-profile.py --bundle-id com.pendingname.pendingbot [--name PendingBotDistribute]
    → 装进本机并把一份 JSON 打到 stdout:
      {"name","uuid","path","expiration","entitlements":{...},"certificates":[...]}
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1"
ENV_FILE = Path.home() / ".appstoreconnect" / "pendingbot.env"
# Xcode 16+ 找描述文件的位置。老路径 ~/Library/MobileDevice/Provisioning Profiles
# 只对 iOS 的 .mobileprovision 有意义。
INSTALL_DIR = Path.home() / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles"
# macOS 直接分发（Developer ID）的描述文件类型。
PROFILE_TYPE = "MAC_APP_DIRECT"
RETRIES = 4
BACKOFF = (2, 5, 15)


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"asc-macos-profile: {msg}", file=sys.stderr)
    sys.exit(1)


def load_credentials() -> tuple[str, str, str]:
    values: dict[str, str] = {}
    if ENV_FILE.is_file():
        for raw in ENV_FILE.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip("'\"")
    for key in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
        if os.environ.get(key):
            values[key] = os.environ[key]
    missing = [k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not values.get(k)]
    if missing:
        die("缺少 App Store Connect 凭据: " + ", ".join(missing)
            + f"\n  设成环境变量，或写进 {ENV_FILE}（一行一个 KEY=value）。")
    if not Path(values["ASC_KEY_PATH"]).is_file():
        die(f"ASC_KEY_PATH 指向的 .p8 不存在: {values['ASC_KEY_PATH']}")
    return values["ASC_KEY_ID"], values["ASC_ISSUER_ID"], values["ASC_KEY_PATH"]


def make_token(key_id: str, issuer_id: str, key_path: str) -> str:
    try:
        import jwt  # PyJWT
    except ImportError:
        die("需要 PyJWT 才能给 App Store Connect API 签 token: /usr/bin/python3 -m pip install --user pyjwt")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        Path(key_path).read_text(),
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def get(token: str, path: str) -> dict:
    last = ""
    for attempt in range(RETRIES):
        req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")[:400]
            last = f"HTTP {exc.code}: {body}"
            # 4xx 里只有 429 值得重试；其余是我们的问题，重试没用。
            if exc.code != 429 and 400 <= exc.code < 500:
                die(f"App Store Connect 拒绝了请求 —— {last}")
        except Exception as exc:  # 网络层
            last = repr(exc)
        if attempt < len(BACKOFF):
            time.sleep(BACKOFF[attempt])
    die(f"取不到 App Store Connect 数据（{RETRIES} 次都失败）—— {last}\n"
        "  这是 fail-closed：拿不到描述文件就不构建，绝不拿本机的旧副本顶上。")


def decode_profile(raw: bytes) -> dict:
    # 描述文件是 CMS 签名过的 plist；security cms -D 拆掉签名信封。
    out = subprocess.run(["security", "cms", "-D", "-i", "/dev/stdin"],
                         input=raw, capture_output=True)
    if out.returncode != 0 or not out.stdout:
        die("解不开描述文件（security cms -D 失败）: " + out.stderr.decode()[:300])
    return plistlib.loads(out.stdout)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--name", default=None,
                    help="有多张同 bundle id 的直接分发描述文件时，指名要哪张")
    args = ap.parse_args()

    token = make_token(*load_credentials())
    data = get(token, "/profiles?limit=200&include=bundleId,certificates")
    included = {i["id"]: i for i in data.get("included", [])}

    matches = []
    for d in data.get("data", []):
        attrs = d["attributes"]
        if attrs.get("profileType") != PROFILE_TYPE:
            continue
        bid_ref = d["relationships"]["bundleId"]["data"]["id"]
        bid = included.get(bid_ref, {}).get("attributes", {}).get("identifier")
        if bid != args.bundle_id:
            continue
        if args.name and attrs.get("name") != args.name:
            continue
        matches.append((d, attrs))

    if not matches:
        die(f"App Store Connect 上没有 {args.bundle_id} 的 {PROFILE_TYPE} 描述文件"
            + (f"（名字要求 {args.name}）" if args.name else "")
            + "\n  去 developer.apple.com/account → Certificates, Identifiers & Profiles"
              " → Profiles 建一张 Developer ID Application (macOS) 的。")
    if len(matches) > 1:
        names = ", ".join(a.get("name", "?") for _, a in matches)
        die(f"{args.bundle_id} 有多张 {PROFILE_TYPE} 描述文件（{names}）—— "
            "用 --name 指名要哪张，别让脚本替你猜。")

    entry, attrs = matches[0]
    if attrs.get("profileState") != "ACTIVE":
        die(f"描述文件 {attrs.get('name')} 状态是 {attrs.get('profileState')}，不是 ACTIVE。")

    exp = attrs.get("expirationDate")
    if exp:
        # "2027-02-01T22:12:15.000+00:00"
        when = datetime.fromisoformat(exp)
        if when <= datetime.now(timezone.utc):
            die(f"描述文件 {attrs.get('name')} 已于 {exp} 过期 —— 去后台重新生成一张。")

    raw = base64.b64decode(attrs["profileContent"])
    plist = decode_profile(raw)
    uuid = plist["UUID"]

    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    dest = INSTALL_DIR / f"{uuid}.provisionprofile"
    dest.write_bytes(raw)

    certs = [included.get(c["id"], {}).get("attributes", {}).get("name")
             for c in entry["relationships"]["certificates"]["data"]]

    json.dump({
        "name": attrs.get("name"),
        "uuid": uuid,
        "path": str(dest),
        "expiration": exp,
        # 描述文件**自己**记的生成时刻。断言失败时必须打出来 —— 它是区分
        # 「文件真的缺这个键」和「后台已经改好、我读的是过期副本」的唯一凭据。
        "created": plist.get("CreationDate"),
        "platform": plist.get("Platform"),
        "certificates": certs,
        "entitlements": {k: v for k, v in plist.get("Entitlements", {}).items()},
    }, sys.stdout, ensure_ascii=False, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
