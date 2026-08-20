// Heuristic token counter — char-based, no tokenizer dependency. We're
// not trying to match any single provider's BPE exactly; we want a
// *sanity-check* number so the audit panel can show a provider-vs-local
// ratio per turn. A provider that pads billed tokens (e.g. reporting 1.4×
// the realistic count) shows up as a row where reported / est_input lands
// well above 1.0.
//
// Calibration: cl100k_base packs English at ~3.5–4 chars/token and CJK
// at ~1.4–1.6 chars/token (often 1 token per Han char with some pair
// merges). Claude tokenizer is similar in shape — different boundaries,
// same order of magnitude. We pick chars/4 (Latin) and chars/1.5 (CJK)
// as central estimates, not floors. Whitespace and punct fold into
// adjacent BPE merges, so naive char count is a reasonable mean.

const CJK_TEST = (cp: number): boolean =>
  // CJK Unified Ideographs + extensions, Hiragana/Katakana, Hangul,
  // CJK punctuation/symbols, fullwidth forms.
  (cp >= 0x3000 && cp <= 0x9fff) ||
  (cp >= 0xac00 && cp <= 0xd7af) ||
  (cp >= 0xf900 && cp <= 0xfaff) ||
  (cp >= 0xff00 && cp <= 0xffef);

export function estimateTokens(s: string | null | undefined): number {
  if (!s) return 0;
  let cjk = 0;
  let other = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (cp != null && CJK_TEST(cp)) cjk++;
    else other++;
  }
  return Math.ceil(cjk / 1.5 + other / 4);
}
