#!/usr/bin/env python3
"""Print the highest CFBundleVersion App Store Connect已经收到过的 build 号。

只读。给 `ios-build-number.sh` 当防倒退闸用 —— **拿不到数据一律 exit 非 0，
绝不打印一个可以被当成"没有历史版本"的空值**。这条是刻意的：PendingCrew 那边
的 macOS 发版脚本用 `curl ... || true` 拉 appcast，导致「网络失败」和「首发、
feed 里还没有版本」长得一模一样，网络抖一下防倒退就静默失效。这里不重演。

取的是**跨 MARKETING_VERSION 的全局最大值**，不是当前版本内的最大值。
TN2420 里 iOS 允许换版本后重用 build 号，但我们不打算用那个自由度：
全局单调才同时满足 macOS「跨版本必须单调递增」那条更严的规则，而
PendingBot 的 iOS / macOS 是同一个 target、同一个 bundle id、共用同一个
CURRENT_PROJECT_VERSION，迟早会撞上它。

凭据来源（按优先级）：环境变量 → ~/.appstoreconnect/pendingbot.env
  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.pendingname.pendingbot"
ENV_FILE = Path.home() / ".appstoreconnect" / "pendingbot.env"


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"asc_highest_build: {msg}", file=sys.stderr)
    sys.exit(1)


def load_credentials() -> tuple[str, str, str]:
    values = {}
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
        die(
            "缺少 App Store Connect 凭据: "
            + ", ".join(missing)
            + f"\n  设成环境变量，或写进 {ENV_FILE}（一行一个 KEY=value）。"
            + "\n  见 docs/deploy.md 的「iOS build 号 — UTC 时间戳 + 防倒退闸」一节。"
        )
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


RETRIES = 4          # 首次 + 3 次重试
BACKOFF = (2, 5, 15)  # 秒


def get(url: str, token: str) -> dict:
    """取一页。**任何取不到的情形都不返回空值放行**，但区分两类失败：

    - 确定性失败（鉴权错、请求写错、app 不存在 = 4xx，429 除外）→ 立刻停。重试没用。
    - 瞬时失败（网络 / 超时 / 5xx / 429）→ 有限退避重试，仍不行才停。

    这一层是 PendingCrew 机长（4-1）提的：ASC 要 JWT、有速率限制、偶尔 5xx，
    单纯的 fail-closed 会变成「Apple 抖一下就发不了版」。但重试也到此为止 ——
    不做无限重试，宁可停下来让人看到错误原文。
    """
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    last = ""
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode()[:400]
            if exc.code < 500 and exc.code != 429:
                die(f"App Store Connect 返回 HTTP {exc.code}（确定性错误，重试无用）: {body}")
            last = f"HTTP {exc.code}: {body}"
        except Exception as exc:  # 网络不通 / DNS / 超时
            last = f"{type(exc).__name__}: {exc}"
        if attempt < len(BACKOFF):
            print(
                f"asc_highest_build: 第 {attempt + 1} 次取 ASC 失败（{last}），"
                f"{BACKOFF[attempt]}s 后重试",
                file=sys.stderr,
            )
            time.sleep(BACKOFF[attempt])
    die(
        f"重试 {RETRIES} 次仍够不着 App Store Connect —— 最后一次: {last}\n"
        "  防倒退闸拒绝在盲飞状态下放行。这不是让你绕过它的信号，是「现在没法核实」：\n"
        "  等 ASC 恢复再发，或先手工在 App Store Connect 网页上确认最高 build 号。"
    )


def version_key(value: str) -> tuple[int, ...]:
    """CFBundleVersion 逐段数值比较，缺的段按 0 补（TN2420 的语义）。"""
    parts = [int(p) for p in value.split(".") if p != ""]
    return tuple(parts + [0] * (3 - len(parts)))[:3]


def main() -> None:
    # `--greater A B` —— 只做比较，不联网。让 shell 那侧不必复制一份比较逻辑。
    if len(sys.argv) == 4 and sys.argv[1] == "--greater":
        sys.exit(0 if version_key(sys.argv[2]) > version_key(sys.argv[3]) else 1)

    token = make_token(*load_credentials())

    apps = get(f"{API}/apps?filter[bundleId]={BUNDLE_ID}", token)["data"]
    if not apps:
        die(f"App Store Connect 上找不到 bundleId={BUNDLE_ID} 的 app 记录")
    app_id = apps[0]["id"]

    versions: list[str] = []
    url = f"{API}/builds?filter[app]={app_id}&limit=200"
    while url:
        page = get(url, token)
        for build in page["data"]:
            version = build["attributes"].get("version")
            if version:
                versions.append(version)
        url = page.get("links", {}).get("next")

    if not versions:
        # 真·首发：API 通了、app 记录存在、就是一个 build 都没有。
        # 这跟"够不着 API"是两回事，上面那些路径已经 exit 1 了。
        print("0")
        return

    print(max(versions, key=version_key))


if __name__ == "__main__":
    main()
