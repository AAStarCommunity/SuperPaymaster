#!/usr/bin/env python3
"""Strict single-statement deletions for the offline Registry AST proof."""
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'upgrade'))
import probe_phase_c_gates as driver

T = driver.base_tests.isolation_tests.RegistryASTProofTests
GROUPS = {
    'old_owner_role_node_type': ['node_type'],
    'old_owner_role_free_function': ['free_function'],
    'old_owner_role_storage_escape': ['using_for', 'storage_receiver', 'using_library_assembly_scope'],
    'old_owner_role_storage_return': ['storage_return'],
    'old_owner_role_yul_terminator': ['yul_terminator'],
    'old_owner_role_allowlisted_source': ['missing_allowlisted_source'],
    'old_owner_callsite_target_writers': ['extra_writer', 'setter_without_owner', 'setter_non_oz_owner', 'missing_writer'],
    'old_owner_role_initializer_only': ['initializer_declaration'],
    'old_owner_role_configure_guard': ['configure_guard', 'modifier_post_termination'],
    'old_owner_role_configure_emit': ['emit_nested_write', 'emit_early_return', 'emit_before_write', 'emit_internal_call', 'emit_two_calls', 'emit_try', 'emit_different_target', 'emit_different_function'],
    'old_owner_role_lowlevel_call': ['extra_call', 'delegatecall', 'call_value', 'call_gas', 'call_wrong_target', 'call_wrong_interface', 'modifier_delegatecall_scope'],
    'old_owner_role_callsite_count': ['src_offset', 'allowlist_two', 'allowlist_four'],
    'old_owner_role_callsite_target': ['pin_target_middle_byte', 'pin_target_rpc_mismatch', 'pin_target_audit_staking_middle_byte', 'pin_target_audit_sbt_middle_byte'],
    'old_owner_role_callsite_sp': ['pin_target_sp_constant'],
    'old_owner_role_assembly': ['free_function_assembly_scope', 'library_assembly_scope'],
}
CASES = [(T, 'test_'+test, gate) for gate, tests in GROUPS.items() for test in tests]


def main():
    failures = 0
    for cls, name, gate in CASES:
        green, _, baseline = driver.run(cls, name)
        if not green:
            print(f'BASELINE FAILED {name}\n{baseline}')
            failures += 1
            continue
        not_red, single, log = driver.run(cls, name, gate)
        good = not not_red and single
        count = re.search(r'FAILED \(failures=(\d+)\)', log)
        print(f'REGISTRY_AST_PROBE {name} gate={gate} baseline=green sites={1 if single else 0} '
              f'failures={count.group(1) if count else "unknown"} errors={0 if good else "unknown"} '
              f'{"PASS" if good else "FAIL"}')
        if not good:
            print(log)
            failures += 1
    print(f'REGISTRY_AST_PROBES {"PASS" if not failures else "FAIL"} {len(CASES)-failures}/{len(CASES)} strict red')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
