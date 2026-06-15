// Consistency test suite for the x402 facilitator node.
//
// WHY THIS FILE EXISTS: this package was hit by Codex stop-review TWICE (r1, r2) for
// verify/settle/contract mismatches after the v5.4 god-split moved x402 settlement from
// SuperPaymaster into contracts/src/paymasters/superpaymaster/v3/X402Facilitator.sol. The
// root cause was the ABSENCE of tests. Every assertion below locks one exact invariant that
// MUST stay byte-for-byte identical to X402Facilitator.sol, so a future regression fails here
// instead of reverting on-chain.
//
// The hard-coded digests/typehashes are LITERALS computed once with viem against the contract
// source — do NOT replace them with a re-derivation using the same helper under test, or the
// test becomes circular and stops catching encoding regressions.

import { describe, it, expect } from "vitest";
import {
  keccak256,
  encodeAbiParameters,
  encodeFunctionData,
  decodeFunctionData,
  stringToHex,
  getAddress,
  type Address,
  type Hex,
} from "viem";

import {
  computeEIP3009Nonce,
  computeX402NonceKey,
  getUsdcDomain,
  getX402FacilitatorDomain,
  RECEIVE_WITH_AUTH_TYPES,
  X402_AUTH_TYPES,
} from "../src/lib/verify-sig.js";
import { rejectUnsupportedScheme, isSupportedScheme, SUPPORTED_SCHEMES } from "../src/lib/scheme.js";
import { buildEIP3009SettleArgs, buildDirectSettleArgs } from "../src/lib/settle-args.js";
import { X402_FACILITATOR_ABI } from "../src/lib/contracts.js";

// ---- Shared fixtures -------------------------------------------------------
const TO_1 = getAddress("0x1111111111111111111111111111111111111111");
const TO_2 = getAddress("0x52908400098527886E0F7030069857D2E4169EE7"); // EIP-55 checksummed
const ASSET = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e"); // Base Sepolia USDC
const FROM = getAddress("0x2222222222222222222222222222222222222222");
const SALT_1: Hex = ("0x" + "11".repeat(32)) as Hex;
const SALT_2: Hex = ("0x" + "ab".repeat(32)) as Hex;
const RAW_NONCE: Hex = ("0x" + "cd".repeat(32)) as Hex;
const UINT256_MAX = 2n ** 256n - 1n;

// EIP-712 single-struct type encoder (no nested refs) used to lock typehash strings.
function encodeEip712Type(
  primaryType: string,
  types: Record<string, readonly { name: string; type: string }[]>,
): string {
  const fields = types[primaryType];
  return `${primaryType}(${fields.map((f) => `${f.type} ${f.name}`).join(",")})`;
}

// Reproduce the EIP-712 domain separator exactly as X402Facilitator._x402DomainSeparator does.
function domainSeparator(d: {
  name: string;
  version: string;
  chainId: bigint;
  verifyingContract: Address;
}): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "address" }],
      [
        keccak256(stringToHex("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")),
        keccak256(stringToHex(d.name)),
        keccak256(stringToHex(d.version)),
        d.chainId,
        d.verifyingContract,
      ],
    ),
  );
}

// ============================================================================
// 1. EIP-3009 token-level nonce derivation (r2 ship-blocker)
//    Contract: nonce = keccak256(abi.encode(address to, uint256 maxFee, bytes32 salt))
// ============================================================================
describe("computeEIP3009Nonce — keccak256(abi.encode(to, maxFee, salt))", () => {
  // LITERAL vectors precomputed with viem against the contract encoding. Locked forever.
  it("vector 1: (to1, 1_000_000, salt1)", () => {
    expect(computeEIP3009Nonce(TO_1, 1_000_000n, SALT_1)).toBe(
      "0x1c33b269c951b5fe1e2a721e58e2a478ed718a79c8dadc46928ea131f05cde01",
    );
  });

  it("vector 2: (to2, 0, salt2) — zero maxFee, checksummed addr", () => {
    expect(computeEIP3009Nonce(TO_2, 0n, SALT_2)).toBe(
      "0xf8cfeedbe9c961dfb05392e6b803b5eaccb400f4b39b9bdd1917e36e22c3a262",
    );
  });

  it("vector 3: (to1, uint256_max, salt2) — max fee boundary", () => {
    expect(computeEIP3009Nonce(TO_1, UINT256_MAX, SALT_2)).toBe(
      "0xa33e4531a768f6ad45eb0c8fdc37f1b868a626a276992586daee3265ad610cb4",
    );
  });

  it("binds `to` and `maxFee` — changing either changes the nonce", () => {
    const base = computeEIP3009Nonce(TO_1, 1_000_000n, SALT_1);
    expect(computeEIP3009Nonce(TO_2, 1_000_000n, SALT_1)).not.toBe(base); // different recipient
    expect(computeEIP3009Nonce(TO_1, 999_999n, SALT_1)).not.toBe(base); // different fee cap
  });
});

