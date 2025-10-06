#!/bin/bash
# SuperPaymaster V3 端到端测试
# 完整测试 ERC-4337 UserOperation 流程

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}SuperPaymaster V3 E2E Test${NC}"
echo -e "${GREEN}ERC-4337 UserOperation Flow${NC}"
echo -e "${GREEN}========================================${NC}"

# 加载环境变量
if [ -f .env.v3 ]; then
    source .env.v3
else
    echo -e "${RED}Error: .env.v3 file not found${NC}"
    exit 1
fi

# 测试配置
ENTRYPOINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
BUNDLER_RPC="https://eth-sepolia.g.alchemy.com/v2/${SEPOLIA_RPC_URL##*/}"

echo -e "\n${BLUE}[配置信息]${NC}"
echo -e "EntryPoint:  ${ENTRYPOINT}"
echo -e "Settlement:  ${SETTLEMENT_ADDRESS}"
echo -e "PaymasterV3: ${PAYMASTER_V3_ADDRESS}"
echo -e "User1:       ${TEST_USER_ADDRESS}"
echo -e "User2:       ${TEST_USER_ADDRESS2}"
echo -e "SBT:         ${SBT_CONTRACT_ADDRESS}"
echo -e "PNT Token:   ${GAS_TOKEN_ADDRESS}"

# ============================================
# Step 1: PaymasterV3 向 EntryPoint deposit
# ============================================
echo -e "\n${YELLOW}[Step 1] Checking PaymasterV3 deposit in EntryPoint...${NC}"

