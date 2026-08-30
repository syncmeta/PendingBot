import SwiftUI

struct MessageSearchView: View {
    let conversationId: String?
    let onSelect: (MessageSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MessageSearchResult] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?

    private var isGlobal: Bool { conversationId == nil }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        isGlobal ? "搜索全部对话" : "搜索当前对话",
                        systemImage: "magnifyingglass",
                        description: Text("可搜索正文、发送者、附件名称和时间")
                    )
                } else if loading && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(results) { result in
                            Button {
                                Haptics.tap()
                                onSelect(result)
                                dismiss()
                            } label: {
                                MessageSearchResultRow(result: result, showsConversation: isGlobal)
                            }
                            .buttonStyle(.plain)
                        }
                        if nextCursor != nil {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                HStack {
                                    Spacer()
                                    if loadingMore {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("加载更多")
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(loadingMore)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle(isGlobal ? "搜索消息" : "搜索当前对话")
            .searchable(text: $query, placement: .automatic, prompt: "输入关键词")
            .task(id: query) { await searchAfterDebounce() }
            .alert("搜索失败", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func searchAfterDebounce() async {
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            results = []
            nextCursor = nil
            loading = false
            return
        }
        loading = true
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            let response = try await APIClient().searchMessages(
                query: requested,
                conversationId: conversationId
            )
            try Task.checkCancellation()
            results = response.results
            nextCursor = response.nextCursor
        } catch is CancellationError {
            return
        } catch {
            results = []
            nextCursor = nil
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let response = try await APIClient().searchMessages(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                conversationId: conversationId,
                cursor: cursor
            )
            let known = Set(results.map(\.id))
            results.append(contentsOf: response.results.filter { !known.contains($0.id) })
            nextCursor = response.nextCursor
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MessageSearchResultRow: View {
    let result: MessageSearchResult
    let showsConversation: Bool

    private var date: Date {
        Date(timeIntervalSince1970: TimeInterval(
            ServerTimestamp.epochSeconds(result.createdAt, default: 0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if showsConversation {
                    Text(result.conversationTitle)
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                Text(result.senderName)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            if !result.text.isEmpty {
                Text(result.text)
                    .font(Theme.Fonts.system(size: 15))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            if !result.attachmentMetadata.isEmpty {
                Text(result.attachmentMetadata.map {
                    $0.filename?.isEmpty == false ? $0.filename! : $0.mimeType
                }.joined(separator: " · "))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
