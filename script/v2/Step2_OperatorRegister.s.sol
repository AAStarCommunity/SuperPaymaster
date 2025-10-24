// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBT.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title Step2_OperatorRegister
 * @notice V2测试流程 - 步骤2: Operator注册
 *
 * 功能：
 * 1. Mint GToken给operator
 * 2. Operator stake GToken获得sGToken
 * 3. Operator部署xPNTs token
 * 4. Operator注册到SuperPaymaster
 */
contract Step2_OperatorRegister is Script {

    MockERC20 gtoken;
    GTokenStaking gtokenStaking;
    SuperPaymasterV2 superPaymaster;
    xPNTsFactory xpntsFactory;
    MySBT mysbt;

    address operator;
    address operatorTreasury;

    uint256 constant STAKE_AMOUNT = 100 ether;
    uint256 constant LOCK_AMOUNT = 50 ether;

    function setUp() public {
        // 加载合约
        gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        xpntsFactory = xPNTsFactory(vm.envAddress("XPNTS_FACTORY_ADDRESS"));
        mysbt = MySBT(vm.envAddress("MYSBT_ADDRESS"));

        // Operator账户
        operator = vm.envAddress("OWNER2_ADDRESS");
        operatorTreasury = address(0x777);
    }

    function run() public {
        console.log("=== Step 2: Operator Registration ===\n");
        console.log("Operator address:", operator);
        console.log("Operator treasury:", operatorTreasury);

        // 1. Deployer mint GToken给operator
        console.log("\n2.1 Minting GToken to operator...");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        gtoken.mint(operator, STAKE_AMOUNT);
        console.log("    Minted", STAKE_AMOUNT / 1e18, "GToken");
        vm.stopBroadcast();

        // 2. Operator stake GToken
        console.log("\n2.2 Operator staking GToken...");
        vm.startBroadcast(vm.envUint("OWNER2_PRIVATE_KEY"));

        gtoken.approve(address(gtokenStaking), STAKE_AMOUNT);
        gtokenStaking.stake(STAKE_AMOUNT);

        uint256 sGTokenBalance = gtokenStaking.balanceOf(operator);
        console.log("    Staked:", STAKE_AMOUNT / 1e18, "GT");
        console.log("    Got sGToken:", sGTokenBalance / 1e18, "sGT");

        // 3. 部署xPNTs token
        console.log("\n2.3 Deploying operator's xPNTs token...");
        address xpntsAddr = xpntsFactory.deployxPNTsToken(
            "Test Community Points",
            "xTEST",
            "TestCommunity",
            "test.eth"
        );
        console.log("    xPNTs token deployed:", xpntsAddr);

        // 4. 注册到SuperPaymaster
        console.log("\n2.4 Registering to SuperPaymaster...");
        address[] memory supportedSBTs = new address[](1);
        supportedSBTs[0] = address(mysbt);

        superPaymaster.registerOperator(
            LOCK_AMOUNT,
            supportedSBTs,
            xpntsAddr,
            operatorTreasury
        );
        console.log("    Locked sGToken:", LOCK_AMOUNT / 1e18, "sGT");
        console.log("    Registered successfully!");

        // 5. 验证注册
        console.log("\n2.5 Verifying registration...");
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator);
        console.log("    Is registered:", account.stakedAt > 0);
        console.log("    Treasury:", account.treasury);
        console.log("    xPNTs token:", account.xPNTsToken);
        console.log("    Exchange rate:", account.exchangeRate / 1e18);

        require(account.treasury == operatorTreasury, "Treasury mismatch");
        require(account.xPNTsToken == xpntsAddr, "xPNTs token mismatch");

        console.log("\n[SUCCESS] Step 2 completed!");
        console.log("\nEnvironment variables to save:");
        console.log("OPERATOR_XPNTS_TOKEN_ADDRESS=", xpntsAddr);

        vm.stopBroadcast();
    }
}
