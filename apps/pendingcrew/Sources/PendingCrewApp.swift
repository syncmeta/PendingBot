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

// MacThreePaneView 实现挪到 Mac/Views/MacRootView.swift。
