// Execute the production handler/reconciliation statements with value fixtures.
// SwiftUI lifecycle and remote delivery remain outside this test.
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../apps/pendingbot/Sources/Features/Message/MessageTabView.swift', import.meta.url), 'utf8');
const ingest = source.match(/\.onReceive\(NotificationCenter.default.publisher\(for: \.conversationMaterialized\)\) \{ notification in([\s\S]*?)\n        \}\n        \.task/)[1];
let merge = source.match(/            let serverRows = convFetched.map[\s\S]*?(?=            \/\/ Only reassign)/)[0];
if (process.env.MUTATE_DROP_PENDING === '1') merge = merge.replace('serverRows + recentCreations.values.map(\\.row)', 'serverRows');
const deletion = source.match(/            conversations.removeAll \{ \$0.id == conv.id \}\n            recentCreations.removeValue\(forKey: conv.id\)/)[0];
const swift = `
import Foundation
struct Conversation: Equatable {
 let id: String; let user_id: String; let last_activity_at: Int
 var asConversation: Self { self }
}
final class AccountStore {
 static let shared = AccountStore()
 var current: Account? = Account(id: "me")
 struct Account { let id: String }
}
final class Harness {
 var conversations: [Conversation] = []
 var recentCreations: [String: (row: Conversation, expires: Date)] = [:]
 func ingest(_ notification: Notification) { ${ingest} }
 func reconcile(_ convFetched: [Conversation]) -> [Conversation] { ${merge}; conversations = fresh; return fresh }
 func delete(_ conv: Conversation) { ${deletion} }
}
let h = Harness()
let a = Conversation(id: "a", user_id: "me", last_activity_at: 2)
let b = Conversation(id: "b", user_id: "me", last_activity_at: 1)
func emit(_ row: Conversation) { h.ingest(Notification(name: Notification.Name("created"), object: row)) }
emit(a); assert(h.conversations == [a])
emit(a); assert(h.conversations.count == 1)
assert(h.reconcile([b]) == [a,b], "older snapshot must retain creation")
assert(h.reconcile([a,b]) == [a,b]); assert(h.recentCreations.isEmpty)
h.conversations = []; emit(a); h.delete(a)
assert(h.reconcile([]).isEmpty, "deleted creation must not return")
emit(a); h.recentCreations[a.id] = (a, Date.distantPast)
assert(h.reconcile([]).isEmpty, "expired entry must yield to server")
emit(Conversation(id: "", user_id: "me", last_activity_at: 3)); assert(h.conversations.isEmpty)
emit(Conversation(id: "other", user_id: "other", last_activity_at: 3)); assert(h.conversations.isEmpty)
emit(a); AccountStore.shared.current = .init(id: "other")
assert(h.reconcile([]).isEmpty, "account switch must drop pending rows")
print("Materialized merge runtime: PASS")
`;
const run = spawnSync('swift', ['-module-cache-path', '/private/tmp/pendingbot-materialized-test-cache', '-'], {input: swift, encoding: 'utf8'});
process.stdout.write(run.stdout ?? '');
process.stderr.write(run.stderr ?? '');
assert.equal(run.status, 0, 'Swift production-statement regression failed');
