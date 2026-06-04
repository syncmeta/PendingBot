// Personal model leaderboard from pairwise comparisons via a Bradley-Terry
// model (类 LMArena / Chatbot Arena, which also fits Bradley-Terry).
//
// Why Bradley-Terry over the old sequential Elo:
//   * Order-independent. Elo is path-dependent — replaying the same votes in
//     a different order gives different ratings. BT fits a single maximum-
//     likelihood strength per model from the whole comparison set, so the
//     leaderboard is a deterministic function of *what* was voted, not when.
//   * Statistically grounded. BT is the canonical paired-comparison model:
//     P(A beats B) = π_A / (π_A + π_B). The fitted πs are MLEs, not a
//     heuristic running average.
//
// We fit with the MM (minorization-maximization) iteration (Hunter 2004),
// which is simple, has no learning rate, and converges monotonically. A
// personal log is small (dozens to low-hundreds of votes), so a few dozen
// iterations cost nothing.
//
// Ties count as half a win to each side (the standard BT tie handling —
// equivalent to two half-games with opposite outcomes).
//
// The fitted strengths are mapped onto an integer "rating" on the same
// ~1000-centred scale the Elo leaderboard exposed, so the API response shape
// and the iOS ArenaStanding decoder are unchanged.

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

// Centre of the exposed rating scale (kept from the Elo era so iOS / dashboards
// reading `rating` don't see a discontinuity) and the logistic scale factor
// (400 → a 400-point gap ≈ 10:1 expected odds, the Elo convention).
export const RATING_CENTER = 1000;
export const RATING_SCALE = 400;

// MM fit controls. The personal vote set is tiny, so we can afford a tight
// tolerance and a generous iteration cap; both are hit well before the cap
// in practice.
const MAX_ITERS = 1000;
const CONVERGENCE_EPS = 1e-9;

interface Acc {
  games: number;
  wins: number;   // full wins (outcome decisively for this model)
  losses: number;
  ties: number;
}

/**
 * Fit a Bradley-Terry model over the comparisons and return standings sorted
 * by fitted strength desc, then games desc, then slug — a stable order.
 *
 * Edge cases:
 *   - empty input → [].
 *   - a model that never won (0 effective wins) gets strength → 0 under MM,
 *     which would stall the iteration; we floor the win mass with a tiny
 *     Bayesian-style prior (each model starts with a fractional win against a
 *     virtual average opponent) so the fit is always well-defined and a
 *     winless model simply ranks last instead of producing NaN.
 */
