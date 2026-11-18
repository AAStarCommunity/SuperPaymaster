from pathlib import Path
import re, subprocess
paths=[Path('contracts/script/v3/DeployLive.s.sol'),Path('contracts/script/v3/DeployLiveInputs.sol')]
originals=[p.read_text() for p in paths]
s=originals[0]
labels=['facilitator owner','single owner','mint accounting','stake accounting','ticket treasury','GToken conservation','deployer GToken balance','recipient GToken delta','slash admin','timelock nonce','predicted timelock before CREATE']
for label in labels:
 pattern=r'require\(([^\n]*), "handover: '+re.escape(label)+r'"\)'
 s,n=re.subn(pattern,'require(true, "handover: '+label+'")',s)
 assert n==1,(label,n)
s=s.replace('new address[](guardiansInput.length + 6)','new address[](guardiansInput.length + 7)').replace('subjects[i + 6] =','subjects[i + 7] =')
try:
 paths[0].write_text(s)
 paths[1].write_text(originals[1].replace('require(owners[i] != sender,','require(true,'))
 with Path('cache/deploylive-tests/round6b/red-solidity-assertions.log').open('w') as log:
  r=subprocess.run(['/Users/jason/.foundry/bin/forge','test','--offline','--match-test','test_ProductionPathN3|test_SubjectSlotsHaveNoUnassignedEntry|test_Round6b'],stdout=log,stderr=subprocess.STDOUT)
 print('mutated Solidity exit:',r.returncode)
finally:
 for p,s in zip(paths,originals):p.write_text(s)
