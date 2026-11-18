// Acceptance gate for an inventory.mjs output before any consumer uses it as evidence.
// inventory.mjs writes its file only after its controls pass, but a consumer must still refuse a file
// whose schema version is unknown, whose control set is not EXACTLY the named set of that version (none
// missing, none extra), whose controls are not all exactly `true`, or that is bound to a different
// chain, SuperPaymaster or Registry.
import { getAddress } from "viem";

export const INVENTORY_SCHEMA = "sp-inventory/2";
export const REQUIRED_CONTROLS = Object.freeze({
    "sp-inventory/2": Object.freeze([
        "pinnedBlockUnchanged", "endpointsReturnIdenticalRegistryGrants", "everyHolderEverRegistered",
        "operatorConfiguredEventsFound", "everyEventOperatorReadsConfigured", "noUnclassifiedTopic0",
        "endpointsReturnIdenticalLogs", "roleMembersSlotMatchesView", "noConfiguredOperatorOutsideList",
    ]),
});

export function inventoryErrors(inv, { chainId, sp, registry }) {
    const errors = [];
    const required = Object.hasOwn(REQUIRED_CONTROLS, inv?.schema ?? "") ? REQUIRED_CONTROLS[inv.schema] : null;
    if (!required) errors.push(`unsupported inventory schema ${JSON.stringify(inv?.schema)}`);
    if (inv?.chainId !== chainId) errors.push(`inventory chainId ${inv?.chainId} != ${chainId}`);
    const same = (a, b) => typeof a === "string" && typeof b === "string" && /^0x[0-9a-fA-F]{40}$/.test(a) && getAddress(a) === getAddress(b);
    if (!same(inv?.sp, sp)) errors.push("inventory SuperPaymaster address differs from the table's SP");
    if (!same(inv?.state?.registry, registry)) errors.push("inventory Registry address differs from the table's REGISTRY");
    const pc = inv?.positiveControl;
    if (!pc || typeof pc !== "object" || Array.isArray(pc)) errors.push("inventory has no positive controls");
    else if (required) {
        for (const k of required) if (!Object.hasOwn(pc, k)) errors.push(`inventory control ${k} is missing`);
        for (const k of Object.keys(pc)) if (!required.includes(k)) errors.push(`inventory control ${k} is not a control of ${inv.schema}`);
        for (const k of required) if (Object.hasOwn(pc, k) && pc[k] !== true) errors.push(`inventory control ${k} is not exactly true`);
    }
    if (!Number.isInteger(inv?.pinnedBlock?.number) || !/^0x[0-9a-f]{64}$/.test(inv?.pinnedBlock?.hash ?? "")) errors.push("inventory pinned block missing");
    return errors;
}
