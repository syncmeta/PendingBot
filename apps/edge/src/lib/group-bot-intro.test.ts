import { describe, it, expect } from 'vitest';
import { botsMissingDescriptions } from './group-bot-intro';

// Todo #20 的回归护栏。
//
// 病根:群调度器唯一的判据是每只机器人在本群的「什么话题该叫我」;建群时一次性
// 带进来的机器人从来不生成这份介绍,于是调度器每一轮都合规地返回空名单 ——
// 群永远安静、不报错、界面上什么都没有。线上 `group_bot_descriptions` 全表 0 行。
//
// 这里考的是补齐逻辑的选择判据:**"谁还缺介绍"必须算得准**。算多了浪费一次小
// 模型调用,算少了就是有机器人继续瞎着 —— 而瞎着的后果是静默的。
describe('botsMissingDescriptions', () => {
  it('全都没有介绍时,一个不漏', () => {
    expect(botsMissingDescriptions(['a', 'b', 'c'], [])).toEqual(['a', 'b', 'c']);
  });

  it('已经有介绍的不重复生成', () => {
    expect(botsMissingDescriptions(['a', 'b', 'c'], ['b'])).toEqual(['a', 'c']);
  });

  it('全都有介绍时返回空 —— 补齐过的群后续不再花钱', () => {
    expect(botsMissingDescriptions(['a', 'b'], ['a', 'b'])).toEqual([]);
  });

  it('参与者列表里的重复只算一次', () => {
    expect(botsMissingDescriptions(['a', 'a', 'b'], [])).toEqual(['a', 'b']);
  });

  it('顺序跟着参与者走,结果稳定', () => {
    expect(botsMissingDescriptions(['c', 'a', 'b'], ['a'])).toEqual(['c', 'b']);
  });

  it('介绍表里有本群已经没有的机器人时,不影响判断', () => {
    expect(botsMissingDescriptions(['a'], ['a', 'zombie'])).toEqual([]);
  });

  it('空群 / 空输入不炸', () => {
    expect(botsMissingDescriptions([], [])).toEqual([]);
    expect(botsMissingDescriptions([], ['a'])).toEqual([]);
  });

  it('空字符串 id 被忽略,不会拿去调模型', () => {
    expect(botsMissingDescriptions(['', 'a'], [])).toEqual(['a']);
  });
});
