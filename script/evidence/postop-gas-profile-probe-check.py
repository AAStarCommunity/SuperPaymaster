from pathlib import Path
s=Path('contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol').read_text()
import re
base=Path('contracts/src/paymasters/superpaymaster/v3')
s=re.sub(r'"(\.[^"]+)"',lambda m:'"'+str((base/m[1]).resolve().relative_to(Path.cwd())).replace('contracts/src/','src/')+'"',s)
s=s.replace('contract SuperPaymaster is','contract ProfilePaymaster is')
s=s.replace('    function postOp(', '    event Trajectory(uint256[8] gasRemaining);\n\n    function postOp(')
s=s.replace('        if (context.length == 0) return;', '        uint256[8] memory g;\n        g[0] = gasleft();\n        if (context.length == 0) return;')
for old,new in [
('        OpCtx memory c = abi.decode(context, (OpCtx));','        g[1] = gasleft();\n        OpCtx memory c = abi.decode(context, (OpCtx));'),
('        // P1-17 idempotency', '        g[2] = gasleft();\n        // P1-17 idempotency'),
('        operators[c.operator].totalTxSponsored++;','        operators[c.operator].totalTxSponsored++;\n        g[3] = gasleft();'),
('        delete _inflight[c.opHash];','        g[4] = gasleft();\n        delete _inflight[c.opHash];\n        g[5] = gasleft();'),
('        protocolRevenue += charge;','        protocolRevenue += charge;\n        g[6] = gasleft();'),
('        emit ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge);','        emit ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge);\n        g[7] = gasleft();\n        emit Trajectory(g);')]:
 s=s.replace(old,new)
target = Path('contracts/test/helpers/ProfilePaymaster.sol')
assert target.read_text() == s, 'Test-only probe drift: regenerate from production source and review instrumentation'
