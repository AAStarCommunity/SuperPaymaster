// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title V3DeploySimple
 * @notice 简化的部署脚本 - 避免OZ版本冲突,使用低级调用部署
 * @dev 使用方式:
 *   forge script script/v3-deploy-simple.s.sol:V3DeploySimple --rpc-url sepolia --broadcast
 */
contract V3DeploySimple is Script {
    // Sepolia 地址
    address constant ENTRYPOINT_V7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address sbt = vm.envAddress("SBT_CONTRACT_ADDRESS");
        address gasToken = vm.envAddress("GAS_TOKEN_ADDRESS");
        uint256 minBalance = vm.envUint("MIN_TOKEN_BALANCE");
        uint256 settlementThreshold = vm.envUint("SETTLEMENT_THRESHOLD");
        address registry = vm.envAddress("SUPER_PAYMASTER"); // 从环境变量读取 Registry 地址

        console.log("========================================");
        console.log("V3 Simple Deployment - Sepolia");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Registry:", registry);
        console.log("SBT:", sbt);
        console.log("Gas Token:", gasToken);
        console.log("Min Balance:", minBalance);
        console.log("Settlement Threshold:", settlementThreshold);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // 步骤1: 部署 Settlement
        console.log("[1/2] Deploying Settlement...");
        address settlement = _deploySettlement(deployer, registry, settlementThreshold);
        console.log("  Settlement deployed:", settlement);

        // 步骤2: 部署 PaymasterV3
        console.log("\n[2/2] Deploying PaymasterV3...");
        address paymaster = _deployPaymasterV3(
            ENTRYPOINT_V7,
            deployer,
            sbt,
            gasToken,
            settlement,
            minBalance
        );
        console.log("  PaymasterV3 deployed:", paymaster);

        vm.stopBroadcast();

        // 保存部署信息
        console.log("\n========================================");
        console.log("Deployment Complete!");
        console.log("========================================");
        console.log("\nContract Addresses:");
        console.log("  Settlement:", settlement);
        console.log("  PaymasterV3:", paymaster);

        console.log("\nNext Steps:");
        console.log("1. Export addresses:");
        console.log("   export SETTLEMENT_ADDRESS=", settlement);
        console.log("   export PAYMASTER_V3_ADDRESS=", paymaster);
        console.log("\n2. Register in Registry:");
        console.log("   cast send", registry, "\\");
        console.log("     'registerPaymaster(address,string,uint256)'", paymaster, "'SuperPaymaster' 150 \\");
        console.log("     --rpc-url sepolia --private-key $PRIVATE_KEY");
        console.log("\n3. Deposit ETH:");
        console.log("   cast send", paymaster, "\\");
        console.log("     --value 0.1ether \\");
        console.log("     --rpc-url sepolia --private-key $PRIVATE_KEY");
        console.log("========================================\n");

        // 写入文件
        string memory info = string(abi.encodePacked(
            '{\n',
            '  "settlement": "', vm.toString(settlement), '",\n',
            '  "paymasterV3": "', vm.toString(paymaster), '"\n',
            '}'
        ));
        vm.writeFile("deployments/v3-sepolia-latest.json", info);
    }

    function _deploySettlement(address owner, address registry, uint256 threshold) internal returns (address) {
        // Settlement constructor: (address initialOwner, address registryAddress, uint256 initialThreshold)
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("src/v3/Settlement.sol:Settlement"),
            abi.encode(owner, registry, threshold)
        );

        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "Settlement deployment failed");
        return addr;
    }

    function _deployPaymasterV3(
        address entryPoint,
        address owner,
        address sbtContract,
        address gasToken,
        address settlement,
        uint256 minBalance
    ) internal returns (address) {
        // PaymasterV3 bytecode (需要预先编译)
        bytes memory bytecode = abi.encodePacked(
            vm.getCode("src/v3/PaymasterV3.sol:PaymasterV3"),
            abi.encode(entryPoint, owner, sbtContract, gasToken, settlement, minBalance)
        );

        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "PaymasterV3 deployment failed");
        return addr;
    }
}