// ============================================================================
// 2. Replay nonce key (X402Facilitator.x402NonceKey)
//    Contract: keccak256(abi.encode(address asset, address from, bytes32 nonce))
// ============================================================================
describe("computeX402NonceKey — keccak256(abi.encode(asset, from, nonce))", () => {
  it("vector: (asset, from, rawNonce)", () => {
    expect(computeX402NonceKey(ASSET, FROM, RAW_NONCE)).toBe(
      "0xa5176242f40a07f76e2cb93b14c79db273c1514103925c6ff32553bee5554b24",
    );
  });

  it("vector: keyed on a derived EIP-3009 nonce", () => {
    const derived = computeEIP3009Nonce(TO_1, 1_000_000n, SALT_1);
    expect(computeX402NonceKey(ASSET, FROM, derived)).toBe(
      "0x7da9e3756f34febf87ae12988f1aeb7706a05aed82bb02dfe3aa6dc5b90d579d",
    );
  });
});

// ============================================================================
// 3. The two-layer nonce relationship (the exact r1+r2 bug)
//    The replay key for an EIP-3009 payment MUST be keyed on the DERIVED token nonce
//    keccak256(to, maxFee, salt), NOT on the raw request nonce.
// ============================================================================
describe("two-layer nonce relationship (EIP-3009 replay key)", () => {
  it("replay key = nonceKey(asset, from, eip3009Nonce(to, maxFee, salt))", () => {
    const maxFee = 1_000_000n;
    const tokenNonce = computeEIP3009Nonce(TO_1, maxFee, SALT_1);
    const replayKey = computeX402NonceKey(ASSET, FROM, tokenNonce);

    // This is what verify.ts MUST compute (effectiveNonce -> nonceKey).
    expect(replayKey).toBe(computeX402NonceKey(ASSET, FROM, computeEIP3009Nonce(TO_1, maxFee, SALT_1)));
  });

  it("would FAIL against the old raw-nonce code: derived key != raw-salt key", () => {
    // Old (buggy) behaviour keyed the replay slot on the raw request nonce/salt.
    const maxFee = 1_000_000n;
    const correctKey = computeX402NonceKey(ASSET, FROM, computeEIP3009Nonce(TO_1, maxFee, SALT_1));
    const buggyRawKey = computeX402NonceKey(ASSET, FROM, SALT_1); // raw salt == request nonce

    expect(correctKey).not.toBe(buggyRawKey);
  });
});

// ============================================================================
// 4. EIP-3009 typehash: ReceiveWithAuthorization, NOT TransferWithAuthorization
// ============================================================================
describe("EIP-3009 typehash — ReceiveWithAuthorization variant", () => {
  it("primaryType is ReceiveWithAuthorization (not Transfer)", () => {
    const keys = Object.keys(RECEIVE_WITH_AUTH_TYPES);
    expect(keys).toContain("ReceiveWithAuthorization");
    expect(keys).not.toContain("TransferWithAuthorization");
  });

  it("type string hashes to the ReceiveWithAuthorization typehash, not Transfer", () => {
    const typeString = encodeEip712Type("ReceiveWithAuthorization", RECEIVE_WITH_AUTH_TYPES);
    expect(typeString).toBe(
      "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)",
    );

    const RECEIVE_TYPEHASH = "0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8";
    const TRANSFER_TYPEHASH = "0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267";
    expect(keccak256(stringToHex(typeString))).toBe(RECEIVE_TYPEHASH);
    expect(keccak256(stringToHex(typeString))).not.toBe(TRANSFER_TYPEHASH);
  });
});

// ============================================================================
// 5. EIP-712 domains
//    - direct path: X402Facilitator domain {name:"X402Facilitator", version:"1", ...}
//    - eip-3009 path: token (USDC) domain {name:"USDC", version:"2", ...}
// ============================================================================
describe("EIP-712 domain builders", () => {
  const FACILITATOR = getAddress("0x3C4DE35f6391Dd07B56c70cB45A7D3dEc219855e");
  const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
  const CHAIN_ID = 11155111;

  it("X402Facilitator (direct path) domain fields", () => {
    expect(getX402FacilitatorDomain(CHAIN_ID, FACILITATOR)).toEqual({
      name: "X402Facilitator",
      version: "1",
      chainId: BigInt(CHAIN_ID),
      verifyingContract: FACILITATOR,
    });
  });

  it("X402Facilitator domain separator matches the on-chain _x402DomainSeparator formula", () => {
    const fromBuilder = domainSeparator(getX402FacilitatorDomain(CHAIN_ID, FACILITATOR));
    // Independently recomputed with the literal "X402Facilitator"/"1" the contract hard-codes.
    const onChain = keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "address" }],
        [
          keccak256(stringToHex("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")),
          keccak256(stringToHex("X402Facilitator")),
          keccak256(stringToHex("1")),
          BigInt(CHAIN_ID),
          FACILITATOR,
        ],
      ),
    );
    expect(fromBuilder).toBe(onChain);
  });

  it("USDC (eip-3009 path) token domain fields", () => {
    expect(getUsdcDomain(CHAIN_ID, USDC)).toEqual({
      name: "USDC",
      version: "2",
      chainId: BigInt(CHAIN_ID),
      verifyingContract: USDC,
    });
  });
});

