# Frozen measurement policy

Recorded before matrix results, 2026-10-31. Base HEAD a941ddd9.

- Do not change source, original tests, deployment files, or Foundry configuration.
- Run offline. Original tuple: MIN_POST=440000, SETTLE=420000, C_WRAP=5000, C_POSTOP=340000.
- Uniform proposal margin: m = 15%, applied to measured whole proxy-frame maximum,
  rounded upward to an integer. For operational tuple proposals round upward to 5000 gas.
- Define C_POSTOP proposal = max(175000, round5000(ceil(1.15 * W_postop))).
- Conservatively propose SETTLE = C_POSTOP; MIN_POST = SETTLE + 20000.
  This reserves the full padded whole-frame cost even at the guard. These are proposals,
  not claims that untested parameter changes pass all G2 no-subsidy cases.
- First/repeat matrix is a same-user/operator pair in one canonical EntryPoint bundle.
  Validation warmth is retained; repeat adds prior settlement warmth and initialized state.
- Trace gas is gross frame consumption, before transaction refunds, excluding the caller's
  CALL opcode. Keep proxy overhead, distinguish it from implementation and token subframes.
