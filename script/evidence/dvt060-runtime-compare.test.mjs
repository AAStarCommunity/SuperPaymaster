// node --test script/evidence/dvt060-runtime-compare.test.mjs — the comparator can say "no".
import test from "node:test";
import assert from "node:assert/strict";
import { maskAndCompare } from "./dvt060-runtime-compare.mjs";

const art = { deployedBytecode: { object: "0x6000" + "00".repeat(32) + "60ff", immutableReferences: { "7": [{ start: 2, length: 32 }] } } };
const imm = "11".repeat(32);

test("immutable words are masked; every other byte must match", () => {
    assert.equal(maskAndCompare("0x6000" + imm + "60ff", art).match, true);
    assert.equal(maskAndCompare("0x6001" + imm + "60ff", art).match, false);   // logic byte differs
    assert.equal(maskAndCompare("0x6000" + imm + "60fe", art).match, false);   // CBOR/tail byte differs
    assert.equal(maskAndCompare("0x6000" + imm + "60ff00", art).match, false); // length differs
});
