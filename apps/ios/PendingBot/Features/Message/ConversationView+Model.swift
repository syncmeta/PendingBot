import Foundation

// Model-pick + PATCH plumbing for the conversation settings sheet.
//   /v1/conversations/:id  — per-conv `model_slug`     (chat model)
//   /v1/conversations/:id  — per-conv `vision_model_slug`
//   /v1/conversations/:id  — per-conv `voice_model_slug`
//   /v1/bots/:id          — bot's default `model_id`   (broader scope)

extension ConversationView {

    /// Apply a model pick from the settings sheet. The user chose a scope:
    ///   - `.conversation` — only this conversation; pins or replaces the
    ///     per-conversation override on the server.
    ///   - `.bot` — replace the bot's default model (server updates
    ///     bots.model_id directly). Also clears any per-conv pin here so
    ///     this conversation picks up the new default.
    /// Both scopes require a non-nil slug — picker no longer offers a
    /// "follow default" affordance.
    func applyModelPick(slug: String?, scope: ModelPickScope) async {
        guard let normalized = slug.flatMap({ $0.isEmpty ? nil : $0 }) else { return }
        switch scope {
        case .conversation:
            modelOverride = normalized
            await patchConversationModel(slug: normalized)
        case .bot:
            modelOverride = ""
            await patchConversationModel(slug: nil)
            await patchBotDefaultModel(slug: normalized)
        }
    }

    func patchConversationModel(slug: String?) async {
        guard let api else { return }
        struct Body: Encodable { let model_slug: String? }
        do {
            try await api.patchVoid("v1/conversations/\(conversation.id)",
                                    body: Body(model_slug: slug))
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// PATCH the per-conv vision-model pin (0064). nil = auto. Server
    /// re-uses the model-pin gate (private bot creator only).
    func patchConversationVisionModel(slug: String?) async {
        guard let api else { return }
        struct Body: Encodable { let vision_model_slug: String? }
        do {
            try await api.patchVoid("v1/conversations/\(conversation.id)",
                                    body: Body(vision_model_slug: slug))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// PATCH the per-conv realtime voice-model pin. nil = follow the
    /// bot's default. Server re-uses the model-pin gate (private bot
    /// creator only).
    func patchConversationVoiceModel(slug: String?) async {
        guard let api else { return }
        struct Body: Encodable { let voice_model_slug: String? }
        do {
            try await api.patchVoid("v1/conversations/\(conversation.id)",
                                    body: Body(voice_model_slug: slug))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// PATCH the bot's default model. Server gates: only the creator of a
    /// private bot can call this — public/preset bots are read-only.
    func patchBotDefaultModel(slug: String) async {
        guard let api, !conversation.bot_id.isEmpty else { return }
        struct Body: Encodable { let model_id: String }
        do {
            try await api.patchVoid("v1/bots/\(conversation.bot_id)",
                                    body: Body(model_id: slug))
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
