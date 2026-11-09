# Usage: python3 -I state_reads.py <rpcfile> <label> ; reads current state for every address ever seen
import json,glob,subprocess,sys,os
D='/Users/jason/Dev/aastar/manifest-live/reg02-sepolia-evidence/'
C=os.path.expanduser('~/.foundry/bin/cast'); U=open(os.path.expanduser(sys.argv[1])).read().strip(); LAB=sys.argv[2]
R='0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71'; S='0x4867B4302bf4C7818b71F55E53A3520Ee1855Aa7'
BLK=sys.argv[3]
def cast(*a):
  p=subprocess.run([C,a[0],'-r',U,'--block',BLK,*a[1:]],capture_output=True,text=True)
  if p.returncode: raise SystemExit('cast error: '+p.stderr.replace(U,'<url>')[:300])
  return p.stdout.strip()
def kk(s): return subprocess.run([C,'keccak',s],capture_output=True,text=True).stdout.strip()
ROLES={n:kk(n) for n in ['COMMUNITY','ENDUSER','PAYMASTER_AOA','PAYMASTER_SUPER','DVT','ANODE','KMS']}
def logs(d): return [l for f in glob.glob(D+f'logs/{d}/*.json') for l in json.load(open(f))]
RR='0x2c48d754bbf59f20e71c13710fac35aa1ea020da58dcbb366de0ef7f75c9377d'; RG='0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d'
TR='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
users=set()
for l in logs('reg_all_a'):
  if l['topics'][0] in (RR,RG): users.add('0x'+l['topics'][2][-40:])
sbt_holders=set()
for l in logs('sbt_all_a'):
  if l['topics'][0]==TR: users.add('0x'+l['topics'][2][-40:]); sbt_holders.add('0x'+l['topics'][2][-40:])
users.discard('0x'+'0'*40)
out=[]
for u in sorted(users):
  hr={n:cast('call',R,'hasRole(bytes32,address)(bool)',h,u)=='true' for n,h in ROLES.items()}
  slot=kk('0x'+u[2:].rjust(64,'0')+'%064x'%16)
  urc=int(cast('storage',R,slot),16)
  bal=int(cast('call',S,'balanceOf(address)(uint256)',u).split()[0])
  tid=int(cast('call',S,'getUserSBT(address)(uint256)',u).split()[0])
  act=cast('call',S,'getActiveMemberships(uint256)(address[])',str(tid)) if tid else '[]'
  allm=cast('call',S,'getMemberships(uint256)((address,uint256,bool,string)[])',str(tid)) if tid else '[]'
  out.append(dict(user=u,roles=[n for n,v in hr.items() if v],hasEndUser=hr['ENDUSER'],userRoleCount=urc,nRolesTrue=sum(hr.values()),sbtBalance=bal,sbtId=tid,active=act,memberships=allm))
json.dump(out,open(D+f'state_{LAB}.json','w'),indent=1)
A=[o for o in out if o['sbtBalance']>0 and o['userRoleCount']==0]
B=[o for o in out if not o['hasEndUser'] and o['active'] not in ('[]','')]
mis=[o['user'] for o in out if o['userRoleCount']!=o['nRolesTrue']]
print(LAB,'block',BLK,'users',len(out),'sbt_holders_ever',len(sbt_holders),'with_sbt_now',sum(o['sbtBalance']>0 for o in out))
print('A-state (SBT>0 & userRoleCount==0):',[o['user'] for o in A])
print('B-state (no ENDUSER & active membership):',[(o['user'],o['roles'],o['active']) for o in B])
print('userRoleCount != #hasRole-true mismatches:',mis)
