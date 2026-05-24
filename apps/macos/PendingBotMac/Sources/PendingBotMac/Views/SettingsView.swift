import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("连接") {
                TextField("API URL", text: $model.apiBaseURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("登录 JWT", text: $model.authToken)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("保存") {
                    model.saveSettings()
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut(.defaultAction)

                Button("清空 Token") {
                    model.authToken = ""
                    model.saveSettings()
                }
            }
        }
        .padding(20)
    }
}

