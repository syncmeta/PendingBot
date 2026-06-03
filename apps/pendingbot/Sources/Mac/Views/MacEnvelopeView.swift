#if os(macOS)
import SwiftUI

/// T0.1 — macOS 来信 tab（#212）。中列 feed 列表 + detail 渲染奏折正文(body_md)。
/// 逻辑复用跨平台 `EnvelopeDataSource`。第一版:列表 + markdown 正文;无 realtime
/// (3s 轮询)、无 thinking-trace 实时流、无写信 compose。

// MARK: - 中列:来信 feed

struct MacEnvelopeColumn: View {
    @Binding var selectedEnvelopeId: String?

    @State private var envelopes: [EnvelopeRow] = []
    @State private var loadError: String?
    @State private var didLoad = false

    private let pollInterval: UInt64 = 3_000_000_000

    var body: some View {
        List(selection: $selectedEnvelopeId) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if envelopes.isEmpty && didLoad && loadError == nil {
                Text("还没有来信").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(envelopes) { e in
                HStack(spacing: 12) {
                    BrandAvatar(seed: e.senderSeed, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.title).font(.body).lineLimit(1)
                        if !e.summary.isEmpty {
                            Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else if e.status == "running" {
                            Text("正在写…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
                .tag(e.id)
            }
        }
        .navigationTitle("来信")
        .task { await pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                let fresh = try await EnvelopeDataSource.listEnvelopes()
                if fresh != envelopes { envelopes = fresh }
                loadError = nil
            } catch is CancellationError {
            } catch {
                loadError = error.localizedDescription
            }
            didLoad = true
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }
}

// MARK: - detail 列:奏折正文

struct MacEnvelopeDetail: View {
    let envelopeId: String

    @State private var envelope: EnvelopeRow?
    @State private var loadError: String?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let envelope {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(envelope.title).font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        if envelope.bodyMd.isEmpty {
                            Text(envelope.status == "running" ? "正在写…" : "(无正文)")
                                .foregroundStyle(.secondary)
                        } else {
                            markdownText(envelope.bodyMd)
                                .textSelection(.enabled)
                                .foregroundStyle(Color(hex: 0x1B1A14))
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(hex: 0xFDFCFA))
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

    @ViewBuilder
    private func markdownText(_ md: String) -> some View {
        if let attr = try? AttributedString(
            markdown: md,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
        } else {
            Text(md)
        }
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
#endif
