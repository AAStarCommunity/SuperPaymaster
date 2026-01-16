#!/usr/bin/env node

/**
 * Migration Script: Update all frontend calls from v2 to v3 API
 * This script updates deprecated scripts to use the new unified registerRole() API
 */

const fs = require('fs');
const path = require('path');

// Role IDs from v3
const ROLE_IDS = {
    ENDUSER: '0x' + Buffer.from('ENDUSER').toString('hex').padEnd(64, '0'),
    COMMUNITY: '0x' + Buffer.from('COMMUNITY').toString('hex').padEnd(64, '0'),
    PAYMASTER: '0x' + Buffer.from('PAYMASTER').toString('hex').padEnd(64, '0'),
    SUPER: '0x' + Buffer.from('SUPER').toString('hex').padEnd(64, '0')
};

// Mapping of old function calls to new v3 API
const API_MAPPING = {
    // Registry v2 -> v3 mappings
    'registerCommunity': {
        old: /registry\.registerCommunity\((.*?)\)/gs,
        new: (match, args) => `registry.registerRole(ROLE_COMMUNITY, msg.sender, ${args})`
    },
    'registerPaymaster': {
        old: /registry\.registerPaymaster\((.*?)\)/gs,
        new: (match, args) => `registry.registerRole(ROLE_PAYMASTER, msg.sender, ${args})`
    },
    'registerSuperPaymaster': {
        old: /registry\.registerSuperPaymaster\((.*?)\)/gs,
        new: (match, args) => `registry.registerRole(ROLE_SUPER, msg.sender, ${args})`
    },
    'registerEndUser': {
        old: /registry\.registerEndUser\((.*?)\)/gs,
        new: (match, args) => `registry.registerRole(ROLE_ENDUSER, msg.sender, ${args || '""'})`
    },
    'exitCommunity': {
        old: /registry\.exitCommunity\(\)/gs,
        new: () => `registry.exitRole(ROLE_COMMUNITY)`
    },
    'exitPaymaster': {
        old: /registry\.exitPaymaster\(\)/gs,
        new: () => `registry.exitRole(ROLE_PAYMASTER)`
    },
    'exitSuperPaymaster': {
        old: /registry\.exitSuperPaymaster\(\)/gs,
        new: () => `registry.exitRole(ROLE_SUPER)`
    },
    'safeMint': {
        old: /registry\.safeMint\((.*?)\)/gs,
        new: (match, args) => `registry.safeMintForRole(ROLE_ENDUSER, ${args})`
    },

    // MySBT function mappings
    'safeMintAndJoin': {
        old: /mySBT\.safeMintAndJoin\((.*?)\)/gs,
        new: (match, args) => `mySBT.safeMintAndJoin(${args}) // v3 compatible`
    },

    // GTokenStaking mappings
    'lockStake': {
        old: /gTokenStaking\.lockStake\(([^,]+),\s*([^,]+),\s*"([^"]+)"\)/gs,
        new: (match, user, amount, purpose) => {
            // Determine roleId based on purpose
            let roleId = 'ROLE_ENDUSER';
            if (purpose.includes('Registry')) roleId = 'ROLE_COMMUNITY';
            if (purpose.includes('Paymaster')) roleId = 'ROLE_PAYMASTER';
            return `gTokenStaking.lockStake(${user}, ${roleId}, ${amount}, entryBurn)`;
        }
    },
    'unlockStake': {
        old: /gTokenStaking\.unlockStake\(([^,]+),\s*([^)]+)\)/gs,
        new: (match, user, amount) => `gTokenStaking.unlockStake(${user}, roleId)`
    },
    'getLockedStake': {
        old: /gTokenStaking\.getLockedStake\(([^,]+),\s*([^)]+)\)/gs,
        new: (match, user, locker) => `gTokenStaking.getLockedStake(${user}, roleId)`
    }
};

// Files to update
const filesToUpdate = [
    'deprecated/scripts/tx-test/2-setup-communities-and-xpnts.js',
    'deprecated/scripts/testSbtMint.js',
    'deprecated/scripts/test-prepare-assets.js',
    'deprecated/scripts/register-aastar-community.js',
    'deprecated/scripts/tx-test/utils/config.js'
];

// Update ABI references in config files
function updateABIReferences(content) {
    // Update Registry ABI
    content = content.replace(
        /REGISTRY:\s*loadABI\(".*?Registry\.sol\/Registry\.json"\)/g,
        'REGISTRY: loadABI("../../../abis/Registry_v3.json")'
    );

    // Update MySBT ABI
    content = content.replace(
        /MYSBT:\s*loadABI\(".*?MySBT.*?\.json"\)/g,
        'MYSBT: loadABI("../../../abis/MySBT_v3.json")'
    );

    // Update GTokenStaking ABI
    content = content.replace(
        /GTOKEN_STAKING:\s*loadABI\(".*?GTokenStaking.*?\.json"\)/g,
        'GTOKEN_STAKING: loadABI("../../../abis/IGTokenStakingV3.json")'
    );

    return content;
}

