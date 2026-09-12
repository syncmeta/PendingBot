// Source wiring only. Does not simulate SwiftUI, networking, or delivery.
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const root = '../apps/pendingbot/Sources/Features/Message/';
const read = name => readFileSync(new URL(root + name, import.meta.url), 'utf8');
const conversation = read('ConversationView.swift');
const list = read('MessageTabView.swift');
assert.match(conversation, /static let conversationMaterialized/);
assert.match(conversation, /post\(name: \.conversationMaterialized, object: conversation\)\s*await subscribeRealtime\(\)/);
assert.match(list, /publisher\(for: \.conversationMaterialized\)/);
assert.match(list, /created.user_id == AccountStore.shared.current\?\.id/);
assert.match(list, /!conversations.contains\(where: \{ \$0.id == created.id \}\)/);
console.log('Conversation materialization source wiring: PASS (5 checks; no UI/network test)');
