#!/bin/sh
# 用法: verify-rpath-resolvable.sh <App.app 路径> <可执行文件名>
#
# 断言：主可执行文件的每个 @rpath 依赖，都能沿它自己的 LC_RPATH 在包内解析出
# 真实文件 —— 也就是把 dyld 的解析规则在发布前先跑一遍。
#
# 为什么需要这道门：发版脚本里其余的断言查的**全是签名和 entitlement**，
# 没有一道能发现「签得好好的、公证也过了、一双击就 dyld Library not loaded」。
# PendingCrew 2026-08-06 正是这么让一个**六道断言全绿**的包上了线：XcodeGen 对
# `supportedDestinations` 多端 target 只生成 iOS 约定的 rpath
# （`@executable_path/Frameworks`），而 macOS 的嵌入式框架在 `Contents/Frameworks`。
#
# **我们是同一种工程**（`apps/pendingbot/project.yml` 的 PendingBot target 就是
# `supportedDestinations: [iOS, macOS]`），而且嵌进包里的 SPM 框架不少
# （GRDB / Sentry / PostHog / RevenueCat / Supabase / GoogleSignIn / MarkdownUI /
# SwiftMath …），所以这道门对我们只会更重要，不会更轻。
#
# 只查主可执行文件：这是踩过的那一类。嵌入框架自身的依赖不在范围内。
set -eu

app=${1:?usage: verify-rpath-resolvable.sh <App.app> <exe-name>}
exe_name=${2:?usage: verify-rpath-resolvable.sh <App.app> <exe-name>}
exe="$app/Contents/MacOS/$exe_name"
test -f "$exe" || { echo "找不到可执行文件: $exe" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# 逐行读文件，不用 `for x in $var` —— 那个写法依赖词分裂，在 zsh 下不分裂，
# 会让整道断言退化成「永远全都解析不到」的假阳性。PendingCrew 现场踩过一次。
otool -l "$exe" | awk '/LC_RPATH/{f=1} f&&/^ *path /{print $2; f=0}' | sort -u > "$tmp/rpaths"
otool -L "$exe" | awk '/^\t@rpath\//{print $1}' | sort -u > "$tmp/deps"

# 一个 @rpath 依赖都没有也要说话：真没有内嵌框架是可能的，但更可能是
# otool 的输出格式变了、awk 一条都没匹配上 —— 那样这道断言会静默全绿。
dep_count=$(grep -c '' "$tmp/deps" || true)
echo "rpath 断言：$dep_count 个 @rpath 依赖，$(grep -c '' "$tmp/rpaths" || true) 条 LC_RPATH"

missing=''
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  suffix=${dep#@rpath/}
  found=''
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    # dyld 对主可执行文件而言 @loader_path 等同 @executable_path
    resolved=$(printf '%s' "$rp" | sed -e "s|@executable_path|$app/Contents/MacOS|" \
                                       -e "s|@loader_path|$app/Contents/MacOS|")
    if [ -e "$resolved/$suffix" ]; then found=1; break; fi
  done < "$tmp/rpaths"
  [ -n "$found" ] || missing="$missing  $dep
"
done < "$tmp/deps"

if [ -n "$missing" ]; then
  echo "以下 @rpath 依赖在包内解析不到 —— app 一启动就会 dyld 崩溃：" >&2
  printf '%s' "$missing" >&2
  echo "可执行文件的 LC_RPATH：" >&2
  sed 's/^/  /' "$tmp/rpaths" >&2
  echo "（macOS 的嵌入式框架在 Contents/Frameworks，rpath 需要 @executable_path/../Frameworks；" >&2
  echo "  在 apps/pendingbot/project.yml 里设 \"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]\"）" >&2
  exit 2
fi
