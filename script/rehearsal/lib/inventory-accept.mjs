// Acceptance gate for an inventory.mjs output before any consumer uses it as evidence.
// The inventory is written only after its controls pass, but a consumer must still refuse a file
// whose controls are not all true, or that is bound to a different chain, SuperPaymaster or Registry.
import { getAddress } from "viem";

export function inventoryErrors(inv, { chainId, sp, registry }) {
    const errors = [];
    if (inv?.chainId !== chainId) errors.push(`inventory chainId ${inv?.chainId} != ${chainId}`);
    const same = (a, b) => typeof a === "string" && typeof b === "string" && /^0x[0-9a-fA-F]{40}$/.test(a) && getAddress(a) === getAddress(b);
    if (!same(inv?.sp, sp)) errors.push("inventory SuperPaymaster address differs from the table's SP");
    if (!same(inv?.state?.registry, registry)) errors.push("inventory Registry address differs from the table's REGISTRY");
    const pc = inv?.positiveControl;
    if (!pc || typeof pc !== "object" || Object.keys(pc).length === 0) errors.push("inventory has no positive controls");
    else for (const [k, v] of Object.entries(pc)) if (v !== true) errors.push(`inventory control ${k} is not true`);
    if (!Number.isInteger(inv?.pinnedBlock?.number) || !/^0x[0-9a-f]{64}$/.test(inv?.pinnedBlock?.hash ?? "")) errors.push("inventory pinned block missing");
    return errors;
}
