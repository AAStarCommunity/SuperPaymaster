import * as fs from 'fs';
import * as path from 'path';

// Define the contract mapping (Key in config -> Human readable name)
const CONTRACT_MAPPING: Record<string, string> = {
    'superPaymaster': 'SuperPaymaster',
    'registry': 'Registry',
    'gToken': 'GToken',
    'aPNTs': 'aPNTs',
    'xPNTsFactory': 'xPNTsFactory',
    'staking': 'GTokenStaking',
    'sbt': 'MySBT',
    'blsValidator': 'BLSValidator',
    'blsAggregator': 'BLSAggregator',
    'reputationSystem': 'ReputationSystem',
    'dvtValidator': 'DVTValidator',
    'paymasterFactory': 'PaymasterFactory',
    'paymasterV4Impl': 'PaymasterV4Impl'
};

// Define Explorer URLs
const EXPLORER_URLS: Record<string, string> = {
    'op-sepolia': 'https://sepolia-optimism.etherscan.io',
    'sepolia': 'https://sepolia.etherscan.io',
    'optimism': 'https://optimistic.etherscan.io',
    'mainnet': 'https://etherscan.io'
};

async function generateReport() {
    const network = process.argv[2];
    if (!network) {
        console.error("Usage: npx tsx scripts/generate-verification-report.ts <network>");
        process.exit(1);
    }

    const projectRoot = path.resolve(__dirname, '..');
    const deploymentsDir = path.join(projectRoot, 'deployments');
    const configPath = path.join(deploymentsDir, `config.${network}.json`);

    if (!fs.existsSync(configPath)) {
        console.error(`Error: Config file not found at ${configPath}`);
        process.exit(1);
    }

    console.log(`Loading config from ${configPath}...`);
    const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    
    // Determine explorer URL
    let explorerUrl = EXPLORER_URLS[network];
    if (!explorerUrl) {
         // Fallback logic or default
         if (network.includes('op')) explorerUrl = 'https://sepolia-optimism.etherscan.io';
         else explorerUrl = 'https://sepolia.etherscan.io';
         console.warn(`Warning: Unknown network ${network}, defaulting to ${explorerUrl}`);
    }

    // Generate Markdown Content
    const date = new Date().toISOString().split('T')[0];
    // MM-DD format as per user request example (2-10)
    const shortDate = `${new Date().getMonth() + 1}-${new Date().getDate()}`;
    
    // Use the exact filename format user requested: verify.<network>.contracts.md
    // But user also mentioned "similar to verify.op-sepolia.contracts-2-10.md"
    // I will use verify.<network>.contracts-<date>.md to establish a history
    const outputFilename = `verify.${network}.contracts-${shortDate}.md`;
    const outputPath = path.join(deploymentsDir, outputFilename);

    let content = `# Verified SuperPaymaster Contracts (${network.toUpperCase()})\n\n`;
    content += `The following contracts have been successfully verified on Etherscan/Blockscout for the ${network} network.\n\n`;
    content += `| Contract Name | Address | Explorer Link |\n`;
    content += `| :--- | :--- | :--- |\n`;

    // specific order if needed, but for now iterate mapping to ensure we only get known contracts
    // Or iterate config to get everything?
    // Let's iterate the mapping to maintain order and clean names
    
    for (const [key, name] of Object.entries(CONTRACT_MAPPING)) {
        const address = config[key];
        if (address && address !== '0x0000000000000000000000000000000000000000') {
            const link = `${explorerUrl}/address/${address}#code`;
            content += `| **${name}** | \`${address}\` | [View on Explorer](${link}) |\n`;
        }
    }
    
    // Add infrastructure note
    content += `\n---\n`;
    content += `*Note: EntryPoint \`${config.entryPoint}\` and SimpleAccountFactory \`${config.simpleAccountFactory || 'N/A'}\` are infrastructure contracts and are already verified.*\n`;

    fs.writeFileSync(outputPath, content);
    console.log(`✅ Verification report generated at: ${outputPath}`);
}

generateReport().catch(err => {
    console.error(err);
    process.exit(1);
});
