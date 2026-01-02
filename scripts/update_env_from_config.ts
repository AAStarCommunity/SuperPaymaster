import fs from 'fs';
import path from 'path';

// Map config.json keys to .env keys
const KEY_MAP: Record<string, string> = {
    "gToken": "GTOKEN_ADDRESS",
    "registry": "REGISTRY_ADDRESS",
    "staking": "STAKING_ADDRESS",
    "sbt": "MYSBT_ADDRESS",
    "superPaymaster": "PAYMASTER_SUPER", // Paymaster
    "paymasterV4Proxy": "PAYMASTER_V4_PROXY",
    "aPNTs": "APNTS_TOKEN_ADDRESS",
    "reputationSystem": "REPUTATION_SYSTEM",
    "xPNTsFactory": "XPNTS_FACTORY",
    "blsAggregator": "BLS_AGGREGATOR"
};

async function main() {
    const configFileName = process.env.CONFIG_FILE || 'config.json';
    console.log(`Syncing .env from ${configFileName}...`);
    
    const configPath = path.join(process.cwd(), configFileName);
    if (!fs.existsSync(configPath)) {
        console.error("config.json not found!");
        return;
    }

    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const envPath = path.join(process.cwd(), process.env.TARGET_ENV_FILE || '.env');
    
    let envContent = "";
    if (fs.existsSync(envPath)) {
        envContent = fs.readFileSync(envPath, 'utf8');
    }

    // Update keys
    let updatedEnv = envContent;
    
    for (const [jsonKey, envKey] of Object.entries(KEY_MAP)) {
        const val = config[jsonKey];
        if (val) {
            console.log(`Setting ${envKey}=${val}`);
            
            // Regex to replace existing or append
            const regex = new RegExp(`^${envKey}=.*`, 'm');
            if (regex.test(updatedEnv)) {
                updatedEnv = updatedEnv.replace(regex, `${envKey}=${val}`);
            } else {
                updatedEnv += `\n${envKey}=${val}`;
            }
        }
    }

    fs.writeFileSync(envPath, updatedEnv);
    console.log(".env updated successfully.");
}

main().catch(console.error);
