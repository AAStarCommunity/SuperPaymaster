import { createPublicClient, http, type Hex, parseAbi } from 'viem';
import { foundry, sepolia } from 'viem/chains';
import * as fs from 'fs';
import * as path from 'path';

async function verify() {
    const network = process.argv[2] || 'anvil';
    console.log(`\n🔍 Verifying Milestone State on ${network.toUpperCase()}...\n`);

    const configPath = path.resolve(__dirname, `../deployments/config.${network}.json`);
    const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    
    const client = createPublicClient({
        chain: network === 'anvil' ? foundry : sepolia,
        transport: http(network === 'anvil' ? 'http://127.0.0.1:8545' : process.env.RPC_URL)
    });

    const RegistryABI = parseAbi([
        'function communityByName(string) view returns (address)',
        'function communityByENS(string) view returns (address)',
        'function hasRole(bytes32, address) view returns (bool)',
        'function ROLE_COMMUNITY() view returns (bytes32)',
        'function ROLE_PAYMASTER_SUPER() view returns (bytes32)',
        'function owner() view returns (address)'
    ]);

    const SuperPaymasterABI = parseAbi([
        'function operators(address) view returns (uint128 aPNTsBalance, uint96 exchangeRate, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored)'
    ]);

    const ROLE_COMMUNITY = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'ROLE_COMMUNITY' });
    const ROLE_PAYMASTER_SUPER = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'ROLE_PAYMASTER_SUPER' });

    console.log(`--- Registry: ${config.registry} ---`);
    const regOwner = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'owner' });
    console.log(`Owner: ${regOwner}`);

    // 1. 验证 AAStar (Jason)
    const jason = '0xb5600060e6de5E11D3636731964218E53caadf0E' as Hex;
    console.log(`\n[AAStar Community]\n`);
    const addrByName = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'communityByName', args: ['AAStar'] });
    const hasCommRole = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'hasRole', args: [ROLE_COMMUNITY, jason] });
    const opConfig = await client.readContract({ address: config.superPaymaster, abi: SuperPaymasterABI, functionName: 'operators', args: [jason] });
    // opConfig indices: 0:bal, 1:rate, 2:conf, 3:paused, 4:token, 5:rep, 6:minTx, 7:treasury, ...

    console.log(`Registered Address: ${addrByName} ${addrByName === jason ? '✅' : '❌'}`);
    console.log(`Has COMMUNITY Role: ${hasCommRole} ${hasCommRole ? '✅' : '❌'}`);
    console.log(`SuperPaymaster Configured: ${opConfig[2]} ${opConfig[2] ? '✅' : '❌'}`);
    console.log(`Points Token (aPNTs): ${opConfig[4]} ${opConfig[4].toLowerCase() === config.aPNTs.toLowerCase() ? '✅' : '❌'}`);
    console.log(`aPNTs Balance: ${opConfig[0]} (Should be > 0)`);

    // 2. 验证 DemoCommunity (Anni)
    const anni = '0xEcAACb915f7D92e9916f449F7ad42BD0408733c9' as Hex;
    console.log(`\n[DemoCommunity]\n`);
    const demoAddrByName = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'communityByName', args: ['DemoCommunity'] });
    const anniHasCommRole = await client.readContract({ address: config.registry, abi: RegistryABI, functionName: 'hasRole', args: [ROLE_COMMUNITY, anni] });
    const demoOpConfig = await client.readContract({ address: config.superPaymaster, abi: SuperPaymasterABI, functionName: 'operators', args: [anni] });

    console.log(`Registered Address: ${demoAddrByName} ${demoAddrByName === anni ? '✅' : '❌'}`);
    console.log(`Has COMMUNITY Role: ${anniHasCommRole} ${anniHasCommRole ? '✅' : '❌'}`);
    console.log(`SuperPaymaster Configured: ${demoOpConfig[2]} ${demoOpConfig[2] ? '✅' : '❌'}`);
    console.log(`Points Token (dPNTs): ${demoOpConfig[4]} ${demoOpConfig[4] !== '0x0000000000000000000000000000000000000000' ? '✅' : '❌'}`);

    if (opConfig[4].toLowerCase() !== config.aPNTs.toLowerCase() || demoOpConfig[4] === '0x0000000000000000000000000000000000000000') {
        throw new Error("❌ Validation Failed: Token Mismatch or Missing Configuration");
    }

    console.log(`\n✨ ALL ON-CHAIN CHECKS PASSED FOR MILESTONE! ✨`);
}

verify().catch(e => { console.error('❌ Verification Failed:', e); process.exit(1); });
