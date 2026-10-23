// R2-F4: consolidate the artifact identity of v5.5.0-rc.4 (forge 1.7.1, profile.default) and which bytes
// each evidence line executed, into one identity.json.
// Usage (from this directory's parent): node scripts/build_identity.mjs identity.json
import { readFileSync, writeFileSync } from "node:fs";

const rd = (p) => JSON.parse(readFileSync(p, "utf8"));
const out = process.argv[2];
const full = rd("identity-rc4-forge171-default.json");
const prague = rd("identity-rc4-nightly-prague.json");
const cancun = rd("identity-rc4-nightly-cancun.json");
const tag = rd("../rc4-tag-fbd74fb1/rc4.json");
const flat = (j) => Object.fromEntries(j.contracts.flatMap((c) => (c.variants ?? []).map((v) => [v.artifact, v])));
const F = flat(full), P = flat(prague), C = flat(cancun);
const slim = (v) => ({ artifact: v.artifact, compiler: v.compiler, settings: v.settings,
    creationKeccak: v.creationKeccak, creationBytes: v.creationBytes, runtimeKeccak: v.runtimeKeccak, runtimeBytes: v.runtimeBytes,
    runtimeKeccakImmutablesZeroed: v.runtimeKeccakImmutablesZeroed, immutableReferences: v.immutableReferences,
    linkReferences: v.linkReferences, runtimeCborTail: v.runtimeCborTail, rawMetadataKeccak: v.rawMetadataKeccak });

const releaseList = tag.map((t) => {
    const v = F[t.artifact];
    const other = Object.keys(F).filter((k) => k !== t.artifact && k.startsWith(t.artifact.split("/")[0] + "/" + t.contract + "."));
    return { contract: t.contract, shipped: slim(v),
        tagRecord: { runtimeKeccak: t.runtimeKeccak, creationKeccak: t.creationKeccak, runtimeBytes: t.runtimeBytes, runs: t.runs },
        equalsTagRecord: v.runtimeKeccak === t.runtimeKeccak && v.creationKeccak === t.creationKeccak && v.runtimeBytes === t.runtimeBytes,
        nonShippedVariants: other.map((k) => slim(F[k])) };
});
const otherTargets = ["TimelockController.sol:TimelockController", "ERC1967Proxy.sol:ERC1967Proxy", "SimpleAccount.sol:SimpleAccount",
    "SimpleAccountFactory.sol:SimpleAccountFactory", "BLayerAccounts.sol:MockAirAccount", "BLayerAccounts.sol:MockAirAccountFactory",
    "xPNTsFactory.sol:xPNTsFactory", "xPNTsToken.sol:xPNTsToken", "MySBT.sol:MySBT", "GTokenStaking.sol:GTokenStaking",
    "GTokenAuthorization.sol:GTokenAuthorization", "EntryPoint.sol:EntryPoint"];
const others = otherTargets.map((t) => ({ target: t, variants: (full.contracts.find((c) => c.target === t)?.variants ?? []).map(slim) }));
const cross = Object.keys(F).map((k) => ({ artifact: k,
    nightlyPragueEqual: P[k]?.creationKeccak === F[k].creationKeccak && P[k]?.runtimeKeccak === F[k].runtimeKeccak,
    nightlyCancunEqual: C[k]?.creationKeccak === F[k].creationKeccak && C[k]?.runtimeKeccak === F[k].runtimeKeccak,
    rawMetadataKeccak: { forge171Cancun: F[k].rawMetadataKeccak, nightlyPrague: P[k]?.rawMetadataKeccak, nightlyCancun: C[k]?.rawMetadataKeccak } }));

const gOld = rd("g-executed-bytecode-original-fixture.json"), gNew = rd("g-executed-bytecode-artifact-run.json");
const bOn = rd("b-onchain/onchain-identity.json"), bCr = rd("b-onchain/creation-match.json");
writeFileSync(out, JSON.stringify({
    tag: "v5.5.0-rc.4", tagObject: "67f78f60167890600e0d78e69ce62f071eb358aa", commit: "fbd74fb1e2e9d948996e6d6c02c48dc1c1778107",
    contractsSrcTree: "f1d39b5bb4081c51e69c9b4a64346dd769193f31", foundryToml: "065d0bd7cd8e4d1de606cf438471c1f66fa5c659",
    build: { forge: "1.7.1 (4072e48705af9d93e3c0f6e29e93b5e9a40caed8)", profile: "default (forge build --offline, no FOUNDRY_PROFILE)",
        solc: "0.8.33+commit.64118f21", outDir: full.outDir, note: "bytecode_hash = none: the runtime CBOR tail carries only the solc version" },
    canonicalEntryPointV07: { address: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", runtimeKeccak: "0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58",
        runtimeBytes: 16035, source: "contracts/test/fixtures/entrypoint-v0.7.runtime.hex (etched in G and B; the repo-compiled EntryPoint artifact is NOT used)",
        senderCreatorRuntimeKeccak: "0x283c9d14378f5f4c4e24045b87d621d48443fa5b4af7dd7180a599b3756a7689" },
    releaseList, otherKeyContracts: others,
    crossBuildEquality: { summary: `${cross.filter((x) => x.nightlyPragueEqual && x.nightlyCancunEqual).length}/${cross.length} artifact variants byte-identical (creation and runtime) across forge 1.7.1 cancun, nightly 926eb1d prague, nightly 926eb1d cancun`, rows: cross },
    executed: {
        G_RAMS2a_original_fixture: { how: "contracts created with `new` inside the test (test compile unit = the compilation_restrictions 'registry-size' job, optimizer runs 200)", rows: gOld.rows },
        G_F4_artifact_run: { how: "deployCode() of the rc.4 profile.default artifact JSONs (f4art/)", rows: gNew.rows },
        B_layer_redeploy: { how: "eth_getCode on a re-deployment whose 55 deploy tx hashes equal those of runs a, b, c, c-rundler-mvg6m", runtime: bOn.rows, creation: bCr.rows },
    },
}, null, 1) + "\n");
console.log("release list:", releaseList.map((r) => `${r.contract}=${r.equalsTagRecord}`).join(" "));
console.log(cross.filter((x) => x.nightlyPragueEqual && x.nightlyCancunEqual).length, "/", cross.length, "cross-build equal");
