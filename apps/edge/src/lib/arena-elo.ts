// Personal model leaderboard from pairwise comparisons (类 arena.ai).
//
// We replay sequential Elo over the user's comparison log rather than
// keeping a denormalised rating column: a personal log is small (dozens to
// hundreds of votes), replay is O(n), and there's no incremental-update
// state to drift out of sync. Order matters — Elo is path-dependent — so
// callers must pass comparisons oldest-first.

export type Outcome = 'a' | 'b' | 'tie';

export interface Comparison {
  model_a: string;
  model_b: string;
  outcome: Outcome;
}

export interface Standing {
  model_slug: string;
  rating: number;
  games: number;
  wins: number;
  losses: number;
  ties: number;
}

export const ELO_START = 1000;
export const ELO_K = 32;

function expected(ra: number, rb: number): number {
  return 1 / (1 + 10 ** ((rb - ra) / 400));
}

interface Acc {
  rating: number;
  games: number;
  wins: number;
  losses: number;
  ties: number;
}

// Replay the comparisons and return standings sorted by rating desc, then
// by games desc (a model with the same rating but more games ranks first),
// then by slug for a stable order.
export function computeLeaderboard(comparisons: Comparison[]): Standing[] {
  const table = new Map<string, Acc>();
  const get = (slug: string): Acc => {
    let a = table.get(slug);
    if (!a) {
      a = { rating: ELO_START, games: 0, wins: 0, losses: 0, ties: 0 };
      table.set(slug, a);
    }
    return a;
  };

  for (const c of comparisons) {
    // A self-pairing (same model on both sides) carries no signal — skip it
    // so it can't inflate game counts or nudge a rating against itself.
    if (c.model_a === c.model_b) continue;
    const A = get(c.model_a);
    const B = get(c.model_b);
    const ea = expected(A.rating, B.rating);
    const eb = 1 - ea;
    const sa = c.outcome === 'a' ? 1 : c.outcome === 'tie' ? 0.5 : 0;
    const sb = 1 - sa;
    A.rating += ELO_K * (sa - ea);
    B.rating += ELO_K * (sb - eb);
    A.games += 1;
    B.games += 1;
    if (c.outcome === 'tie') {
      A.ties += 1;
      B.ties += 1;
    } else if (c.outcome === 'a') {
      A.wins += 1;
      B.losses += 1;
    } else {
      A.losses += 1;
      B.wins += 1;
    }
  }

  return [...table.entries()]
    .map(([model_slug, a]) => ({
      model_slug,
      rating: Math.round(a.rating),
      games: a.games,
      wins: a.wins,
      losses: a.losses,
      ties: a.ties,
    }))
    .sort(
      (x, y) =>
        y.rating - x.rating ||
        y.games - x.games ||
        x.model_slug.localeCompare(y.model_slug),
    );
}