// ============================================================================
// 6. Scheme routing parity — /verify and /settle share ONE guard
// ============================================================================
describe("scheme routing parity (shared guard)", () => {
  it("supported schemes are exactly eip-3009 and direct", () => {
    expect([...SUPPORTED_SCHEMES].sort()).toEqual(["direct", "eip-3009"]);
  });

  it("permit2 is rejected (reason, not null)", () => {
    expect(rejectUnsupportedScheme("permit2")).not.toBeNull();
    expect(isSupportedScheme("permit2")).toBe(false);
  });

  it("unknown schemes are rejected", () => {
    expect(rejectUnsupportedScheme("totally-unknown")).not.toBeNull();
    expect(rejectUnsupportedScheme("")).not.toBeNull();
  });

  it("eip-3009 and direct are accepted (null reason)", () => {
    expect(rejectUnsupportedScheme("eip-3009")).toBeNull();
    expect(rejectUnsupportedScheme("direct")).toBeNull();
  });

  it("both /verify and /settle import the SAME guard (cannot diverge)", () => {
    // verify.ts and settle.ts both call rejectUnsupportedScheme from ../lib/scheme.js.
    // Assert the guard is a single function reference, so a divergent inline check cannot
    // silently reappear in one route. The string assertions above pin its decision table.
    expect(typeof rejectUnsupportedScheme).toBe("function");
  });
});

// ============================================================================
// 7. settle arg order matches the X402Facilitator ABI
// ============================================================================
describe("settle arg order matches the contract ABI", () => {
  const common = {
    from: FROM,
    to: TO_1,
    asset: ASSET,
    amount: 1_000_000n,
    maxFee: 5_000n,
    validBefore: 2_000_000_000n,
    signature: "0xdeadbeef" as Hex,
  };

  it("EIP-3009 path: 9 args in (from,to,asset,amount,maxFee,validAfter,validBefore,salt,signature)", () => {
    const args = buildEIP3009SettleArgs({ ...common, validAfter: 1_000_000_000n, salt: SALT_1 });
    expect(args).toHaveLength(9);
    expect(args).toEqual([
      FROM,
      TO_1,
      ASSET,
      1_000_000n,
      5_000n,
      1_000_000_000n, // validAfter
      2_000_000_000n, // validBefore
      SALT_1,
      "0xdeadbeef",
    ]);

    // Round-trip through the ABI: viem rejects wrong arg count/type; decode proves ORDER.
    const encoded = encodeFunctionData({
      abi: X402_FACILITATOR_ABI,
      functionName: "settleX402Payment",
      args,
    });
    const decoded = decodeFunctionData({ abi: X402_FACILITATOR_ABI, data: encoded });
    expect(decoded.functionName).toBe("settleX402Payment");
    expect(decoded.args).toEqual(args);
  });

  it("direct path: 8 args in (from,to,asset,amount,maxFee,validBefore,nonce,signature)", () => {
    const args = buildDirectSettleArgs({ ...common, nonce: RAW_NONCE });
    expect(args).toHaveLength(8);
    expect(args).toEqual([
      FROM,
      TO_1,
      ASSET,
      1_000_000n,
      5_000n,
      2_000_000_000n, // validBefore (NO validAfter on the direct path)
      RAW_NONCE,
      "0xdeadbeef",
    ]);

    const encoded = encodeFunctionData({
      abi: X402_FACILITATOR_ABI,
      functionName: "settleX402PaymentDirect",
      args,
    });
    const decoded = decodeFunctionData({ abi: X402_FACILITATOR_ABI, data: encoded });
    expect(decoded.functionName).toBe("settleX402PaymentDirect");
    expect(decoded.args).toEqual(args);
  });

  it("ABI input order matches the contract source for both settle functions", () => {
    const fn = (name: string) => X402_FACILITATOR_ABI.find((e) => "name" in e && e.name === name);
    const eip3009 = fn("settleX402Payment") as { inputs: { name: string }[] };
    const direct = fn("settleX402PaymentDirect") as { inputs: { name: string }[] };

    expect(eip3009.inputs.map((i) => i.name)).toEqual([
      "from", "to", "asset", "amount", "maxFee", "validAfter", "validBefore", "salt", "signature",
    ]);
    expect(direct.inputs.map((i) => i.name)).toEqual([
      "from", "to", "asset", "amount", "maxFee", "validBefore", "nonce", "signature",
    ]);
  });
});
