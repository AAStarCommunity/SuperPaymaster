"""Offline, versioned public-seed schedule. No random-library version dependency."""
import argparse
import hashlib
import itertools
import json

ARMS = ('SP', 'VerifyingPaymaster', 'TokenPaymaster')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def generate(seed, accounts, slot_period=None, max_elapsed=None, chain="op-mainnet"):
    from manifests import qualification
    frozen = qualification(chain)
    bound = frozen["payload"]["max_elapsed_seconds"]
    slot_period = slot_period if slot_period is not None else (30 if chain == "op-mainnet" else 130)
    max_elapsed = bound if max_elapsed is None else max_elapsed
    if max_elapsed != bound:
        raise ValueError("elapsed bound must match frozen chain parameters")
    if not isinstance(seed, str) or not seed or len(accounts) != 3 or len(set(accounts)) != 3:
        raise ValueError('public seed and three distinct accounts required')
    if slot_period <= 0 or max_elapsed < 0 or max_elapsed >= slot_period:
        raise ValueError('block elapsed bound must be smaller than slot period')
    # Even if an SP attempt is last in one block and first three blocks later.
    if 3 * slot_period - max_elapsed < 60:
        raise ValueError('worst-case per-account SP spacing is below 60 seconds')
    permutations = list(itertools.permutations(ARMS))
    # Each six-slot batch contains every permutation exactly once. SHA256 ranking
    # with an index tie-break defines a portable deterministic shuffle.
    orders = []
    for batch in range(10):
        orders.extend(sorted(permutations, key=lambda p: (digest([seed, batch, p]), p)))
    slots = []
    for i, order in enumerate(orders):
        slots.append(dict(block_slot=i, pair_id=f'block-{i:02d}', start_seconds=i * slot_period,
                          deadline_seconds=i * slot_period + max_elapsed, order=order,
                          senders={arm: accounts[(j + i) % 3] for j, arm in enumerate(ARMS)}))
    payload = dict(schema='rq3-schedule-v1', seed=seed, accounts=accounts,
                   qualification=frozen, slot_period_seconds=slot_period, max_elapsed_seconds=max_elapsed, slots=slots)
    return dict(payload=payload, sha256=digest(payload))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', required=True)
    parser.add_argument('--accounts', nargs=3, required=True)
    parser.add_argument('--slot-period', type=int)
    parser.add_argument('--max-elapsed', type=int)
    parser.add_argument("--chain", choices=("op-mainnet", "sepolia"), default="op-mainnet")
    args = parser.parse_args()
    print(json.dumps(generate(args.seed, args.accounts, args.slot_period, args.max_elapsed, args.chain), indent=2))
