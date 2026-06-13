// SHIM for PendingBot Components/ServerImage.swift — internals route through CrewRemoteImage.
//
// PendingBot's ServerImage fetches auth-gated images via SupabaseStack JWT.
// PendingCrew has no Supabase — it talks only to the edge with a device-grant
// bearer. CrewRemoteImage (Sources/Mac/Support/CrewImageLoader.swift) already
// handles the auth-gated fetch via AppModel.imageAuth.
//
// Public init signature is IDENTICAL to PendingBot's ServerImage so that
// AttachmentGrid in the vendored BubbleView constructs it unchanged:
//
//   ServerImage(path: att.url, serverURL: serverURL, contentMode: .fill)
//
// The `serverURL` parameter is accepted but ignored — CrewRemoteImage uses
// AppModel.imageAuth.baseURL which is set from AppModel.apiBaseURL, and the
// path is the relative wire URL (e.g. `/v1/uploads/<id>`).
//
// macOS: delegates to CrewRemoteImage (NSImage-backed, actor-cached).
// iOS:   currently macOS-only app, but the shim compiles on iOS as a plain
//        placeholder so cross-platform Xcode targets don't fail.

import SwiftUI

struct ServerImage: View {
    let path: String
    let serverURL: URL
    var contentMode: ContentMode = .fit

    var body: some View {
        #if os(macOS)
        CrewRemoteImage(path: path, contentMode: contentMode)
        #else
        // iOS placeholder — PendingCrew is macOS-only for now.
        // Replace with a cross-platform image loader when iOS support lands.
        ZStack {
            Color.secondary.opacity(0.1)
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
        #endif
    }
}

/// Identifiable wrapper so a tapped image path can drive `.fullScreenCover`.
/// Vendored BubbleView's AttachmentGrid uses this. Defined here so it is
/// visible alongside ServerImage (its only consumer prior to A4).
///
/// NOTE: BubbleView.swift defines its own `private struct ZoomTarget` — when
/// BubbleView is copied in A4 the file-private definition will shadow this one
/// within that file. This top-level version is provided as a compile-time
/// anchor in case anything references it outside BubbleView; it causes no
/// conflict because the BubbleView copy is `private`.
// (No struct definition needed here — BubbleView defines ZoomTarget privately.)
