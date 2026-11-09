#!/usr/bin/env python3
"""Only renamed REQUIRED/F05 bindings and the corrected discovery selector."""
import probe_phase_c_gates as driver
from gate_assertions import assertion_mentions
import test_manifest_exec as tests

CASES = (
    (tests.ManifestTests, 'test_old_timelock_approval_history_range', 'old_timelock_approval_history_creation'),
    (tests.ManifestTests, 'test_old_timelock_approval_history_log', 'old_timelock_approval_history_log'),
    (tests.ManifestTests, 'test_old_timelock_replay_reads', 'old_timelock_replay_reads'),
    (tests.ManifestTests, 'test_old_timelock_replay_owners', 'old_timelock_replay_owners'),
    (tests.F05CollectGates, 'test_stake_not_unlocking', 'stake_not_unlocking_collect'),
    (tests.F05BuildPlanGates, 'test_stake_not_unlocking', 'stake_not_unlocking_build_plan'),
    (tests.DiscoveryTests, 'test_preswitch_enumeration', 'old_owner_factory_enumeration_discover_targets'),
)


def main():
    passed = 0
    for cls, name, gate in CASES:
        green, _, baseline = driver.run(cls, name)
        accepted, reached, mutant = driver.run(cls, name, gate) if green else (True, False, '')
        sites = len(driver.SITES.get((cls, name, gate), set()))
        good = green and sites == 1 and reached and not accepted
        passed += good
        print(baseline + mutant, end='')
        print(f'GATE_BINDING {gate} {"PASS" if good else "FAIL"} sites={sites} '
              f'baseline={"green" if green else "RED"} failures={mutant.count("FAIL:")} '
              f'errors={mutant.count("ERROR:")} named={assertion_mentions(mutant, gate)}', flush=True)
    print(f'GATE_BINDING_PROBES {"PASS" if passed == len(CASES) else "FAIL"} {passed}/{len(CASES)} strict red')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
