#!/bin/sh
# 把「这个产物是从哪个 commit 出的」写进产物 Info.plist。
#
# 由 `apps/pendingbot/project.yml` 的 postBuildScripts 调用，**iOS / macOS 两端
# 都跑**。跑在 code signing 之前，所以改 Info.plist 不会让签名失效。
#
# 形状照抄 PendingCrew 的 `Shared/scripts/stamp-build-info.sh`，多加一样东西：
# **dirty 标记**。从带未提交改动的工作区打出来的包，光有 sha 是骗人的 ——
# 那个 sha 指向的代码和包里跑的代码根本不是一回事。
#
# ---- 写进去的三个键 -------------------------------------------------------
#   BuildStampCommit  40 位 sha，或字面量 `unknown`
#   BuildStampDirty   true / false（只在拿到 sha 时才写）
#   BuildStampDate    构建时刻（UTC）
#
# **拿不到 git 信息时写 `unknown`，而不是「一个键都不写」**（这一点跟
# PendingCrew 不同，是有意的）：两种情况必须能分开 ——
#   - 键写着 `unknown` → 打戳脚本**跑了**，只是那台机器上没有 git 信息
#     （tarball / 浅克隆 / 没装 git）。这是诚实的答案。
#   - 键**不存在**    → 打戳这一步压根没跑（比如 build phase 被人删了）。
#     那是工程配置坏了，不该跟上面那种混在一起。
#
# **绝不写空串、也绝不编一个假 sha 顶上。**
#
# ---- 同一个机制，两套政策（构建期宽、发版期严）---------------------------
# 这里是**构建期**，一律 exit 0、不拦人：
#   - 外部人从 tarball 编 → `unknown`，照常编得过。这条路径就是给开源用户的，
#     不该因为缺 git 元数据就不让人编译。
#   - 从脏工作区编 → 标 dirty，照常编得过。开发时工作区本来就是脏的。
#
# **发版期**（`scripts/release/build-macos-dmg.sh` 第 ⑨ 道断言）反过来，两种
# 都直接拒绝出包。失败方式不对称：外部人拿到一个标着 `unknown` 的自编包，他
# 知道那是自己编的，无害；而**我们分发出去的 .dmg 要是标着 `unknown` 或
# dirty，那就是一个我们自己也说不出它是哪份代码打的产物** —— 那正好抵消了
# 做这件事的全部意义。
set -eu

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$PLIST" ]; then
	echo "warning: stamp-build-info: 找不到产物 Info.plist（$PLIST），跳过打戳"
	exit 0
fi

put() {  # put <键> <类型> <值>
	/usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}

put BuildStampDate string "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! COMMIT=$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null); then
	# 没装 git，或者这不是个 git 仓库（tarball / 下载的 zip）。如实写 unknown。
	put BuildStampCommit string unknown
	/usr/libexec/PlistBuddy -c "Delete :BuildStampDirty" "$PLIST" 2>/dev/null || true
	echo "note: stamp-build-info: 拿不到 git 信息（$SRCROOT 不是 git 仓库或没装 git）→ BuildStampCommit=unknown"
	exit 0
fi

# 脏 = 工作区里有任何未提交的改动（已跟踪文件的改动 + 未忽略的新文件）。
# **不开任何例外**：xcodegen 生成的 PendingBot.xcodeproj 是被跟踪的，一度担心
# 它每次生成都会变、把每个构建都判成脏 —— 2026-08-22 实测过，同一版 xcodegen
# 对同一份 project.yml 的输出与仓库里那份逐字节相同，不会误判。哪天真变了，
# 那本身就是该知道的事（说明提交的 pbxproj 和 project.yml 不同步），不该在这里
# 用一条例外把它盖掉。
if [ -n "$(git -C "$SRCROOT" status --porcelain 2>/dev/null)" ]; then
	DIRTY=true
else
	DIRTY=false
fi

put BuildStampCommit string "$COMMIT"
put BuildStampDirty bool "$DIRTY"
echo "note: stamp-build-info: ${COMMIT} (dirty=${DIRTY}) → $(basename "$PLIST")"
