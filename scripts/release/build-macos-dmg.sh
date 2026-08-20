#!/bin/sh
# 本地出 macOS 安装包（.dmg）。
#
#   scripts/release/build-macos-dmg.sh
#
# 干净快照（默认钉 main HEAD）→ Release archive（macOS destination）
# → Developer ID 签名（exportArchive）→ 八道断言 → 公证 → staple
# → 打 .dmg → dmg 也签名 + 公证 + staple → 终验 → 打 tag。
#
# **凭据一律不上云。** Developer ID 证书能签任何冒充这个开发者身份的 app，
# 不值得为省几下手动操作送进 GitHub secrets（2026-08-20 人类拍板）。所以形态
# 就是「本地出包 → 人工 gh release 上传产物」，CI 只跑不需要凭据的闸
# （.github/workflows/edge-checks.yml）。
#
# 这里**没有**「跳过公证」「关掉签名」「先出个 ad-hoc 包」之类的开关，是刻意的：
# 那样出来的东西在别人机器上会被 Gatekeeper 拦，等于发了个装不上的包。卡住就
# 卡住，卡住是个正确的状态。
#
# ---- 环境变量 -------------------------------------------------------------
#   PENDING_RELEASE_REF     构建哪个 ref（默认 main）。**非 main = 演练模式**：
#                           照样出真包、真公证、真验，但不打 tag、不碰任何共享
#                           状态。改脚本时用它，别拿 main 当试验场。
#   PENDING_TEAM_ID         默认 M42BKJN82S
#   PENDING_MACOS_PROFILE   描述文件名，默认 PendingBotDistribute
#   PENDING_NOTARY_PROFILE  notarytool 的钥匙串 profile 名。不给就用
#                           ~/.appstoreconnect/pendingbot.env 里那把 ASC key
#                           （和传 TestFlight、查 build 号闸是同一把）。
#   PENDING_DRAFT_RELEASE=1 额外跑一条 `gh release create --draft`。**默认关**，
#                           因为它会把 tag 推到 origin —— 那是一次对外动作，
#                           得是人明确要的，不是构建的副作用。
set -eu

app_name=PendingBot
bundle_id=com.pendingname.pendingbot
scheme=PendingBot

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_dir_rel=apps/pendingbot
team_id="${PENDING_TEAM_ID:-M42BKJN82S}"
ref="${PENDING_RELEASE_REF:-main}"
profile_name="${PENDING_MACOS_PROFILE:-PendingBotDistribute}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 2; }

# ===========================================================================
# 第 0 阶段 —— 前置断言。**全部在 archive 之前**，秒级。
#
# 这一整段的存在理由只有一条：archive + 公证要跑十几到二十分钟，任何能在开跑
# 前就知道会失败的事，都不该等到跑完才知道。下面第 0.5 条尤其 ——
# 2026-08-20 就是靠它把「描述文件没带 Sign in with Apple」从「archive 完
# 二十分钟后才炸」提前到了「两秒」。
# ===========================================================================
step "0. 前置断言"

for tool in xcodegen xcodebuild hdiutil ditto codesign otool vtool lipo plutil xcrun; do
  command -v "$tool" >/dev/null 2>&1 || fail "PATH 上找不到 $tool"
done
[ "${PENDING_DRAFT_RELEASE:-0}" != "1" ] || command -v gh >/dev/null 2>&1 \
  || fail "PENDING_DRAFT_RELEASE=1 需要 gh"

# 0.1 Developer ID 证书必须在钥匙串里（没有的话下面 export 会失败得很难读）
security find-identity -v -p codesigning 2>/dev/null \
  | grep -q "Developer ID Application: .*($team_id)" \
  || fail "钥匙串里没有 \"Developer ID Application: …($team_id)\" 证书。
  这不是能绕过的东西 —— 没有它就签不出别人机器上能打开的包。"

# 0.2 公证凭据。两条路二选一，**都不通就停**，不留「先不公证」的口子。
if [ -n "${PENDING_NOTARY_PROFILE:-}" ]; then
  notary_args="--keychain-profile $PENDING_NOTARY_PROFILE"
  echo "公证凭据：钥匙串 profile $PENDING_NOTARY_PROFILE"