DEPOSIT_INFO=$(cast call $ENTRYPOINT \
  "getDepositInfo(address)(uint256,bool,uint112,uint32,uint48)" \
  $PAYMASTER_V3_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")

CURRENT_DEPOSIT=$(echo "$DEPOSIT_INFO" | head -1)
echo -e "Current deposit: ${CURRENT_DEPOSIT} wei"

REQUIRED_DEPOSIT="20000000000000000"  # 0.02 ETH
if [ "$CURRENT_DEPOSIT" -lt "$REQUIRED_DEPOSIT" ]; then
    echo -e "${YELLOW}Depositing 0.02 ETH to EntryPoint...${NC}"

    TX=$(cast send $ENTRYPOINT \
      "depositTo(address)" \
      $PAYMASTER_V3_ADDRESS \
      --value 0.02ether \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$PRIVATE_KEY" \
      --legacy \
      --json)

    TX_HASH=$(echo $TX | jq -r '.transactionHash')
    echo -e "${GREEN}✅ Deposit successful!${NC}"
    echo -e "TX: https://sepolia.etherscan.io/tx/${TX_HASH}"
else
    echo -e "${GREEN}✅ Deposit sufficient: $(cast --from-wei $CURRENT_DEPOSIT) ETH${NC}"
fi

# ============================================
# Step 2: 检查 User1 的资格和余额
# ============================================
echo -e "\n${YELLOW}[Step 2] Checking User1 qualifications...${NC}"

# 检查 SBT
HAS_SBT=$(cast call $SBT_CONTRACT_ADDRESS \
  "balanceOf(address)(uint256)" \
  $TEST_USER_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")
echo -e "SBT Balance: ${HAS_SBT}"

if [ "$HAS_SBT" = "0" ]; then
    echo -e "${RED}❌ User1 does not have SBT!${NC}"
    echo -e "${YELLOW}Please mint SBT first${NC}"
    exit 1
fi

# 检查 PNT 余额
PNT_BALANCE=$(cast call $GAS_TOKEN_ADDRESS \
  "balanceOf(address)(uint256)" \
  $TEST_USER_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")
echo -e "PNT Balance: ${PNT_BALANCE} ($(cast --from-wei $PNT_BALANCE))"

MIN_BALANCE="10000000000000000000"  # 10 PNT
if [ "$PNT_BALANCE" -lt "$MIN_BALANCE" ]; then
    echo -e "${RED}❌ User1 PNT balance insufficient!${NC}"
    echo -e "${YELLOW}Required: $(cast --from-wei $MIN_BALANCE) PNT${NC}"
    exit 1
fi

echo -e "${GREEN}✅ User1 qualified (has SBT and sufficient PNT)${NC}"

# ============================================
# Step 3: 构造并提交 UserOperation
# ============================================
echo -e "\n${YELLOW}[Step 3] Constructing UserOperation...${NC}"
echo -e "${BLUE}This step requires JavaScript/TypeScript${NC}"
echo -e "${BLUE}Creating Node.js test script...${NC}"

# 创建 Node.js 测试脚本
cat > test-userop.js << 'EOFJS'
const { ethers } = require('ethers');
const axios = require('axios');

// 从环境变量读取配置
const config = {
    rpcUrl: process.env.SEPOLIA_RPC_URL,
    bundlerUrl: `https://eth-sepolia.g.alchemy.com/v2/${process.env.SEPOLIA_RPC_URL.split('/').pop()}`,
    entryPoint: '0x0000000071727De22E5E9d8BAf0edAc6f37da032',
    paymaster: process.env.PAYMASTER_V3_ADDRESS,
    sender: process.env.TEST_USER_ADDRESS,
    recipient: process.env.TEST_USER_ADDRESS2,
    privateKey: process.env.TEST_USER_PRIVATE_KEY  // 需要用户提供
};

async function main() {
    console.log('\n🔧 Constructing UserOperation...\n');

    const provider = new ethers.JsonRpcProvider(config.rpcUrl);
    const wallet = new ethers.Wallet(config.privateKey, provider);

    // 1. 构造 UserOperation
    const userOp = {
        sender: config.sender,
        nonce: '0x0',  // 需要从 EntryPoint 获取
        factory: ethers.ZeroAddress,
        factoryData: '0x',
        callData: '0x',  // 简单的转账 callData
        callGasLimit: '0x' + (50000).toString(16),
        verificationGasLimit: '0x' + (150000).toString(16),
        preVerificationGas: '0x' + (21000).toString(16),
        maxFeePerGas: '0x' + (2000000000).toString(16),
        maxPriorityFeePerGas: '0x' + (1000000000).toString(16),
        paymaster: config.paymaster,
        paymasterVerificationGasLimit: '0x' + (100000).toString(16),
        paymasterPostOpGasLimit: '0x' + (50000).toString(16),
        paymasterData: '0x',
        signature: '0x'
    };

    console.log('UserOperation:', JSON.stringify(userOp, null, 2));

    // 2. 通过 Alchemy Bundler 提交
    console.log('\n📡 Submitting to Bundler...\n');

    try {
        const response = await axios.post(config.bundlerUrl, {
            jsonrpc: '2.0',
            id: 1,
            method: 'eth_sendUserOperation',
            params: [userOp, config.entryPoint]
        });

        console.log('✅ UserOperation submitted!');
        console.log('UserOp Hash:', response.data.result);

        return response.data.result;
    } catch (error) {
        console.error('❌ Failed to submit UserOperation:', error.response?.data || error.message);
        throw error;
    }
}

if (require.main === module) {
    main().catch(console.error);
}

module.exports = { main };
EOFJS

# ============================================
# Step 4: 等待用户提供私钥并执行
# ============================================
echo -e "\n${YELLOW}[Step 4] UserOperation Submission${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  Manual Action Required${NC}"
echo -e ""
echo -e "To submit a real UserOperation via Alchemy Bundler:"
echo -e ""
echo -e "1. Install dependencies:"
echo -e "   ${BLUE}npm install ethers axios${NC}"
echo -e ""
echo -e "2. Set User1 private key:"
echo -e "   ${BLUE}export TEST_USER_PRIVATE_KEY=0x...${NC}"
echo -e ""
echo -e "3. Run the test script:"
echo -e "   ${BLUE}node test-userop.js${NC}"
echo -e ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ============================================
# Step 5: 检查 Settlement 记账
# ============================================
echo -e "\n${YELLOW}[Step 5] Checking Settlement Records (after UserOp execution)${NC}"
echo -e "${BLUE}Run this after UserOperation is executed:${NC}"
echo -e ""

cat > check-settlement.sh << 'EOFCHECK'
#!/bin/bash
source .env.v3

echo "Checking pending balance for User1..."
PENDING=$(cast call $SETTLEMENT_ADDRESS \
  "pendingAmounts(address,address)(uint256)" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")

echo "Pending amount: ${PENDING} wei"

if [ "$PENDING" -gt "0" ]; then
    echo "✅ Fee recorded successfully!"
    echo ""
    echo "Getting pending records..."

    # 获取 pending 记录
    cast call $SETTLEMENT_ADDRESS \
      "getUserPendingRecords(address,address)(bytes32[])" \
      $TEST_USER_ADDRESS \
      $GAS_TOKEN_ADDRESS \
      --rpc-url "$SEPOLIA_RPC_URL"
else
    echo "⚠️  No pending fees recorded yet"
fi
EOFCHECK

chmod +x check-settlement.sh

echo -e "   ${BLUE}./check-settlement.sh${NC}"
echo -e ""

# ============================================
# Step 6: 执行批量结算
# ============================================
echo -e "\n${YELLOW}[Step 6] Batch Settlement (after fees recorded)${NC}"
echo -e "${BLUE}Run this to settle pending fees:${NC}"
echo -e ""

cat > settle-fees.sh << 'EOFSETTLE'
#!/bin/bash
source .env.v3

echo "Getting pending records for User1..."
RECORDS=$(cast call $SETTLEMENT_ADDRESS \
  "getUserPendingRecords(address,address)(bytes32[])" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")

echo "Pending records: ${RECORDS}"

if [ -z "$RECORDS" ] || [ "$RECORDS" = "[]" ]; then
    echo "No pending records to settle"
    exit 0
fi

echo "Executing batch settlement..."
SETTLEMENT_HASH=$(date +%s | sha256sum | head -c 64)

# 需要 owner 调用
cast send $SETTLEMENT_ADDRESS \
  "settleFees(bytes32[],bytes32)" \
  "$RECORDS" \
  "0x${SETTLEMENT_HASH}" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy

echo "✅ Settlement completed!"
EOFSETTLE

chmod +x settle-fees.sh

echo -e "   ${BLUE}./settle-fees.sh${NC}"
echo -e ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}E2E Test Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e ""
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Provide TEST_USER_PRIVATE_KEY for User1"
echo -e "2. Run: ${BLUE}node test-userop.js${NC}"
echo -e "3. Wait for UserOp execution"
echo -e "4. Run: ${BLUE}./check-settlement.sh${NC}"
echo -e "5. Run: ${BLUE}./settle-fees.sh${NC}"
echo -e ""
echo -e "${BLUE}All helper scripts created:${NC}"
echo -e "- test-userop.js: Submit UserOperation via Bundler"
echo -e "- check-settlement.sh: Check pending fees"
echo -e "- settle-fees.sh: Execute batch settlement"
