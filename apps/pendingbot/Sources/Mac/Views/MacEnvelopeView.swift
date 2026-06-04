#if os(macOS)
import SwiftUI

/// T0.1 — macOS 来信 tab（#212）。中列 feed 列表 + detail 渲染奏折正文(body_md)。
/// 逻辑复用跨平台 `EnvelopeDataSource`(查询)+ `RealtimeSocket`(RealtimeHub WS)。
///
/// UI 对齐 iOS `EnvelopeTabView` + `EnvelopeFeedRow` + `EnvelopeArticleView`:
/// feed 卡片(leading accent strip + kicker「发信人头像·名字·相对时间」+ hairline
/// + serif 标题 + 副标题 + 状态 pill),detail 走 editorial 抬头(serif 大标题 +
/// serif 副标 + hairline + byline「头像·名字·于 M月d日 HH:mm」)+ 文章版 markdown。
/// 文案逐字对 iOS。字体 `Theme.Fonts.*`、颜色 `Theme.Palette.*`。
///
/// Realtime 和 iOS `EnvelopeFeedChannel` 同一条通道:订阅 user topic
/// (`v1/realtime-hub/user`)、只挑 `envelope_runs` 行,任意 INSERT/UPDATE/DELETE
/// 即刷新列表 —— **不是轮询、不是 Supabase Realtime**。第一版:列表 + markdown
/// 正文;无 thinking-trace 实时流、无写信 compose。

// MARK: - 中列:来信 feed

struct MacEnvelopeColumn: View {
    @Binding var selectedEnvelopeId: String?

    @State private var envelopes: [EnvelopeRow] = []
    @State private var loadError: String?
    @State private var didLoad = false
    /// user-topic RealtimeHub socket,只用来监听 envelope_runs 变更触发刷新。
    @State private var socket: RealtimeSocket?

