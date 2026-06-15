// Shared x402 scheme routing guard.
//
// Codex stop-review (r1/r2) flagged that /verify and /settle independently inlined their
// scheme checks: verify rejected "permit2" while settle could fall through and settle a
// request /verify never validated. Both routes MUST funnel scheme routing through THIS single
// guard so they can never diverge again. Only "eip-3009" and "direct" are settleable;
// everything else ("permit2", typos, future/unknown schemes) is rejected by both paths.

export type X402Scheme = "eip-3009" | "permit2" | "direct";

/** The only schemes both /verify and /settle accept and process. */
export const SUPPORTED_SCHEMES = ["eip-3009", "direct"] as const;
export type SupportedScheme = (typeof SUPPORTED_SCHEMES)[number];

/** Narrow an arbitrary scheme string to a settleable scheme. */
export function isSupportedScheme(scheme: string): scheme is SupportedScheme {
  return (SUPPORTED_SCHEMES as readonly string[]).includes(scheme);
}

/**
 * The single shared scheme guard used by BOTH /verify and /settle.
 * Returns a human-readable rejection reason for any unsupported scheme
 * (e.g. "permit2" or an unknown value), or `null` when the scheme is settleable.
 * Callers format the reason into their own response shape (verify => { valid:false,
 * reason }, settle => { success:false, error }) but the accept/reject decision is identical.
 */
export function rejectUnsupportedScheme(scheme: string): string | null {
  if (isSupportedScheme(scheme)) return null;
  return `Unsupported scheme: ${scheme}. Supported: ${SUPPORTED_SCHEMES.join(", ")}`;
}