else
  asc_env="$HOME/.appstoreconnect/pendingbot.env"
  [ -f "$asc_env" ] || fail "既没给 PENDING_NOTARY_PROFILE，也没有 $asc_env —— 无从公证。"
  # shellcheck disable=SC1090
  . "$asc_env"
  : "${ASC_KEY_ID:?$asc_env 里缺 ASC_KEY_ID}"
  : "${ASC_ISSUER_ID:?$asc_env 里缺 ASC_ISSUER_ID}"
  : "${ASC_KEY_PATH:?$asc_env 里缺 ASC_KEY_PATH}"
  [ -f "$ASC_KEY_PATH" ] || fail "ASC_KEY_PATH 指的 .p8 不存在: $ASC_KEY_PATH"
  notary_args="--key $ASC_KEY_PATH --key-id $ASC_KEY_ID --issuer $ASC_ISSUER_ID"
  echo "公证凭据：ASC API key $ASC_KEY_ID（本机，不上云）"
fi

# 0.3 从 Apple 重拉描述文件并装到本机。
#     每次都重拉是有意的 —— 后台改过之后用本机旧副本，会出现「后台已经改好、
#     构建还在用老的」这种极难查的错位。本机那份只当缓存。
profile_json=$("$root/scripts/release/asc-macos-profile.py" \
  --bundle-id "$bundle_id" --name "$profile_name") \
  || fail "取描述文件失败（上面有原因）"
profile_uuid=$(printf '%s' "$profile_json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
echo "描述文件：$profile_name（$profile_uuid），有效期到 $(printf '%s' "$profile_json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["expiration"])')"

# 0.4 签名方式：**手工指定描述文件**，不用 Xcode 自动申请。
#     自动签名走的是「云端托管发布证书」，本机这个账号申请它会被 Apple 挡回来
#     （403 "You haven't been given access to cloud-managed distribution
#     certificates."）。而我们本机和后台都有一张正常的 Developer ID 证书 +
#     一张手工建好的描述文件。用手工签名不是降级：证书、hardened runtime、
#     公证一步不少，只是不去申请一张要不到的证书。
#     archive 阶段仍然用自动签名（开发身份）—— 见下面第 2 阶段的注释。

# 0.5 **描述文件必须覆盖源 entitlements 里的每一个键。**
#     这道断言值一整轮：2026-08-20 实测，`PendingBotDistribute` 少了
#     `com.apple.developer.applesignin`，而 Mac 端的登录全靠它。手工签名下
#     Xcode 会明确报错（好事），但那要等到 archive 完二十分钟之后。
#     值不比对、只比键：描述文件里的值常是通配（`M42BKJN82S.*`、`"*"`），
#     跟源文件里的具体值本来就不该相等。
src_ent="$root/$app_dir_rel/Resources/$app_name-macOS.entitlements"
[ -f "$src_ent" ] || fail "找不到 macOS 的 entitlements: $src_ent"
printf '%s' "$profile_json" | /usr/bin/python3 -c '
import json, plistlib, sys
prof = json.load(sys.stdin)
src = plistlib.load(open(sys.argv[1], "rb"))
have = set(prof["entitlements"])
missing = [k for k in src if k not in have]
if missing:
    print("描述文件 %s 没有授权这些 entitlement 键：" % prof["name"], file=sys.stderr)
    for k in missing:
        print("    " + k, file=sys.stderr)
    print("""
  这份**是刚从 Apple 现拉的，不是本机缓存** —— 本脚本每次构建都重新下载
  描述文件，本机那份只当缓存。所以「缺」是 Apple 那边记录的实际状态。
    描述文件 UUID : %s
    它自己记的生成时刻 : %s
  UUID 和生成时刻没变，就说明后台那条记录**从来没有被重新生成过**。

  能力在 App ID 上勾着**还不够** —— 描述文件是生成那一刻的快照，之后给
  App ID 加的能力不会自动补进已有的文件里。所以后台页面上看着是勾的、
  文件里却没有，这两件事可以同时为真。

  修法：developer.apple.com/account → Certificates, Identifiers & Profiles
  → Profiles → %s → Edit → Generate（重新生成一次，UUID 会变）。

  如果重新生成之后这些键**还是**没进来，那就不是过期问题，而是 Apple 不给
  这个分发方式这项能力 —— 那是产品级问题，停下来找人，别绕。

  别为了绕过它从 %s 里删键 —— 那是把功能悄悄关掉，不是修好。""" % (
        prof["uuid"], prof.get("created"), prof["name"], sys.argv[1]), file=sys.stderr)
    sys.exit(2)
print("描述文件覆盖了源 entitlements 的全部 %d 个键" % len(src))
' "$src_ent" || fail "描述文件授权不全 —— 这次构建注定签不出来，停在这里"

