import SwiftUI

// T4.6 P1 Step 7 — child-crew summary strip. Driven off the already-loaded
// crew detail's `children: [CrewLinkV2]` (camelCase, no extra fetch).
// Tapping a card pushes the child crew's chat — the card IS the
// "enter child crew" affordance (spec leaves the entry point open). No
// auto-sync of child chat in P1 (§14 non-goal).
struct CrewChildSummaryStrip: View {
    let children: [CrewLinkV2]

    var body: some View {
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("子机组")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Metrics.gutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(children) { child in
                            NavigationLink {
                                CrewDetailV2View(crewId: child.crewId, fallbackTitle: child.title)
                            } label: {
                                CrewChildSummaryCard(link: child)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                }
            }
            .padding(.vertical, 6)
            .background(Theme.Palette.canvas)
        }
    }
}

struct CrewChildSummaryCard: View {
    let link: CrewLinkV2

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.sequence.fill")
                .font(.callout)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("子方保留 \(percent(link.childShareBps))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func percent(_ bps: Int) -> String {
        String(format: "%.1f%%", Double(bps) / 100.0)
    }
}
