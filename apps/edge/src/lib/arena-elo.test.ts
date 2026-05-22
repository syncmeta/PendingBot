import { describe, it, expect } from 'vitest';
import { computeLeaderboard, ELO_START, type Comparison } from './arena-elo';

describe('computeLeaderboard', () => {
  it('returns empty standings for no comparisons', () => {
    expect(computeLeaderboard([])).toEqual([]);
  });

  it('ranks the consistent winner above the loser', () => {
    const cmp: Comparison[] = [
      { model_a: 'gpt', model_b: 'llama', outcome: 'a' },
      { model_a: 'gpt', model_b: 'llama', outcome: 'a' },
      { model_a: 'gpt', model_b: 'llama', outcome: 'a' },
    ];
    const board = computeLeaderboard(cmp);
    expect(board.map((s) => s.model_slug)).toEqual(['gpt', 'llama']);
    expect(board[0].rating).toBeGreaterThan(ELO_START);
    expect(board[1].rating).toBeLessThan(ELO_START);
    expect(board[0].wins).toBe(3);
    expect(board[1].losses).toBe(3);
  });

  it('keeps ratings equal after a single tie', () => {
    const board = computeLeaderboard([{ model_a: 'a', model_b: 'b', outcome: 'tie' }]);
    expect(board[0].rating).toBe(ELO_START);
    expect(board[1].rating).toBe(ELO_START);
    expect(board.every((s) => s.ties === 1)).toBe(true);
  });

  it('is symmetric — A beats B equals B loses to A regardless of side', () => {
    const left = computeLeaderboard([{ model_a: 'x', model_b: 'y', outcome: 'a' }]);
    const right = computeLeaderboard([{ model_a: 'y', model_b: 'x', outcome: 'b' }]);
    const ratingOf = (board: ReturnType<typeof computeLeaderboard>, slug: string) =>
      board.find((s) => s.model_slug === slug)!.rating;
    expect(ratingOf(left, 'x')).toBe(ratingOf(right, 'x'));
    expect(ratingOf(left, 'y')).toBe(ratingOf(right, 'y'));
  });

  it('ignores self-pairings', () => {
    const board = computeLeaderboard([{ model_a: 'solo', model_b: 'solo', outcome: 'a' }]);
    expect(board).toEqual([]);
  });

  it('beating a strong model gains more than beating a weak one', () => {
    // Build up "strong" as a clear winner, "weak" as a clear loser, then
    // have "challenger" beat each once and compare the rating it earns.
    const beatStrong: Comparison[] = [
      { model_a: 'strong', model_b: 'filler', outcome: 'a' },
      { model_a: 'strong', model_b: 'filler', outcome: 'a' },
      { model_a: 'challenger', model_b: 'strong', outcome: 'a' },
    ];
    const beatWeak: Comparison[] = [
      { model_a: 'weak', model_b: 'filler', outcome: 'b' },
      { model_a: 'weak', model_b: 'filler', outcome: 'b' },
      { model_a: 'challenger', model_b: 'weak', outcome: 'a' },
    ];
    const cAfterStrong = computeLeaderboard(beatStrong).find((s) => s.model_slug === 'challenger')!;
    const cAfterWeak = computeLeaderboard(beatWeak).find((s) => s.model_slug === 'challenger')!;
    expect(cAfterStrong.rating).toBeGreaterThan(cAfterWeak.rating);
  });
});