export function computeLeaderboard(comparisons: Comparison[]): Standing[] {
  // ── Tally per-model W/L/T and the pairwise win matrix ──────────────────
  const stats = new Map<string, Acc>();
  const get = (slug: string): Acc => {
    let a = stats.get(slug);
    if (!a) {
      a = { games: 0, wins: 0, losses: 0, ties: 0 };
      stats.set(slug, a);
    }
    return a;
  };

  // wins[i][j] = effective wins of i over j (a win = 1, a tie = 0.5 each side).
  const wins = new Map<string, Map<string, number>>();
  const addWin = (winner: string, loser: string, amount: number) => {
    let row = wins.get(winner);
    if (!row) {
      row = new Map();
      wins.set(winner, row);
    }
    row.set(loser, (row.get(loser) ?? 0) + amount);
  };

  for (const c of comparisons) {
    // A self-pairing carries no signal — skip so it can't inflate counts.
    if (c.model_a === c.model_b) continue;
    const A = get(c.model_a);
    const B = get(c.model_b);
    A.games += 1;
    B.games += 1;
    if (c.outcome === 'tie') {
      A.ties += 1;
      B.ties += 1;
      addWin(c.model_a, c.model_b, 0.5);
      addWin(c.model_b, c.model_a, 0.5);
    } else if (c.outcome === 'a') {
      A.wins += 1;
      B.losses += 1;
      addWin(c.model_a, c.model_b, 1);
    } else {
      A.losses += 1;
      B.wins += 1;
      addWin(c.model_b, c.model_a, 1);
    }
  }

  const models = [...stats.keys()];
  if (models.length === 0) return [];

  // ── MM iteration for the Bradley-Terry MLE ─────────────────────────────
  // Each model i has strength π_i (> 0). Update rule (Hunter 2004):
  //   π_i ← W_i / Σ_j [ n_ij / (π_i + π_j) ]
  // where W_i = total effective wins of i, n_ij = games between i and j.
  // A small smoothing prior (PRIOR effective wins + games vs a virtual
  // average-strength opponent) keeps a winless / unbeaten model finite.
  const PRIOR = 1e-3;

  // Total effective wins per model (+ prior).
  const W = new Map<string, number>();
  // Games played between each unordered pair, stored on both directions.
  const N = new Map<string, Map<string, number>>();
  const games = (i: string, j: string): number => N.get(i)?.get(j) ?? 0;

  for (const i of models) {
    let wi = PRIOR; // prior win mass vs the virtual opponent
    const row = wins.get(i);
    if (row) for (const v of row.values()) wi += v;
    W.set(i, wi);
  }
  for (const i of models) {
    for (const j of models) {
      if (i === j) continue;
      const nij = (wins.get(i)?.get(j) ?? 0) + (wins.get(j)?.get(i) ?? 0);
      if (nij <= 0) continue;
      let row = N.get(i);
      if (!row) {
        row = new Map();
        N.set(i, row);
      }
      row.set(j, nij);
    }
  }

  // Strengths, initialised uniformly. Includes a virtual "average" opponent
  // pinned at strength 1 that every model plays PRIOR games against — this is
  // what the prior win mass is "earned" against, anchoring the otherwise
  // scale-free π vector and keeping winless models finite.
  const pi = new Map<string, number>(models.map((m) => [m, 1]));
  const VIRTUAL = 1; // fixed strength of the average virtual opponent

  for (let iter = 0; iter < MAX_ITERS; iter++) {
    const nextPi = new Map<string, number>();
    let maxDelta = 0;
    for (const i of models) {
      let denom = PRIOR / (pi.get(i)! + VIRTUAL); // prior games vs virtual
      const row = N.get(i);
      if (row) {
        for (const [j, nij] of row) {
          denom += nij / (pi.get(i)! + pi.get(j)!);
        }
      }
      const updated = denom > 0 ? W.get(i)! / denom : pi.get(i)!;
      nextPi.set(i, updated);
      maxDelta = Math.max(maxDelta, Math.abs(updated - pi.get(i)!));
    }
    // Renormalise to geometric mean 1 each round — BT strengths are only
    // identified up to a global scale, so pinning the scale keeps the
    // iteration numerically stable and the rating mapping reproducible.
    const logSum = models.reduce((s, m) => s + Math.log(nextPi.get(m)!), 0);
    const geoMean = Math.exp(logSum / models.length);
    for (const m of models) pi.set(m, nextPi.get(m)! / geoMean);
    if (maxDelta < CONVERGENCE_EPS) break;
  }

  // ── Map strengths → integer ratings on the ~1000-centred Elo-like scale ─
  // rating = CENTER + SCALE * log10(π_i)  (geo-mean of π is 1 → average model
  // sits at CENTER). Monotone in π, so the ranking is preserved.
  return models
    .map((slug) => {
      const acc = stats.get(slug)!;
      const rating = Math.round(RATING_CENTER + RATING_SCALE * Math.log10(pi.get(slug)!));
      return {
        model_slug: slug,
        rating,
        games: acc.games,
        wins: acc.wins,
        losses: acc.losses,
        ties: acc.ties,
      };
    })
    .sort(
      (x, y) =>
        y.rating - x.rating ||
        y.games - x.games ||
        x.model_slug.localeCompare(y.model_slug),
    );
}
