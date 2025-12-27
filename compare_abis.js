const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Configuration
const CONTRACTS_OUT_DIR = '/Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/out';
const SDK_ABIS_DIR_1 = '/Users/jason/Dev/mycelium/my-exploration/projects/aastar-sdk/abis';
const SDK_ABIS_DIR_2 = '/Users/jason/Dev/mycelium/my-exploration/projects/aastar-sdk/packages/core/src/abis';

// Mapping: SDK Filename -> Contract Artifact Path (relative to out/)
// Based on typical Foundry output structure: ContractName.sol/ContractName.json
const FILE_MAPPING = {
    'SuperPaymaster.json': 'SuperPaymasterV3.sol/SuperPaymasterV3.json',
    'Registry.json': 'Registry.sol/Registry.json',
    'GToken.json': 'GToken.sol/GToken.json',
    'GTokenStaking.json': 'GTokenStaking.sol/GTokenStakingV3.json', // Check this mapping
    'MySBT.json': 'MySBT.sol/MySBT.json',
    'BLSAggregator.json': 'BLSAggregatorV3.sol/BLSAggregatorV3.json',
    'DVTValidator.json': 'DVTValidatorV3.sol/DVTValidatorV3.json',
    'xPNTsFactory.json': 'xPNTsFactory.sol/xPNTsFactory.json',
    'ReputationSystem.json': 'ReputationSystemV3.sol/ReputationSystemV3.json',
    'PaymasterFactory.json': 'PaymasterFactory.sol/PaymasterFactory.json',
    'xPNTsToken.json': 'xPNTsToken.sol/xPNTsToken.json'
};

// Also check if GTokenStaking is just GTokenStaking.sol/GTokenStaking.json
// I'll try to find the file if the specific mapping fails.

function getAbiHash(abi) {
    const str = JSON.stringify(abi);
    return crypto.createHash('sha256').update(str).digest('hex');
}

function normalizeAbi(abi) {
    // We only care about the ABI array.
    // Sometimes formatting differs (spaces, newlines).
    // We can just rely on JSON.stringify for a quick check if they are structurally identical objects.
    // But safe comparison implies sorting keys? JSON.stringify order is not guaranteed but usually stable for same object construction.
    // Let's assume standard formatting. If fail, we can deep compare.
    return JSON.stringify(abi);
}

function findContractArtifact(sdkName, relPath) {
    let fullPath = path.join(CONTRACTS_OUT_DIR, relPath);
    if (fs.existsSync(fullPath)) return fullPath;

    // Fallback: Try to find by name directly if mapping might be slightly off (e.g. V3 suffix)
    // E.g. GTokenStaking.json might be in GTokenStaking.sol/GTokenStaking.json OR GTokenStakingV3.json
    // Let's try flexible search if primary fails.
    
    // Attempt 1: Check if filename without .json matches a directory
    const baseName = sdkName.replace('.json', '');
    const solDir = path.join(CONTRACTS_OUT_DIR, baseName + '.sol');
    if (fs.existsSync(solDir)) {
        const jsonPath = path.join(solDir, baseName + '.json');
        if (fs.existsSync(jsonPath)) return jsonPath;
    }

    return null;
}

function compare(dirName, dirPath) {
    console.log(`\n--- Comparing with ${dirName} ---`);
    console.log(`Path: ${dirPath}`);
    
    let allMatch = true;

    for (const [sdkFile, contractRelPath] of Object.entries(FILE_MAPPING)) {
        const sdkFilePath = path.join(dirPath, sdkFile);
        
        // Skip if file doesn't exist in this SDK folder (e.g. xPNTsToken might be in core but not root abis)
        if (!fs.existsSync(sdkFilePath)) {
            // console.log(`[SKIP] ${sdkFile} not found in SDK folder.`);
            continue;
        }

        const contractPath = findContractArtifact(sdkFile, contractRelPath);
        
        if (!contractPath) {
            console.log(`[WARN] ${sdkFile}: Could not find corresponding compiled contract artifact.`);
            console.log(`       Checked: ${contractRelPath}`);
            allMatch = false;
            continue;
        }

        try {
            // Read SDK ABI
            const sdkContent = fs.readFileSync(sdkFilePath, 'utf8');
            let sdkJson = JSON.parse(sdkContent);
            // SDK files might be the direct ABI array OR a JSON with "abi" field.
            let sdkAbi = Array.isArray(sdkJson) ? sdkJson : sdkJson.abi;

            if (!sdkAbi) {
                console.log(`[ERR ] ${sdkFile}: Could not extract ABI from SDK file.`);
                allMatch = false;
                continue;
            }

            // Read Contract ABI
            const contractContent = fs.readFileSync(contractPath, 'utf8');
            const contractJson = JSON.parse(contractContent);
            const contractAbi = contractJson.abi;

            if (!contractAbi) {
                console.log(`[ERR ] ${sdkFile}: Compiled artifact has no ABI field.`);
                allMatch = false;
                continue;
            }

            // Compare
            const sdkHash = getAbiHash(sdkAbi);
            const contractHash = getAbiHash(contractAbi);

            if (sdkHash === contractHash) {
                console.log(`[OK  ] ${sdkFile} matches.`);
            } else {
                console.log(`[FAIL] ${sdkFile} DIFFERS!`);
                console.log(`       SDK Path: ${sdkFilePath}`);
                console.log(`       Src Path: ${contractPath}`);
                allMatch = false;
            }

        } catch (e) {
            console.log(`[ERR ] ${sdkFile}: Error comparing - ${e.message}`);
            allMatch = false;
        }
    }
}

compare('SDK Root ABIs', SDK_ABIS_DIR_1);
compare('SDK Core ABIs', SDK_ABIS_DIR_2);