# 0.6 build 号（CFBundleVersion）。格式的唯一事实源是 ios-build-number.sh，
#     这里不另起一套。`--print-only` 跳过的是 ASC 防倒退闸 —— Mac 包不上 ASC，
#     那道闸比错了对象，理由写在那个脚本的文件头。
build_number=$("$root/scripts/release/ios-build-number.sh" --print-only) \
  || fail "算不出 build 号"
echo "build 号：$build_number"

echo "✓ 前置断言全过"

# ===========================================================================
# 第 1 阶段 —— 干净快照
#
# 这台机器的工作区常年是脏的。不钉一个 ref 建快照，就没法保证「所见 = 所装」。
# ===========================================================================
step "1. 干净快照（$ref）"
snap=$(mktemp -d "/tmp/pendingbot-macos-release.XXXXXX")
cleanup() {
  git -C "$root" worktree remove --force "$snap/src" 2>/dev/null || true
  git -C "$root" worktree prune
  rm -rf "$snap"
}
trap cleanup EXIT HUP INT TERM
git -C "$root" worktree add --detach "$snap/src" "$ref" >/dev/null
snap_sha=$(git -C "$snap/src" rev-parse HEAD)
echo "快照 = $ref @ $snap_sha"

src="$snap/src/$app_dir_rel"
# 版本号必须从**快照**里读，不是从工作区 —— 工作区可能是脏的，读那份会所见≠所装。
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$src/project.yml" | head -n 1 | tr -d '"')
[ -n "$version" ] || fail "读不出 MARKETING_VERSION"
echo "版本号：$version（tag 用的语义化版本；build 号跟它解耦）"

# ===========================================================================
# 第 2 阶段 —— Release archive
# ===========================================================================
step "2. archive（macOS）"
cd "$src"
xcodegen generate >/dev/null

derived="$snap/derived"
xcarchive="$snap/$app_name.xcarchive"

# `-destination 'generic/platform=macOS'` 是关键：PendingBot 这个 target 是
# `supportedDestinations: [iOS, macOS]`，macOS 不是独立 target。不钉住就可能
# 构出 iOS 产物。第 3 阶段第 ① 道断言会用 vtool 正面核对产物到底是不是 Mac 的。
#
# **不要在这里指定 CODE_SIGN_IDENTITY**：自动签名 + 手工指定发布身份会被 Xcode
# 判成 "conflicting provisioning settings" 直接失败（每个 SPM 依赖都会报一遍）。
# 正确分工是 archive 用自动签名（开发身份），发布身份留给下面的 exportArchive。
xcodebuild -project "$app_name.xcodeproj" -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  -archivePath "$xcarchive" -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team_id" \
  ENABLE_HARDENED_RUNTIME=YES \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  archive

# ===========================================================================
# 第 3 阶段 —— export（Developer ID）
# ===========================================================================
step "3. exportArchive（developer-id，手工签名）"
cat > "$snap/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$team_id</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$bundle_id</key><string>$profile_uuid</string>
	</dict>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$xcarchive" \
  -exportPath "$snap/export" -exportOptionsPlist "$snap/ExportOptions.plist"

app="$snap/export/$app_name.app"
[ -d "$app" ] || fail "exportArchive 没产出 $app"

# 回到仓库根。后面没有一步需要待在快照里，而退出时的 cleanup 要把快照整个删掉 ——
# 站在一个正在被删的目录里是自找麻烦。
cd "$root"

# ===========================================================================
# 第 4 阶段 —— 八道断言
#
# 前七道是 PendingCrew 用血换来的，第八道是我们自己的。每一道都对应一次
# 「全链路零报错、装到用户机器上才发现坏了」的真实事故。
# ===========================================================================
step "4. 产物断言"
exe="$app/Contents/MacOS/$app_name"

# ① 产物必须是**真 Mac 原生**的，不是 Catalyst、不是 iOS。
#    这个 target 三端共用，destination 写错、或者哪天有人给它开了 Catalyst，
#    出来的东西照样能签能公证，装上去才发现不对。用 vtool 正面核 Mach-O 里的
#    平台标记，不靠「我传了 macOS 所以应该是 macOS」这种推定。
platforms=$(vtool -show-build "$exe" 2>/dev/null | awk '/platform /{print $2}' | sort -u)
[ "$platforms" = "MACOS" ] \
  || fail "产物的 Mach-O 平台是「$platforms」，不是 MACOS（MACCATALYST / IOS 都不行）"
