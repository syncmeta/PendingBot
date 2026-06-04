import { describe, it, expect } from 'vitest';
import {
  computeLeaderboard,
  RATING_CENTER,
  type Comparison,
} from './arena-bradley-terry';

describe('computeLeaderboard (Bradley-Terry)', () => {
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
    expect(board[0].rating).toBeGreaterThan(RATING_CENTER);
    expect(board[1].rating).toBeLessThan(RATING_CENTER);
    expect(board[0].wins).toBe(3);
    expect(board[1].losses).toBe(3);
    expect(board[0].games).toBe(3);
  });

  it('keeps ratings equal after a single tie', () => {
    const board = computeLeaderboard([{ model_a: 'a', model_b: 'b', outcome: 'tie' }]);
    expect(board[0].rating).toBe(board[1].rating);
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

  it('is order-independent — the BT fit ignores vote sequence (Elo did not)', () => {
    const forward: Comparison[] = [
      { model_a: 'gpt', model_b: 'llama', outcome: 'a' },
      { model_a: 'llama', model_b: 'mistral', outcome: 'a' },
      { model_a: 'gpt', model_b: 'mistral', outcome: 'a' },
    ];
    const shuffled: Comparison[] = [forward[2], forward[0], forward[1]];
    const ratingsOf = (cmp: Comparison[]) =>
      Object.fromEntries(computeLeaderboard(cmp).map((s) => [s.model_slug, s.rating]));
    expect(ratingsOf(forward)).toEqual(ratingsOf(shuffled));
  });

  it('beating a stronger model earns more than beating a weaker one', () => {
    // 'strong' wins all its games, 'weak' loses all of its, then 'challenger'
    // beats each once. BT should credit the win over 'strong' more.
    const beatStrong: Comparison[] = [
      { model_a: 'strong', model_b: 'filler', outcome: 'a' },
      { model_a: 'strong', model_b: 'filler2', outcome: 'a' },
      { model_a: 'challenger', model_b: 'strong', outcome: 'a' },
    ];
    const beatWeak: Comparison[] = [
      { model_a: 'weak', model_b: 'filler', outcome: 'b' },
      { model_a: 'weak', model_b: 'filler2', outcome: 'b' },
      { model_a: 'challenger', model_b: 'weak', outcome: 'a' },
    ];
    const cAfterStrong = computeLeaderboard(beatStrong).find((s) => s.model_slug === 'challenger')!;
    const cAfterWeak = computeLeaderboard(beatWeak).find((s) => s.model_slug === 'challenger')!;
    expect(cAfterStrong.rating).toBeGreaterThan(cAfterWeak.rating);
  });

  it('produces a finite rating for a winless model', () => {
    const board = computeLeaderboard([
      { model_a: 'winner', model_b: 'loser', outcome: 'a' },
      { model_a: 'winner', model_b: 'loser', outcome: 'a' },
    ]);
    const loser = board.find((s) => s.model_slug === 'loser')!;
    expect(Number.isFinite(loser.rating)).toBe(true);
    expect(loser.rating).toBeLessThan(board.find((s) => s.model_slug === 'winner')!.rating);
  });

  it('ranks a transitive chain in the right order', () => {
    // a > b > c, established directly. BT should recover a > b > c.
    const cmp: Comparison[] = [
      { model_a: 'a', model_b: 'b', outcome: 'a' },
      { model_a: 'a', model_b: 'b', outcome: 'a' },
      { model_a: 'b', model_b: 'c', outcome: 'a' },
      { model_a: 'b', model_b: 'c', outcome: 'a' },
    ];
    const board = computeLeaderboard(cmp);
    expect(board.map((s) => s.model_slug)).toEqual(['a', 'b', 'c']);
  });
});
