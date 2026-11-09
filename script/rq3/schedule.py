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


def generate(seed, accounts, slot_period=30, max_elapsed=20):
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
                   slot_period_seconds=slot_period, max_elapsed_seconds=max_elapsed, slots=slots)
    return dict(payload=payload, sha256=digest(payload))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', required=True)
    parser.add_argument('--accounts', nargs=3, required=True)
    parser.add_argument('--slot-period', type=int, default=30)
    parser.add_argument('--max-elapsed', type=int, default=20)
    args = parser.parse_args()
    print(json.dumps(generate(args.seed, args.accounts, args.slot_period, args.max_elapsed), indent=2))