archs=$(lipo -archs "$exe" 2>/dev/null)
case " $archs " in
  *" arm64 "*) ;;
  *) fail "产物不含 arm64 切片（拿到的是「$archs」）—— Apple Silicon 上跑不了" ;;
esac
echo "① 平台 MACOS，架构：$archs"

# ② 描述文件必须真的嵌进去了。entitlements 里有受限项（application-identifier /
#    keychain-access-groups），没有描述文件授权会被 AMFI 在 exec 之前拒绝 ——
#    表现是「应用已损坏，无法打开」，而签名验证、公证、Gatekeeper 全过。
[ -f "$app/Contents/embedded.provisionprofile" ] \
  || fail "产物缺 embedded.provisionprofile —— 受限 entitlement 没授权，app 打不开"
echo "② embedded.provisionprofile 在"

built_ent=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - -) \
  || fail "读不出产物的 entitlements"

# ③ 签完的 entitlements 里不许残留未展开的构建变量。`$(AppIdentifierPrefix)`
#    没展开的话，keychain 组会变成一个无意义的字面量 —— 读不到家族 SSO 凭据、
#    登录态静默丢失，而签名有效、公证通过、Gatekeeper 放行，全链路零报错。
printf '%s' "$built_ent" | grep -q '[$](' \
  && { printf '%s\n' "$built_ent" >&2; fail "产物 entitlements 里还有未展开的构建变量"; }
echo "③ 没有未展开的构建变量"

# ④ keychain 共享组必须真的带上 team 前缀。**正面断言** —— 上面第 ③ 道那种
#    「没有 $( 」是反面判据，管不住「键整个不见了」。
printf '%s' "$built_ent" | grep -q "$team_id\.com\.pendingname\.shared" \
  || fail "产物 entitlements 里没有 $team_id.com.pendingname.shared —— 家族 SSO 共享组会失效"
echo "④ 家族 SSO 共享组带着 team 前缀"

# ⑤ **源里声明的每个键，产物里必须真的还在**（逐项正面比对）。
#    Xcode 会把描述文件没授权的键**静默剥掉**：产物既没有那个能力也不报任何错，
#    包能签能公证能装能跑，只是那个功能永远不工作。上面 ①—④ 查的都是「我们
#    想到的那几个键」，查不出「声明了但被吞了」。所以这里拿源文件当清单。
missing_keys=$(printf '%s' "$built_ent" | /usr/bin/python3 -c '
import plistlib, sys
built = plistlib.loads(sys.stdin.buffer.read())
src = plistlib.load(open(sys.argv[1], "rb"))
print("\n".join(k for k in src if k not in built))
' "$src_ent") || fail "比对 entitlements 时出错"
[ -z "$missing_keys" ] || {
  printf '源 entitlements 声明了这些键，产物里却没有 —— 被签名步骤静默剥掉了：\n%s\n' "$missing_keys" >&2
  fail "多半是描述文件没授权这个能力，或键名用错了平台（macOS 的推送键是 com.apple.developer.aps-environment，不是 iOS 的 aps-environment）"
}
echo "⑤ 源 entitlements 的每个键在产物里都还在"

# ⑥ hardened runtime 必须开 —— 公证的硬性前提。漏了要等三分钟公证往返才被
#    Apple 拒，不如在这儿立刻拦。CodeDirectory 的 flags 里带 `runtime` 才算数。
codesign -dvv "$app" 2>&1 | grep -qE '^CodeDirectory.*flags=.*runtime' \
  || { codesign -dvv "$app" 2>&1 | grep -E '^CodeDirectory' >&2; fail "产物没开 hardened runtime —— 公证会被拒"; }
echo "⑥ hardened runtime 开着"

# ⑦ 每个 @rpath 依赖都要能在包内解析出真实文件 —— 查的是 dyld，不是签名。
"$root/scripts/release/verify-rpath-resolvable.sh" "$app" "$app_name"
echo "⑦ @rpath 依赖都能解析"

# ⑧ 产物 Info.plist 里的版本号必须真是我们传进去的那两个值。
#    Info.plist 里写的是 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`，
#    要靠构建期变量替换。哪天 GENERATE_INFOPLIST_FILE 或 INFOPLIST_FILE 被人
#    动一下，产物就会带着字面量的 `$(...)` 或者一个陈旧的占位值出门，而上面
#    七道一道都不查这个。
got_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
got_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[ "$got_short" = "$version" ] || fail "产物 CFBundleShortVersionString 是「$got_short」，应该是「$version」"
[ "$got_build" = "$build_number" ] || fail "产物 CFBundleVersion 是「$got_build」，应该是「$build_number」"
echo "⑧ 版本号写对了：$got_short ($got_build)"

# ===========================================================================
# 第 5 阶段 —— 公证 app
# ===========================================================================
step "5. 公证 app（要往返几分钟，正常）"
zip="$snap/$app_name.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$zip"
# shellcheck disable=SC2086
xcrun notarytool submit "$zip" $notary_args --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
echo "app 已公证 + staple"

# ===========================================================================
# 第 6 阶段 —— 打 .dmg
#
# app 先单独公证 + staple，再装进 dmg，dmg 自己再公证 + staple 一次。两次往返
# 是有意的：只 staple dmg 的话，用户把 app 拖出来之后那份 app 身上没有票，
# 第一次打开要联网让 Gatekeeper 现问 Apple —— 断网或 Apple 抖一下就打不开。
# ===========================================================================
step "6. 打 .dmg 并公证"
dist="$root/dist/macos"
mkdir -p "$dist"
dmg="$dist/$app_name-$version-$build_number.dmg"
rm -f "$dmg"

staging="$snap/dmg"
mkdir -p "$staging"
/usr/bin/ditto "$app" "$staging/$app_name.app"
ln -s /Applications "$staging/Applications"   # 拖拽安装的那个箭头
hdiutil create -volname "$app_name" -srcfolder "$staging" -ov -format UDZO -quiet "$dmg"

signer=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($team_id)\)\".*/\1/p" | head -n 1)
[ -n "$signer" ] || fail "找不到 Developer ID 签名身份"
codesign --sign "$signer" --timestamp "$dmg"
# shellcheck disable=SC2086
xcrun notarytool submit "$dmg" $notary_args --wait
xcrun stapler staple "$dmg"

