struct PendingCrewAuthCredential {
    enum Kind {
        case deviceGrant
        case debugUserJWT
    }

    let kind: Kind
    let token: String

    static func resolve(
        deviceGrantToken: String?,
        debugUserJWT: String?,
        allowDebugUserJWT: Bool
    ) -> PendingCrewAuthCredential? {
        if let token = clean(deviceGrantToken), token.hasPrefix("pdg_") {
            return PendingCrewAuthCredential(kind: .deviceGrant, token: token)
        }
        if allowDebugUserJWT, let token = clean(debugUserJWT) {
            return PendingCrewAuthCredential(kind: .debugUserJWT, token: token)
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
