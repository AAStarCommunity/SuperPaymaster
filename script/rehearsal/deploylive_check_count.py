"""Pure row cardinality for the committed DeployLive assertion contract.

Address getters and most immutable bindings share the snapshot-policy row; they
are not individual SUMMARY rows. Runtime and version rows are per config entry.
"""

def expected_check_count(cfg, policy, artifacts, versions):
    guardians = int(cfg['guardianN'])
    if not 2 <= guardians <= 64:
        raise ValueError('invalid guardianN')
    proxy_abi = {'registry': 'Registry', 'superPaymaster': 'SuperPaymaster', 'pnts': 'xPNTsTokenV2'}
    runtime_rows = sum(name is not None or key == 'pnts' for key, name in artifacts.items())
    version_rows = sum(proxy_abi.get(key, name) in versions for key, name in artifacts.items())
    # Dedicated immutable rows supplement (not replace) full policy validation.
    immutable_rows = sum('codehashOf' in rule for rule in policy['immutableBindings']['xPNTsFactoryV2'].values())
    immutable_rows += sum(field in policy['immutableBindings'][name] for name, field in
                          (('GTokenAuthorization', '_cap'), ('MicroPaymentChannel', '_cachedThis')))
    # 182 fixed assertions include schema/policy, provider and header checks,
    # owner/role/Safe/security/ledger checks, and the three non-guardian stakes.
    # Each guardian contributes one membership and one additional stake row.
    return 182 + runtime_rows + version_rows + immutable_rows + 2 * guardians
