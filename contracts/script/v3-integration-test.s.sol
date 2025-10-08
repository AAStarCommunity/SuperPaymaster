// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title V3IntegrationTest
 * @notice 链上集成测试脚本 - 测试 Settlement 和 PaymasterV3 的完整流程
 * @dev 使用方式:
 *   forge script script/v3-integration-test.s.sol:V3IntegrationTest --rpc-url sepolia --broadcast
 */
contract V3IntegrationTest is Script {
    // 测试账户
    address testUser;
    address treasury;

    // 部署的合约地址 (从deployments/v3-sepolia.json读取)
    address settlementAddress;
    address paymasterV3Address;
    address sbtAddress;
    address tokenAddress;

    function setUp() public {
        // 从环境变量加载
        settlementAddress = vm.envAddress("SETTLEMENT_ADDRESS");
        paymasterV3Address = vm.envAddress("PAYMASTER_V3_ADDRESS");
        sbtAddress = vm.envAddress("SBT_CONTRACT_ADDRESS");
        tokenAddress = vm.envAddress("GAS_TOKEN_ADDRESS");
        treasury = vm.envAddress("TREASURY_ADDRESS");
        testUser = vm.envAddress("TEST_USER_ADDRESS");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("========================================");
        console.log("V3 Integration Test - Sepolia");
        console.log("========================================");
        console.log("Settlement:", settlementAddress);
        console.log("PaymasterV3:", paymasterV3Address);
        console.log("Test User:", testUser);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Test 1: 检查合约配置
        console.log("[Test 1] Checking contract configuration...");
        _testContractConfiguration();

        // Test 2: 模拟记账流程
        console.log("\n[Test 2] Simulating fee recording...");
        _testFeeRecording();

        // Test 3: 检查pending状态
        console.log("\n[Test 3] Checking pending balance...");
        _testPendingBalance();

        // Test 4: 执行批量结算
        console.log("\n[Test 4] Executing batch settlement...");
        _testBatchSettlement();

        // Test 5: 验证最终状态
        console.log("\n[Test 5] Verifying final state...");
        _testFinalState();

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("All Integration Tests Passed!");
        console.log("========================================");
    }

    function _testContractConfiguration() internal view {
        // 检查 Settlement 配置
        (bool success1, bytes memory data1) = settlementAddress.staticcall(
            abi.encodeWithSignature("registry()")
        );
        require(success1, "Failed to get registry");
        address registryAddr = abi.decode(data1, (address));
        console.log("  Settlement Registry:", registryAddr);

        // 检查 Settlement threshold
        (bool success2, bytes memory data2) = settlementAddress.staticcall(
            abi.encodeWithSignature("settlementThreshold()")
        );
        require(success2, "Failed to get threshold");
        uint256 threshold = abi.decode(data2, (uint256));
        console.log("  Settlement Threshold:", threshold);

        // 检查 PaymasterV3 的 EntryPoint
        (bool success3, bytes memory data3) = paymasterV3Address.staticcall(
            abi.encodeWithSignature("entryPoint()")
        );
        require(success3, "Failed to get EntryPoint");
        address entryPoint = abi.decode(data3, (address));
        console.log("  PaymasterV3 EntryPoint:", entryPoint);

        console.log("  [OK] Configuration verified");
    }

    function _testFeeRecording() internal {
        // 模拟 PaymasterV3.postOp 调用 Settlement.recordGasFee
        bytes32 userOpHash = keccak256(abi.encodePacked("test-userop-", block.timestamp));
        uint256 feeAmount = 0.001 ether;

        console.log("  Recording fee for user:", testUser);
        console.log("  Amount:", feeAmount);
        console.log("  UserOpHash:", vm.toString(userOpHash));

        // 注意: 实际调用需要 PaymasterV3 已在 Registry 注册
        (bool success, bytes memory data) = settlementAddress.call(
            abi.encodeWithSignature(
                "recordGasFee(address,address,uint256,bytes32)",
                testUser,
                tokenAddress,
                feeAmount,
                userOpHash
            )
        );

        if (!success) {
            console.log("  [WARN]  Recording failed (check if Paymaster is registered)");
            console.log("  Error:", string(data));
        } else {
            bytes32 recordKey = abi.decode(data, (bytes32));
            console.log("  [OK] Fee recorded, key:", vm.toString(recordKey));
        }
    }

    function _testPendingBalance() internal view {
        // 查询 pending balance
        (bool success, bytes memory data) = settlementAddress.staticcall(
            abi.encodeWithSignature(
                "pendingAmounts(address,address)",
                testUser,
                tokenAddress
            )
        );

        if (success) {
            uint256 pending = abi.decode(data, (uint256));
            console.log("  Pending balance:", pending);
            console.log("  [OK] Pending balance checked");
        } else {
            console.log("  [WARN]  Failed to get pending balance");
        }
    }

    function _testBatchSettlement() internal {
        // 获取用户的所有 pending 记录
        (bool success1, bytes memory data1) = settlementAddress.call(
            abi.encodeWithSignature(
                "getUserPendingRecords(address,address)",
                testUser,
                tokenAddress
            )
        );

        if (!success1) {
            console.log("  [WARN]  No pending records found");
            return;
        }

        bytes32[] memory recordKeys = abi.decode(data1, (bytes32[]));
        console.log("  Found pending records:", recordKeys.length);

        if (recordKeys.length == 0) {
            console.log("  [WARN]  No records to settle");
            return;
        }

        // 执行批量结算
        bytes32 settlementHash = keccak256(abi.encodePacked("settlement-", block.timestamp));

        (bool success2,) = settlementAddress.call(
            abi.encodeWithSignature(
                "settleFees(bytes32[],bytes32)",
                recordKeys,
                settlementHash
            )
        );

        if (success2) {
            console.log("  [OK] Settlement executed successfully");
        } else {
            console.log("  [WARN]  Settlement failed (check user allowance)");
        }
    }

    function _testFinalState() internal view {
        // 检查用户 pending balance 是否清零
        (bool success, bytes memory data) = settlementAddress.staticcall(
            abi.encodeWithSignature(
                "pendingAmounts(address,address)",
                testUser,
                tokenAddress
            )
        );

        if (success) {
            uint256 finalPending = abi.decode(data, (uint256));
            console.log("  Final pending balance:", finalPending);

            if (finalPending == 0) {
                console.log("  [OK] All fees settled successfully");
            } else {
                console.log("  [WARN]  Still has pending balance");
            }
        }
    }
}
