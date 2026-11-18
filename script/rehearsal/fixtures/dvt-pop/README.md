# SYNTHETIC DVT comparison bundle

Never use these files for deployment. `SYNTHETIC.export.json` preserves DVT's
exact output keys; the field comment identifying its public scalars lives in
`write_synthetic_fixtures()` in the Python test, since JSON has no comments.

The expected GUARDIANS bytes come from DeployLiveLocalBundle using GenuineBLS
public scalars 1/2/3, sender 0x123456 at nonce 7, chain 31337 and accounts
300/301/302. The fixture's Registry and aggregator addresses are that bundle's
CREATE predictions; the DVT address is synthetic. The pin hash is artificial.
The source commit/hash refer to the SP head at fixture generation.

`cast calldata` creates each exported registration from those expected bytes.
Tests compare the converter both to `cast abi-encode` and to the regenerated
DeployLiveLocalBundle output. The converter does not verify PoP cryptography.
See the parent handoff document for regeneration commands and parent-hash pin
semantics. Export `popDigests` are in slot order.
