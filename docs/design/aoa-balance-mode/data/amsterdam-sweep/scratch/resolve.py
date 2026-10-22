import json, glob, sys, os
root = sys.argv[1]; outdir = sys.argv[2]; evm = sys.argv[3]
names = "Registry ERC1967Proxy xPNTsFactory xPNTsToken GTokenAuthorization GTokenStaking MySBT SuperPaymaster SuperPaymasterAdmin GlobalTierSource AOAProtocolRegistry xPNTsTokenV2Ext xPNTsTokenV2 xPNTsFactoryV2 SuperPaymasterLens ReputationSystem DVTValidator BLSAggregator MicroPaymentChannel PaymasterFactory Paymaster X402Facilitator TimelockController PolicyRegistry APNTsCapped EntryPoint".split()
for n in names:
    hits = []
    for p in glob.glob(f"{root}/**/{n}.sol/**/{n}*.json", recursive=True):
        j = json.load(open(p)); md = j.get("metadata", {})
        if isinstance(md, str): md = json.loads(md)
        s = md.get("settings", {}); tgt = list(s.get("compilationTarget", {}).items())
        if not tgt or tgt[0][1] != n: continue
        runs = s.get("optimizer", {}).get("runs"); want = 200 if n == "Registry" else 500
        if runs != want or s.get("evmVersion") != evm: continue
        if n == "EntryPoint" and "account-abstraction-v7" not in tgt[0][0]: continue
        hits.append((p, tgt[0][0], j["bytecode"]["object"]))
    codes = set(h[2] for h in hits)
    if len(codes) != 1: print("AMBIG/NONE", n, [h[:2] for h in hits]); continue
    p, src, code = hits[0]
    open(f"{outdir}/{n}.hex", "w").write(code)
    print(f"{n:22s} {src}  initcode={len(code)//2-1}B  ({os.path.relpath(p, root)})")
