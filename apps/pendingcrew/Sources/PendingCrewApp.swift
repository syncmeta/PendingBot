import SwiftUI

@main
struct PendingCrewApp: App {
    @StateObject private var model: AppModel
    @StateObject private var crewStore: CrewStore

    init() {
        let appModel = AppModel()
        _model = StateObject(wrappedValue: appModel)
        _crewStore = StateObject(wrappedValue: CrewStore(appModel: appModel))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(crewStore)
                #if os(macOS)
                .frame(minWidth: 1040, minHeight: 680)
                #endif
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var crewStore: CrewStore

    var body: some View {
        Group {
            if model.isAuthenticated {
                authenticatedRoot
            } else {
                LoginView()
            }
        }
        // 登出时清空 crew 缓存；登入时 view 自己负责按需 refresh。
        .onChange(of: model.isAuthenticated) { _, isAuth in
            if !isAuth { crewStore.reset() }
        }
    }

    @ViewBuilder
    private var authenticatedRoot: some View {
        #if os(iOS)
        IPadPlaceholderView()
        #else
        MacThreePaneView()
        #endif
    }
}

#if os(iOS)
struct IPadPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("PendingCrew iPad")
                .font(.largeTitle)
            Text("等待 peer / Fly machine 连接\n(scaffold — Phase 4.5 / v1.1 上线)")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

#if os(macOS)
struct MacThreePaneView: View {
    @State private var selectedCrew: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCrew) {
                Section("Crew") {
                    Text("(scaffold — 等 Phase 2)")
                        .foregroundStyle(.secondary)
                }
                Section("标签") {
                    Text("(scaffold)")
                        .foregroundStyle(.secondary)
                }
                Section("Runner Hosts") {
                    Text("(scaffold — 等 Phase 3)")
                        .foregroundStyle(.secondary)
                }
                Section("Machines") {
                    Text("(scaffold — 等 v1.1)")
                        .foregroundStyle(.secondary)
                }
                Section("设置") {
                    Text("(scaffold)")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .navigationTitle("PendingCrew")
        } content: {
            VStack(spacing: 12) {
                Text("Crew 群聊")
                    .font(.title2.weight(.semibold))
                Text("(scaffold — 等 Phase 2-3 实装)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            VStack(spacing: 12) {
                Text("Session 窗口")
                    .font(.title2.weight(.semibold))
                Text("(scaffold — 等 Phase 3 实装 Claude Code / Codex)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