// Add role ID constants to the top of JS files
function addRoleConstants(content) {
    if (!content.includes('// Role IDs for v3')) {
        const roleConstants = `
// Role IDs for v3
const ROLE_ENDUSER = '${ROLE_IDS.ENDUSER}';
const ROLE_COMMUNITY = '${ROLE_IDS.COMMUNITY}';
const ROLE_PAYMASTER = '${ROLE_IDS.PAYMASTER}';
const ROLE_SUPER = '${ROLE_IDS.SUPER}';
`;
        // Insert after require statements
        const requireIndex = content.lastIndexOf('require(');
        if (requireIndex !== -1) {
            const lineEnd = content.indexOf('\n', requireIndex);
            content = content.slice(0, lineEnd + 1) + roleConstants + content.slice(lineEnd + 1);
        } else {
            content = roleConstants + content;
        }
    }
    return content;
}

// Process each file
function processFile(filePath) {
    const fullPath = path.join(__dirname, '..', filePath);

    if (!fs.existsSync(fullPath)) {
        console.log(`⚠️  File not found: ${filePath}`);
        return;
    }

    let content = fs.readFileSync(fullPath, 'utf8');
    let modified = false;

    // Add role constants
    const originalContent = content;
    content = addRoleConstants(content);
    if (content !== originalContent) modified = true;

    // Update ABI references
    if (filePath.includes('config.js')) {
        content = updateABIReferences(content);
        modified = true;
    }

    // Apply API mappings
    for (const [funcName, mapping] of Object.entries(API_MAPPING)) {
        const regex = mapping.old;
        if (regex.test(content)) {
            content = content.replace(regex, mapping.new);
            modified = true;
            console.log(`  ✅ Updated ${funcName} calls`);
        }
    }

    // Add migration comment
    if (modified) {
        const migrationComment = `// [MIGRATED TO V3]: This file has been updated to use Mycelium Protocol v3 API
// Migration Date: ${new Date().toISOString().split('T')[0]}
// Changes: registerCommunity() -> registerRole(ROLE_COMMUNITY, ...)
//          exitCommunity() -> exitRole(ROLE_COMMUNITY)
//          See FRONTEND_MIGRATION_EXAMPLES_V3.md for details
`;
        if (!content.includes('[MIGRATED TO V3]')) {
            content = migrationComment + '\n' + content;
        }

        // Write updated content
        fs.writeFileSync(fullPath, content);
        console.log(`✅ Updated: ${filePath}`);
    } else {
        console.log(`⏭️  No changes needed: ${filePath}`);
    }
}

// Create v3 config file
function createV3Config() {
    const v3Config = `/**
 * Mycelium Protocol v3 Configuration
 * Updated from v2 to use unified registerRole() API
 */

const { ethers } = require("ethers");

// Role IDs for v3
const ROLE_ENDUSER = '${ROLE_IDS.ENDUSER}';
const ROLE_COMMUNITY = '${ROLE_IDS.COMMUNITY}';
const ROLE_PAYMASTER = '${ROLE_IDS.PAYMASTER}';
const ROLE_SUPER = '${ROLE_IDS.SUPER}';

// Contract addresses (update these with v3 deployments)
const CONTRACTS_V3 = {
    REGISTRY_V3: process.env.REGISTRY_V3_ADDRESS || "0x...",
    MYSBT_V3: process.env.MYSBT_V3_ADDRESS || "0x...",
    GTOKEN_STAKING_V3: process.env.GTOKEN_STAKING_V3_ADDRESS || "0x...",

    // Existing contracts remain the same
    GTOKEN: "0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc",
    ENTRYPOINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
};

// Load v3 ABIs
const ABIS_V3 = {
    REGISTRY_V3: require("./abis/Registry_v3.json"),
    MYSBT_V3: require("./abis/MySBT_v3.json"),
    GTOKEN_STAKING_V3: require("./abis/IGTokenStakingV3.json"),
};

// Helper function: Encode role data for registerRole()
function encodeRoleData(roleId, data) {
    if (roleId === ROLE_COMMUNITY) {
        return ethers.utils.defaultAbiCoder.encode(
            ["tuple(string,string,address,address[],address,bool)", "uint256"],
            [data.profile, data.stakeAmount]
        );
    } else if (roleId === ROLE_ENDUSER) {
        return ethers.utils.defaultAbiCoder.encode(["string"], [data.metadata || ""]);
    }
    // Add other role encodings as needed
    return "0x";
}

module.exports = {
    ROLE_ENDUSER,
    ROLE_COMMUNITY,
    ROLE_PAYMASTER,
    ROLE_SUPER,
    CONTRACTS_V3,
    ABIS_V3,
    encodeRoleData
};
`;

    fs.writeFileSync(
        path.join(__dirname, '..', 'scripts', 'config-v3.js'),
        v3Config
    );
    console.log('✅ Created: scripts/config-v3.js');
}

// Main execution
console.log('=== Mycelium Protocol v3 Migration Script ===\n');
console.log('Updating frontend scripts to use v3 API...\n');

// Process each file
filesToUpdate.forEach(file => {
    processFile(file);
});

// Create v3 config
createV3Config();

console.log('\n=== Migration Complete ===');
console.log('Next steps:');
console.log('1. Update contract addresses in scripts/config-v3.js');
console.log('2. Test all updated scripts with v3 contracts');
console.log('3. Deploy v3 contracts to testnet');
console.log('4. Run integration tests');