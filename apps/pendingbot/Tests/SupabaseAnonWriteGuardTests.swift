import Foundation

// Standalone tests for `SupabaseAnonWriteGuard.isAnonWrite` — the predicate
// that decides whether a request is a login-required PostgREST write still
// carrying only the publishable key.
//
// Same pattern (and same reason) as ModelRevealPolicyTests: the guard imports
// nothing but Foundation + OSLog, so swiftc can exercise it in ~2s with no
// simulator. Run: Tests/run-supabase-anon-write-guard-tests.sh
//
// What matters here is the *shape* of the decision, both directions: a false
// negative silently reopens the bug we misdiagnosed twice, and a false
// positive breaks working traffic.

let anonKey = "sb_publishable_TESTKEY"
let userJWT = "eyJhbGciOiJIUzI1NiJ9.someuserjwt.signature"

var failures = 0

func expect(_ actual: Bool, _ expected: Bool, _ what: String) {
    if actual == expected {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what) — expected \(expected), got \(actual)")
        failures += 1
    }
}

func request(
    _ method: String,
    _ path: String,
    auth: String? = "Bearer \(anonKey)"
) -> URLRequest {
    var r = URLRequest(url: URL(string: "https://project.supabase.co\(path)")!)
    r.httpMethod = method
    if let auth { r.setValue(auth, forHTTPHeaderField: "Authorization") }
    return r
}

@main
struct SupabaseAnonWriteGuardTests {
    static func main() {
        SupabaseAnonWriteGuard.arm(publishableKey: anonKey)

        print("trips on anon table writes:")
        for method in ["POST", "PATCH", "PUT", "DELETE", "post", "delete"] {
            expect(
                SupabaseAnonWriteGuard.isAnonWrite(request(method, "/rest/v1/messages")),
                true,
                "\(method) /rest/v1/messages with anon key"
            )
        }

        print("lets legitimate traffic through:")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(
                request("POST", "/rest/v1/messages", auth: "Bearer \(userJWT)")),
            false,
            "same write once a real user token is attached")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(request("GET", "/rest/v1/messages")),
            false,
            "anon read — comes back empty, which reads honestly")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(request("POST", "/rest/v1/rpc/list_bot_invitees")),
            false,
            "rpc POST — read/write indistinguishable at this layer, deliberately out")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(request("POST", "/auth/v1/otp")),
            false,
            "auth endpoint — anon there is how you sign in")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(request("POST", "/storage/v1/object/avatars/x")),
            false,
            "storage endpoint — not the shape this guard is about")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(request("POST", "/rest/v1/messages", auth: nil)),
            false,
            "no Authorization header at all — not the anon-degradation shape")

        print("stays inert until armed:")
        SupabaseAnonWriteGuard.arm(publishableKey: "")
        expect(
            SupabaseAnonWriteGuard.isAnonWrite(request("POST", "/rest/v1/messages")),
            false,
            "unarmed guard never claims a request")

        if failures == 0 {
            print("\nall SupabaseAnonWriteGuard tests passed")
        } else {
            print("\n\(failures) failure(s)")
            exit(1)
        }
    }
}
