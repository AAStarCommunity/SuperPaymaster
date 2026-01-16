const fs = require('fs');
const path = require('path');

// Run from SuperPaymaster/scripts
const SOURCE_DIR = path.resolve(__dirname, '../out');
// Dest: SuperPaymaster/../aastar-sdk/packages/core/src/abis
const DEST_DIR = path.resolve(__dirname, '../../aastar-sdk/packages/core/src/abis');

const CONTRACTS = [
    { src: 'Registry.sol/Registry.json', dest: 'Registry.json' },
    { src: 'SuperPaymasterV3.sol/SuperPaymasterV3.json', dest: 'SuperPaymaster.json' },
    { src: 'GToken.sol/GToken.json', dest: 'GToken.json' },
    { src: 'GTokenStaking.sol/GTokenStaking.json', dest: 'GTokenStaking.json' },
    { src: 'MySBT.sol/MySBT.json', dest: 'MySBT.json' },
    { src: 'PaymasterFactory.sol/PaymasterFactory.json', dest: 'PaymasterFactory.json' },
    { src: 'PaymasterV4_2.sol/PaymasterV4_2.json', dest: 'Paymaster.json' },
    { src: 'xPNTsFactory.sol/xPNTsFactory.json', dest: 'xPNTsFactory.json' },
    { src: 'xPNTsToken.sol/xPNTsToken.json', dest: 'xPNTs.json' },
    { src: 'ReputationSystemV3.sol/ReputationSystemV3.json', dest: 'ReputationSystem.json' },
    { src: 'SimpleAccount.sol/SimpleAccount.json', dest: 'SimpleAccount.json' },
    { src: 'SimpleAccountFactory.sol/SimpleAccountFactory.json', dest: 'SimpleAccountFactory.json' }
];

console.log(`Extracting ABIs from ${SOURCE_DIR} to ${DEST_DIR}`);

if (!fs.existsSync(DEST_DIR)) {
    console.error(`Destination directory does not exist: ${DEST_DIR}`);
    // Create it?
    // fs.mkdirSync(DEST_DIR, { recursive: true });
}

CONTRACTS.forEach(c => {
    // Try simplified path first, then nested
    let srcPath = path.join(SOURCE_DIR, c.src);
    
    // Auto-detect nested path if not found (e.g. PaymasterFactory might be in v4/core)
    if (!fs.existsSync(srcPath)) {
        // Find recursively? Or just hardcode known paths.
        if (c.src.includes('PaymasterFactory')) {
             srcPath = path.join(SOURCE_DIR, 'paymasters/v4/core/PaymasterFactory.sol/PaymasterFactory.json');
        }
    }

    // Check again
    if (!fs.existsSync(srcPath)) {
         // Maybe flat structure in out? Foundry flattens sometimes?
         // Check out/PaymasterFactory.sol/PaymasterFactory.json
         const flatPath = path.join(SOURCE_DIR, path.basename(c.src).split('.')[0] + '.sol', path.basename(c.src));
         if (fs.existsSync(flatPath)) {
             srcPath = flatPath;
         }
    }

    const destPath = path.join(DEST_DIR, c.dest);

    if (fs.existsSync(srcPath)) {
        try {
            const content = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
            const abi = content.abi;
            if (abi) {
                fs.writeFileSync(destPath, JSON.stringify(abi, null, 2));
                console.log(`✅ Extracted ABI: ${c.src} -> ${c.dest}`);
            } else {
                console.error(`❌ No ABI found in ${srcPath}`);
            }
        } catch (e) {
             console.error(`❌ Error parsing ${srcPath}: ${e.message}`);
        }
    } else {
        console.error(`❌ Source Not Found: ${c.src}`);
        // List directory to help debug
        // console.log(fs.readdirSync(SOURCE_DIR));
    }
});
