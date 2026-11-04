# Deployed source input fragment

`deployed-sources.json` is the fragment for `externalInputs.data`. It contains
no entries because no candidate completed the required offline rebuild. An
empty mapping is not a complete isolation input and will fail the target gate.

See `../../deployed_source_candidates.json` for exact per-attempt STOP evidence
and `../../DEPLOYED_SOURCE_PARITY_RESULTS.md` for the summary. No source commit,
proxy/clone binding, or creation block has been promoted from a candidate.
The supplied snapshot also lacks an xPNTsToken address/runtime and does not
contain proxy-slot or target creation-boundary evidence.
