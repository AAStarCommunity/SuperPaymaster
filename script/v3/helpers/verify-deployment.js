const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

async function main() {
    console.log("验证合约部署...\n");
    
    const configPath = path.join(__dirname, '../config.json');
    if (!fs.existsSync(configPath)) {
        console.error("❌ config.json 不存在");
        process.exit(1);
    }
    
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545');
    
    const contracts = [
        'entryPoint',
        'gToken',
        'staking',
        'registry',
        'sbt',
        'superPaymaster',
        'aPNTs',
        'xPNTsFactory',
        'paymasterFactory',
        'paymasterV4Impl',
        'paymasterV4Proxy',
        'simpleAccountFactory'
    ];
    
    let allValid = true;
    
    for (const name of contracts) {
        const address = config[name];
        if (!address) {
            console.log(`⚠️  ${name}: 未配置`);
            continue;
        }
        
        const code = await provider.getCode(address);
        if (code === '0x') {
            console.log(`❌ ${name}: ${address} (无代码)`);
            allValid = false;
        } else {
            console.log(`✅ ${name}: ${address} (${code.length} bytes)`);
        }
    }
    
    if (!allValid) {
        console.error("\n❌ 部分合约验证失败");
        process.exit(1);
    }
    
    console.log("\n✅ 所有合约验证通过");
    process.exit(0);
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
