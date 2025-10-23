// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/v2/core/SuperPaymasterV2.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title Step3_OperatorDeposit
 * @notice V2测试流程 - 步骤3: Operator充值aPNTs
 *
 * 功能：
 * 1. Mint aPNTs给operator (模拟operator购买aPNTs)
 * 2. Operator approve aPNTs
 * 3. Operator deposit aPNTs到SuperPaymaster
 * 4. 验证余额
 */
contract Step3_OperatorDeposit is Script {

    SuperPaymasterV2 superPaymaster;
    MockERC20 apntsToken;

    address operator;

    uint256 constant APNTS_DEPOSIT = 1000 ether;

    function setUp() public {
        // 加载合约
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        apntsToken = MockERC20(vm.envAddress("APNTS_TOKEN_ADDRESS"));

        // Operator账户
        operator = vm.envAddress("OWNER2_ADDRESS");
    }

    function run() public {
        console.log("=== Step 3: Operator Deposit aPNTs ===\n");
        console.log("Operator address:", operator);

        // 1. Deployer mint aPNTs给operator (模拟operator购买)
        console.log("\n3.1 Minting aPNTs to operator (simulating purchase)...");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        apntsToken.mint(operator, APNTS_DEPOSIT * 2);  // 多mint一些
        console.log("    Minted", (APNTS_DEPOSIT * 2) / 1e18, "aPNTs");
        vm.stopBroadcast();

        // 2. Operator deposit aPNTs
        console.log("\n3.2 Operator depositing aPNTs...");
        vm.startBroadcast(vm.envUint("OWNER2_PRIVATE_KEY"));

        uint256 operatorAPNTsBefore = apntsToken.balanceOf(operator);
        console.log("    Operator aPNTs balance before:", operatorAPNTsBefore / 1e18, "aPNTs");

        apntsToken.approve(address(superPaymaster), APNTS_DEPOSIT);
        superPaymaster.depositAPNTs(APNTS_DEPOSIT);

        uint256 operatorAPNTsAfter = apntsToken.balanceOf(operator);
        console.log("    Operator aPNTs balance after:", operatorAPNTsAfter / 1e18, "aPNTs");
        console.log("    Deposited:", APNTS_DEPOSIT / 1e18, "aPNTs");

        vm.stopBroadcast();

        // 3. 验证
        console.log("\n3.3 Verifying deposit...");
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator);
        uint256 contractAPNTs = apntsToken.balanceOf(address(superPaymaster));

        console.log("    Operator internal balance:", account.aPNTsBalance / 1e18, "aPNTs");
        console.log("    SuperPaymaster contract holds:", contractAPNTs / 1e18, "aPNTs");

        require(account.aPNTsBalance == APNTS_DEPOSIT, "Internal balance mismatch");
        require(contractAPNTs >= APNTS_DEPOSIT, "Contract balance mismatch");

        console.log("\n[SUCCESS] Step 3 completed!");
    }
}
