// Local-only Phase C setup. Never imported by the formal runtime.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseAbi } from 'viem';
import { clients, deploy, send, ANVIL_KEYS } from '../b-layer/lib.mjs';
import { privateKeyToAccount } from 'viem/accounts';
import { sha256 } from './evidence.mjs';
const [url, dir, configPath, baselinePath] = process.argv.slice(2);
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(url)) throw Error('loopback only');
const ctx=clients(url), cfg=JSON.parse(readFileSync(configPath)), base=JSON.parse(readFileSync(baselinePath));
if (await ctx.pub.getChainId()!==31337) throw Error('local chain only');
const abi=parseAbi(['function getAddress(address,uint256) view returns(address)','function mint(address,uint256)']);
const sender=await ctx.pub.readContract({address:cfg.simpleAccountFactory,abi,functionName:'getAddress',args:[ctx.account.address,9001n]});
const task=await deploy(ctx,'F1Fixtures.sol','F1TestToken');
const recipient=privateKeyToAccount(ANVIL_KEYS[3]).address;
await send(ctx,task.address,abi,'mint',[sender,10000n]);
await send(ctx,task.address,abi,'mint',[recipient,1n]);
const config={frozen:true,chainId:31337,operator:ctx.account.address,factory:cfg.simpleAccountFactory,sender,salt:'9001',bundlerGasLimit:'3000000',
 accounts:Object.fromEntries(['owner','bundler','verifyingSigner'].map((role,i)=>[role,{name:`rehearsal-${role}`,address:privateKeyToAccount(ANVIL_KEYS[i]).address}])),
 fees:{maxFeePerGas:'5000000000',maxPriorityFeePerGas:'1000000000'},task:{token:task.address,recipient},rehearsalExpiredVpm:true,
 gas:Object.fromEntries(['SP','VPM','TPM'].map(arm=>[arm,{callGasLimit:'200000',verificationGasLimit:'300000',preVerificationGas:'60000',paymasterVerificationGasLimit:'450000',paymasterPostOpGasLimit:'480000'}]))};
const write=(name,x)=>writeFileSync(resolve(dir,name),JSON.stringify(x,null,2)+'\n');
write('formal-config.json',config);
// Keys are used only during local preparation; formal-format inputs contain addresses only.
delete base.verifyingPaymaster.signerKey; delete base.rpcUrl;
write('baselines.json',base);
writeFileSync(resolve(dir,'local-identity.txt'),'REHEARSAL ONLY: A and B share one local Anvil; no independence or evidence claim.\n');
const pin=path=>({path:resolve(path),sha256:sha256(readFileSync(path))});
const proof=pin(resolve(dir,'local-identity.txt'));
write('rpc-identity.json',{schemaVersion:'a6-rpc-identity/1',...Object.fromEntries(['A','B'].map(e=>[e,{operatorName:`rehearsal-${e}`,backendIdentity:`rehearsal-${e}`,upstream:`rehearsal-${e}`,endpointLabel:`local-${e}`,registeredAt:new Date().toISOString(),evidence:[proof]}]))});
const src='script/a6-collector/';
write('pins.json',{
 collector:readdirSync(src).filter(n=>n.endsWith('.mjs')).map(n=>pin(src+n)),validator:[pin(src+'validate.mjs')],dependencies:[pin('package-lock.json')],
 contractSources:[pin('contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol'),pin('singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol'),pin('singleton-paymaster/lib/account-abstraction-v7/contracts/samples/utils/OracleHelper.sol')],
 abi:['TokenPaymaster','VerifyingPaymaster'].map(n=>pin(src+`artifacts/${n}.json`)),config:[configPath,resolve(dir,'formal-config.json'),resolve(dir,'baselines.json')].map(pin)});