    var body: some View {
        List(selection: $selectedEnvelopeId) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.red)
                    .listRowSeparator(.hidden)
            }
            // 空态对齐 iOS EnvelopeTabView.EmptyState:envelope glyph + serif 标题
            // 「还没有来信」+ footnote 两行引导,文案逐字一致。
            if envelopes.isEmpty && didLoad && loadError == nil {
                MacEnvelopeEmptyState()
                    .listRowSeparator(.hidden)
                    .frame(maxWidth: .infinity)
            }
            ForEach(envelopes) { e in
                MacEnvelopeFeedRow(row: e)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .tag(e.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
        .navigationTitle("来信")
        .task {
            await refresh()
            didLoad = true
            // 订阅 user topic,挑 envelope_runs 行变更即刷新(和 iOS 同款逻辑)。
            let sock = RealtimeSocket(path: "v1/realtime-hub/user") { change in
                guard change.table == "envelope_runs" else { return }
                Task { @MainActor in await refresh() }
            }
            sock.start()
            socket = sock
        }
        .onDisappear {
            socket?.stop()
            socket = nil
        }
    }

    private func refresh() async {
        do {
            let fresh = try await EnvelopeDataSource.listEnvelopes()
            if fresh != envelopes { envelopes = fresh }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - feed 卡片(对齐 iOS EnvelopeFeedRow)

/// 一张来信卡片 —— 读起来像一封剪报/专栏:顶部 kicker(发信人 + 日期)、
/// hairline、serif 大标题、导语、非完成态的状态 pill。running 行在 leading
/// 边画一条 accent 细条表示「还在写」。对齐 iOS `EnvelopeFeedRow`。
private struct MacEnvelopeFeedRow: View {
    let row: EnvelopeRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // leading accent 细条 —— 仅 running 时点亮;无论如何都留固定宽度
            // gutter,保证标题对齐(对齐 iOS)。
            Rectangle()
                .fill(row.isRunning ? Theme.Palette.accent : Color.clear)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 14) {
                kickerRow
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 0.5)

                Text(displayTitle)
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if row.isRunning {
                    HStack(spacing: 6) {
                        MacTypingDots()
                        Text("正在写…")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                    }
                } else if !row.summary.isEmpty {
                    // 导语 / 副标 —— bot 刻意写的封面 deck,最多三行让一句
                    // 中文副标喘口气(对齐 iOS)。
                    Text(row.summary)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                }

                statusPill
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
    }

    // MARK: kicker(发信人 · 日期)

    @ViewBuilder
    private var kickerRow: some View {
        HStack(spacing: 8) {
            MacLetterSenderAvatar(row: row, size: 18)
            // Mac 暂无 bot/好友 display_name 解析通道(iOS 走 contacts 缓存 +
            // bots 表),所以这里只画 iOS 的 fallback 抬头「机器人 / 好友」,
            // 字体 / tracking / textCase 与 iOS 一致。display_name 解析留 gap。
            Text(row.isHuman ? "好友" : "机器人")
                .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.inkMuted)
                .textCase(.uppercase)
            Spacer(minLength: 4)
            if let stamp = relativeTime {
                Text(stamp)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: 状态 pill(仅非完成、非 running)

    @ViewBuilder
    private var statusPill: some View {
        if row.status == "error" {
            MacStatusPill(text: "写丢了", tone: .warning)
        } else if row.status == "cancelled" {
            MacStatusPill(text: "已中止", tone: .neutral)
        } else if row.status == "pending" && !row.isRunning {
            MacStatusPill(text: "排队中", tone: .neutral)
        } else {
            EmptyView()
        }
    }

    // MARK: derived

    /// 对齐 iOS `EnvelopeFeedRow.displayTitle`。
    private var displayTitle: String {
        if !row.title.isEmpty { return row.title }
        if row.isRunning { return "正在写来信…" }
        return "未命名来信"
    }

    private var relativeTime: String? {
        guard !row.createdAt.isEmpty,
              let date = ServerTimestamp.parse(row.createdAt) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 状态 pill(对齐 iOS EnvelopeFeedRow.StatusPill)

private struct MacStatusPill: View {
    enum Tone { case warning, neutral }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(bg))
    }

    private var fg: Color {
        switch tone {
        case .warning: return Theme.Palette.amber
        case .neutral: return Theme.Palette.inkMuted
        }
    }
    private var bg: Color {
        switch tone {
        case .warning: return Theme.Palette.amberBg
        case .neutral: return Theme.Palette.surfaceMuted
        }
    }
}

// MARK: - 发信人头像(对齐 iOS LetterSenderAvatar)

/// 预设「读我」信(trigger='example')署名 app 本身 —— 圆形 BrandMark;其余行
/// 回落到按 seed(bot_id / author_user_id)画的确定性 emoji 头像(`BrandAvatar`,
/// 跨平台,与 iOS `BotAvatar` 共用 `ColorHash`)。
private struct MacLetterSenderAvatar: View {
    let row: EnvelopeRow
    var size: CGFloat = 36

    var body: some View {
        if row.isPreset {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        } else {
            BrandAvatar(seed: row.senderSeed, size: size)
        }
    }
}

// MARK: - 正在写指示(对齐 iOS TypingDots)

/// 「正在写」三点脉冲 —— iOS `TypingDots`(`#if os(iOS)`)的 Mac 等价物,
/// 同款 label/字体/accent 色/动画节奏。默认 label 用来信语境的「正在写」。
private struct MacTypingDots: View {
    var label: String = "正在写"

    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.Palette.accent)
                        .frame(width: 3, height: 3)
                        .opacity(phase == i ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.25), value: phase)
                }
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - 空态(对齐 iOS EnvelopeTabView.EmptyState)

private struct MacEnvelopeEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.surface)
                    .frame(width: 88, height: 88)
                    .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                Image(systemName: "envelope")
                    .font(Theme.Fonts.glyph(size: 34, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
            }
            VStack(spacing: 8) {
                Text("还没有来信")
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("打开任意一个机器人对话，进入会话设置，\n请它写一封来信。")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - detail 列:奏折正文(对齐 iOS EnvelopeArticleView)

struct MacEnvelopeDetail: View {
    let envelopeId: String

    @State private var envelope: EnvelopeRow?
    @State private var loadError: String?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let envelope {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection(envelope)
                        bodySection(envelope)
                    }
                    .padding(.horizontal, Theme.Metrics.gutter + 4)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.Palette.canvas)
            } else if let loadError {
                ContentUnavailableView {
                    Label("打不开这封来信", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) }
            } else if !didLoad {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("来信不存在", systemImage: "envelope")
            }
        }
        .navigationTitle("来信")
        .task(id: envelopeId) { await reload() }
    }

    // MARK: 抬头(对齐 iOS EnvelopeArticleView.headerSection)

    /// editorial 抬头 —— serif 大标题、可选 serif 副标 deck、hairline、再一行
    /// byline:头像 + 名字在 leading,「于 5月10日 14:23」在其后(对齐 iOS)。
    @ViewBuilder
    private func headerSection(_ row: EnvelopeRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !row.title.isEmpty {
                Text(row.title)
                    .font(Theme.Fonts.serif(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }

            if !row.summary.isEmpty {
                Text(row.summary)
                    .font(Theme.Fonts.serif(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 0.5)

            HStack(alignment: .center, spacing: 10) {
                MacLetterSenderAvatar(row: row, size: 28)
                Text(senderLabel(row))
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let stamp = formattedTimestamp(row.createdAt) {
                    Text(stamp)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// byline 名字 —— 预设「读我」署名 app 本身;其余 Mac 暂无 display_name
    /// 解析通道,回落 iOS 同款「机器人 / 好友」。display_name 解析留 gap。
    private func senderLabel(_ row: EnvelopeRow) -> String {
        if row.isPreset { return EnvelopeRun.presetSenderName }
        return row.isHuman ? "好友" : "机器人"
    }

    /// 「于 5月10日 14:23」—— 中文 locale 月/日 + 24h 时间(对齐 iOS)。
    private func formattedTimestamp(_ raw: String) -> String? {
        guard !raw.isEmpty, let date = ServerTimestamp.parse(raw) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "于 " + f.string(from: date)
    }

    // MARK: 正文(对齐 iOS EnvelopeArticleView.bodySection)

    @ViewBuilder
    private func bodySection(_ row: EnvelopeRow) -> some View {
        if !row.bodyMd.isEmpty {
            MacArticleMarkdown(markdown: row.bodyMd)
        } else if row.isRunning {
            runningSection
        } else if row.status == "error" {
            Text("这封来信写丢了。可以从来信列表删掉重来。")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
        } else if row.status == "cancelled" {
            Text("这封来信被中止了。")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
        } else {
            Text("(无正文)")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
    }

    /// running 占位 —— Mac 暂不接 thinking-trace 实时流(iOS 走 progress/turns),
    /// 只给一句和 iOS 同款的「写好之后会出现在这里」引导 + typing dots。
    /// 完整 process 面板(notes / visitedURLs)留 gap。
    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                MacTypingDots()
            }
            Text("写好之后会出现在这里。可以离开这页，等会儿回来看。")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
        .padding(.top, 4)
    }

    private func reload() async {
        do {
            envelope = try await EnvelopeDataSource.loadEnvelope(id: envelopeId)
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        didLoad = true
    }
}

// MARK: - 文章版 markdown(对齐 iOS MarkdownText .article 版式)

/// 轻量 markdown 块渲染 —— iOS 用 MarkdownUI(UIKit-coupled,`#if os(iOS)`),
/// Mac 不引入,这里按行解析常见块(标题 / 段落 / 无序列表 / 引用 / 分隔线)+
/// inline(粗体 / 斜体 / 行内 code),版式贴 iOS `.article` 主题:正文 serif 17、
/// lineSpacing 7;标题 serif 渐进上间距;引用 accent 左条 + 斜体 inkMuted。
/// 表格 / 围栏代码块 / 数学 / 引用脚注未做(对齐说明:Mac markdown 子集),留 gap。
private struct MacArticleMarkdown: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // ── 块模型 ────────────────────────────────────────────────────────────

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case quote(String)
        case rule
    }

    /// 极简块解析:按空行 / 行首标记切块。够覆盖 bot 来信常见的标题 + 段落 +
    /// 列表 + 引用结构;复杂嵌套交回段落兜底,不崩。
    private var blocks: [Block] {
        var result: [Block] = []
        var paragraphLines: [String] = []
        var bulletLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraphLines = []
        }
        func flushBullets() {
            if !bulletLines.isEmpty { result.append(.bullet(bulletLines)) }
            bulletLines = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); flushBullets()
                continue
            }
            // 分隔线 --- / *** / ___
            if line == "---" || line == "***" || line == "___" {
                flushParagraph(); flushBullets()
                result.append(.rule)
                continue
            }
            // ATX 标题 # … ######
            if let h = headingLevel(line) {
                flushParagraph(); flushBullets()
                let text = String(line.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: h, text: text))
                continue
            }
            // 无序列表 - / * / +
            if let item = bulletItem(line) {
                flushParagraph()
                bulletLines.append(item)
                continue
            }
            // 引用 >
            if line.hasPrefix(">") {
                flushParagraph(); flushBullets()
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                result.append(.quote(text))
                continue
            }
            flushBullets()
            paragraphLines.append(rawLine)
        }
        flushParagraph(); flushBullets()
        return result
    }

    private func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    // ── 块渲染 ────────────────────────────────────────────────────────────

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, headingTop(level))
                .padding(.bottom, headingBottom(level))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            inline(text)
                .font(Theme.Fonts.serif(size: 17, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(Theme.Fonts.serif(size: 17, weight: .regular))
                            .foregroundStyle(Theme.Palette.inkMuted)
                        inline(item)
                            .font(Theme.Fonts.serif(size: 17, weight: .regular))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineSpacing(7)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 18)
        case .quote(let text):
            inline(text)
                .font(Theme.Fonts.serif(size: 17, weight: .regular))
                .italic()
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Palette.accent.opacity(0.55))
                        .frame(width: 2)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            HStack {
                Spacer()
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(width: 64, height: 0.5)
                Spacer()
            }
            .padding(.vertical, 12)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Theme.Fonts.serif(size: 26, weight: .semibold)
        case 2: return Theme.Fonts.serif(size: 22, weight: .semibold)
        default: return Theme.Fonts.serif(size: 18, weight: .semibold)
        }
    }
    private func headingTop(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 32
        default: return 24
        }
    }
    private func headingBottom(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 10
        case 2: return 8
        default: return 6
        }
    }

    /// inline 解析:粗体 **/__、斜体 */_、行内 `code`。用 AttributedString 的
    /// markdown inline 解析(保留空白),失败回落纯文本。serif 字体由外层 .font 决定;
    /// code 段用 surfaceMuted 底色提示(AttributedString 的 inlinePresentation)。
    private func inline(_ text: String) -> Text {
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attr)
        }
        return Text(text)
    }
}
#endif