# ===========================================================================
# 第 7 阶段 —— 终验（对着最终产物真跑一遍，不是「应该没问题」）
# ===========================================================================
step "7. 终验"
codesign --verify --deep --strict --verbose=2 "$app"
spctl -a -vvv -t install "$app"
xcrun stapler validate "$app"
spctl -a -vvv -t open --context context:primary-signature "$dmg"
xcrun stapler validate "$dmg"
echo "✓ 签名 / Gatekeeper / 公证票，app 和 dmg 都过了"

# ===========================================================================
# 第 8 阶段 —— tag（只在构建 main 时）
# ===========================================================================
tag="v$version-preview"
if [ "$ref" = "main" ]; then
  step "8. 打 tag"
  # preview 序号从已有 tag 推，不需要任何外部状态。
  n=1
  while git -C "$root" rev-parse -q --verify "refs/tags/$tag.$n" >/dev/null; do
    n=$((n + 1))
  done
  tag="$tag.$n"
  git -C "$root" tag -a "$tag" "$snap_sha" -m "$app_name $version (build $build_number)"
  echo "打了 tag $tag（本地，没有推 origin）"
else
  step "8. 跳过 tag（演练模式）"
  echo "PENDING_RELEASE_REF=$ref 不是 main —— 演练不落任何共享状态（tag / release）。"
  tag="<真发版时才会有>"
fi

step "完成"
echo "产物：$dmg"
echo
echo "接下来由人来按（脚本刻意不做）："
echo "  git push origin $tag"
echo "  gh release create $tag --draft --prerelease --title \"$app_name $version\" \\"
echo "      --notes '只有 1v1 文字聊天是真被用过的；群聊 / 语音 / 附件线上数据全是 0。' \\"
echo "      '$dmg'"
echo
echo "为什么不由脚本代劳：gh release create 要求 tag 已经在 origin 上，"
echo "等于顺带做了一次 push —— 那是对外动作，得是人明确要的，不能是构建的副作用。"

if [ "${PENDING_DRAFT_RELEASE:-0}" = "1" ]; then
  [ "$ref" = "main" ] || fail "PENDING_DRAFT_RELEASE=1 只在构建 main 时有意义"
  step "9. gh release create --draft（你明确要求的）"
  git -C "$root" push origin "$tag"
  gh release create "$tag" --draft --prerelease \
    --title "$app_name $version" \
    --notes '只有 1v1 文字聊天是真被用过的；群聊 / 语音 / 附件线上数据全是 0。' \
    "$dmg"
  echo "草稿建好了 —— 最后那下「发布」仍然由人按。"
fi
