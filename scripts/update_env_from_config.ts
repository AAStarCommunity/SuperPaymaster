import fs from 'fs';
import path from 'path';

/**
 * SuperPaymaster Configuration Sync Tool
 * Syncs contract addresses from deployments/*.json to .env.* files
 */

// Map config.json keys to .env keys
const KEY_MAP: Record<string, string> = {
    "registry": "REGISTRY_ADDRESS",
    "gToken": "GTOKEN_ADDRESS",
    "staking": "STAKING_ADDRESS",
    "superPaymaster": "SUPER_PAYMASTER_ADDRESS",
    "paymasterFactory": "PAYMASTER_FACTORY_ADDRESS",
    "aPNTs": "APNTS_TOKEN_ADDRESS",
    "sbt": "MYSBT_ADDRESS",
    "reputationSystem": "REPUTATION_SYSTEM_ADDRESS",
    "dvtValidator": "DVT_VALIDATOR_ADDRESS",
    "blsAggregator": "BLS_AGGREGATOR_ADDRESS",
    "blsValidator": "BLS_VALIDATOR_ADDRESS",
    "xPNTsFactory": "XPNTS_FACTORY_ADDRESS",
    "paymasterV4Impl": "PAYMASTER_V4_IMPL_ADDRESS",
    "entryPoint": "ENTRY_POINT_ADDRESS"
};

async function main() {
    // Parse arguments
    const args = process.argv.slice(2);
    let configArg = "";
    let outputArg = "";

    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--config') configArg = args[i + 1];
        if (args[i] === '--output') outputArg = args[i + 1];
    }

    // Determine paths
    const configFileName = configArg || process.env.CONFIG_FILE || 'anvil.json';
    const envFileName = outputArg || process.env.TARGET_ENV_FILE || '.env.anvil';

    // Ensure configFileName has path if it's just a name
    const configPath = configFileName.includes('/') 
        ? path.resolve(process.cwd(), configFileName)
        : path.resolve(process.cwd(), 'deployments', configFileName);

    const envPath = path.resolve(process.cwd(), envFileName);

    console.log(`🚀 Syncing addresses:`);
    console.log(`   Source: ${configPath}`);
    console.log(`   Target: ${envPath}`);
    
    if (!fs.existsSync(configPath)) {
        console.error(`❌ Error: Deployment config not found at ${configPath}`);
        process.exit(1);
    }

    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    
    let envContent = "";
    if (fs.existsSync(envPath)) {
        envContent = fs.readFileSync(envPath, 'utf8');
    } else {
        console.log(`📝 Creating new environment file: ${envFileName}`);
    }

    // Update keys
    let updatedEnv = envContent;
    
    for (const [jsonKey, envKey] of Object.entries(KEY_MAP)) {
        const val = config[jsonKey];
        if (val) {
            // console.log(`   ${envKey}=${val}`);
            
            // Regex to replace existing or append
            const regex = new RegExp(`^${envKey}=.*`, 'm');
            if (regex.test(updatedEnv)) {
                updatedEnv = updatedEnv.replace(regex, `${envKey}=${val}`);
            } else {
                updatedEnv = updatedEnv.trim() + `\n${envKey}=${val}\n`;
            }
        }
    }

    fs.writeFileSync(envPath, updatedEnv.trim() + '\n');
    console.log("✅ Sync complete.");
}

main().catch(console.error);