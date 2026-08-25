import SwiftUI
#if os(iOS)
import UIKit
#endif

/// WeChat-style "+" action panel for the chat composer. Renders inline
/// below the input row (iMessage / WeChat style), so tapping the
/// composer's "+" pushes the input up and reveals this panel where the
/// keyboard would have been. `onDismiss` lets the host close the panel
/// (e.g. after a photo pick) without the panel needing its own modal
/// context.
///
/// Slimmed down — model picker + skills moved out to BotConfigView (the
/// gear icon in the chat header now lands there directly for bot chats;
/// human chats go to ContactSettingsView, group chats to GroupSettingsView).
/// The remaining tiles are the per-message attach actions: 图片 (library)
/// and 拍照 (camera), plus the conv-dependent 检查 / 猜模型 / 换模型 entries.
///
/// 格子用自适应网格排,**会随可用宽度换行**(Todo #22)。tile 数量是变的
/// (3~6 个,看这个 conv 给不给 lookback / 盲盒入口),所以行数也是变的 ——
/// 面板高度因此只能给下限,不能钉死,见 `ComposerView` 那个 `minHeight`。
struct ChatActionSheet: View {
    /// Tapping the "图片" tile calls this; the host presents `.photosPicker`.
    var onPickPhoto: () -> Void = {}
    /// Tapping the "拍照" tile calls this; the host presents the camera cover.
    var onPickCamera: () -> Void = {}
    /// Tapping the "文件" tile calls this; the host presents the system
    /// document picker (any file type).
    var onPickFile: () -> Void = {}
    var onDismiss: () -> Void = {}
    /// When non-nil, renders a "检查" tile that manually fires a lookback
    /// on the current conv. Nil for conv types without a single bot (group,
    /// user_user) — those skip the tile entirely.
    var onLookback: (() -> Void)? = nil
    /// 盲盒「猜模型」入口。仅当 conv 是未揭晓的 surprise 盲盒时 ConversationView
    /// 才传非 nil（见 `shouldOfferGuess`）；其余情况隐藏该 tile。
    var onGuessModel: (() -> Void)? = nil
    /// 盲盒「换模型」入口。任何带 bot 的 conv 都可换，所以 ConversationView 总传。
    var onSwitchModel: (() -> Void)? = nil

    // All pickers (photo / camera / file) are presented by the host from the
    // main view tree via bindings, not from here — this panel lives inside the
    // composer's inputAccessoryView, and presenting a sheet / fullScreenCover
    // from a hosting controller embedded in the accessory is unreliable.

    /// 一个格子的宽度 / 格子之间的间距。网格按这两个数算一行能放几个。
    private static let tileWidth: CGFloat = 64
    private static let tileSpacing: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            // 自适应网格,不是横排 —— 满配 6 个格子要 6×64 + 5×18 = 474 点,
            // 而 iPhone 可用宽度只有 393 − 2×16 = 361 点。原来那个 HStack
            // **没有换行这个能力**,超出去的部分直接溢出屏幕两侧(作者 Todo #22
            // 的截图里左右各露半个格子,就是这个)。
            //
            // `.adaptive(minimum:maximum:)` 两头都钉死在 64:一行放得下几个由
            // 可用宽度决定,放不下就自己换行,而格子本身不会被拉宽变形。
            // 用原生网格而不是手写流式布局 —— 本仓库的规矩是能不自绘就不自绘。
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth),
                                   spacing: Self.tileSpacing,
                                   alignment: .top)],
                alignment: .leading,
                spacing: Self.tileSpacing
            ) {
                Button {
                    Haptics.tap()
                    onPickPhoto()
                    onDismiss()
                } label: {
                    actionTileLabel(icon: "photo.on.rectangle.angled", label: "图片")
                }
                .buttonStyle(.plain)

                #if os(iOS)
                // Camera capture is iOS-only — Macs have no camera path
                // (UIImagePickerController is unavailable on macOS).
                Button {
                    Haptics.tap()
                    onPickCamera()
                    onDismiss()
                } label: {
                    actionTileLabel(icon: "camera", label: "拍照")
                }
                .buttonStyle(.plain)
                #endif

                Button {
                    Haptics.tap()
                    onPickFile()
                    onDismiss()
                } label: {
                    actionTileLabel(icon: "doc", label: "文件")
                }
                .buttonStyle(.plain)

                if let onLookback {
                    Button {
                        Haptics.tap()
                        onLookback()
                        onDismiss()
                    } label: {
                        actionTileLabel(icon: "checkmark.seal", label: "检查")
                    }
                    .buttonStyle(.plain)
                }

                if let onGuessModel {
                    Button {
                        Haptics.tap()
                        onGuessModel()
                        onDismiss()
                    } label: {
                        actionTileLabel(icon: "questionmark.app", label: "猜模型")
                    }
                    .buttonStyle(.plain)
                }

                if let onSwitchModel {
                    Button {
                        Haptics.tap()
                        onSwitchModel()
                        onDismiss()
                    } label: {
                        actionTileLabel(icon: "cube.transparent", label: "换模型")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 18)
            .padding(.bottom, 18)

            Spacer(minLength: 0)
        }
        .background(Theme.Palette.canvas)
    }

    private func actionTileLabel(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(Theme.Fonts.glyph(size: 22, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
            Text(label)
                .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 64)
    }
}

#if os(iOS)
/// Thin UIImagePickerController wrapper for the camera. PhotosPicker is
/// already used for library selection; UIKit's picker is the cleanest
/// way to get a one-shot camera capture without dragging in AVFoundation.
/// iOS-only — `UIImagePickerController` doesn't exist on macOS and Macs
/// have no camera capture path here.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            onPick(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}
#endif
