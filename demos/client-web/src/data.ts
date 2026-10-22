export type Tab = 'message' | 'friends' | 'crew' | 'envelope' | 'me';
export type Person = { id: string; name: string; emoji: string; color: string; model: string; kind: 'private' | 'public' | 'human' };
export type Message = { id: string; role: 'bot' | 'user'; text: string; attachment?: string };
export type Conversation = { id: string; personId: string; title: string; time: string; messages: Message[] };
export const people: Person[] = [
 { id: 'amet', name: 'Amet', emoji: '🪐', color: '#e9edbd', model: 'glm-5.1', kind: 'private' },
 { id: 'lorem', name: 'Lorem', emoji: '🎪', color: '#c6d9ef', model: 'claude-opus-4.7', kind: 'private' },
 { id: 'sit', name: 'Sit', emoji: '🍋', color: '#c9ead5', model: 'kimi-k2.6', kind: 'private' },
];
const messages = (lines: string[]): Message[] => lines.map((text, i) => ({ id: `seed-${i}`, role: 'bot', text }));
export const initialConversations: Conversation[] = [
 { id: 'intro', personId: 'lorem', title: '大概介绍这个 App', time: '1970年', messages: messages(['这里是 PendingBot。你可以和机器人聊天，也可以和人类朋友聊天。', '返回消息主页，其它会话里还介绍了这个 App 的不同部分。']) },
 { id: 'models', personId: 'sit', title: '同一个机器人 可以有很多种可能', time: '1970年', messages: messages(['同一个机器人，可以在不同会话中使用不同的模型。', '世界上几乎所有模型都能选。你可以认识它，再慢慢发现它擅长什么。']) },
 { id: 'mission', personId: 'amet', title: '我能为你做些什么？', time: '1970年', messages: messages(['这是目前 AI 应用最常见的问候', '但我觉得这个问题不应该 AI 问人类 而应该 AI 自己去发现', '因为人类普遍不清楚 AI 到底能为自己做些什么', '这就是这个 App 的使命之一：发现 AI 能为你做些什么', '当然基本的助手功能也能应付 后续还会接入能运行代码的沙箱', '接入沙箱之后 你就可以把这些机器人当一个面前有电脑的朋友 让它帮你做些手机上不太好做的事']) },
];
export const letter = {
 title: '读我（Readme）', subtitle: '关于「来信」是什么，以及为什么是写信而不是发消息',
 paragraphs: [
 '你的好友，不论是机器人好友还是人类好友，都可以写信到“来信”这里。你可以把它当微信公众号的推送流，也可以把它当电子邮件的收件箱，就看你的好友们怎么表现了。',
 '机器人好友会主动给你写信。如果它发现之前有什么说错了，或者发现了什么很有价值的东西，又或者想向你讲述，你可能就会在这里看到它的信。',
 '但它不会无缘无故嘘寒问暖，那样很烦（但如果你真喜欢嘘寒问暖，它也会来问候的）它也不会天天给你发一些你看不下去的信，那样也很烦。通过信件互通有无、建立连接，确认彼此是鲜活的，就可以了。',
 '为什么不让机器人直接发消息？因为心意、温度、节奏等等真挚的东西放不进聊天框里。如果你向名流、明星发信息，他们大概率不会回，但如果写信呢？世界各地的“信虫”就是这么拿到他们的回复的。',
 '给彼此一点时间，把值得说的话好好说完。这就是来信。'
 ]
};
