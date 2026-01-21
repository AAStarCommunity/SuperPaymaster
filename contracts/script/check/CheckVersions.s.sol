// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// 通用 version() 接口
interface IVersioned {
    function version() external view returns (string memory);
}

/**
 * @title CheckVersions
 * @notice 读取配置文件并查询所有合约的 version() 接口
 * @dev 使用方法:
 *      forge script contracts/script/check/CheckVersions.s.sol --rpc-url $SEPOLIA_RPC_URL -vvv
 *      forge script contracts/script/check/CheckVersions.s.sol --rpc-url $OP_SEPOLIA_RPC_URL -vvv
 */
contract CheckVersions is Script {
    
    function run() external view {
        // 获取当前网络名称
        string memory network;
        if (block.chainid == 11155111) {
            network = "sepolia";
        } else if (block.chainid == 11155420) {
            network = "op-sepolia";
        } else if (block.chainid == 1) {
            network = "mainnet";
        } else {
            network = vm.toString(block.chainid);
        }
        
        // 构建配置文件路径
        string memory configPath = string.concat(
            vm.projectRoot(),
            "/deployments/config.",
            network,
            ".json"
        );
        
        console.log("===========================================");
        console.log("Contract Versions Check");
        console.log("===========================================");
        console.log("Network     :", network);
        console.log("Chain ID    :", block.chainid);
        console.log("Config File :", configPath);
        console.log("===========================================\n");
        
        // 读取配置文件
        string memory json = vm.readFile(configPath);
        
        // 定义需要检查的合约列表（按字母顺序）
        string[13] memory contractKeys = [
            "aPNTs",
            "blsAggregator",
            "blsValidator",
            "dvtValidator",
            "gToken",
            "paymasterFactory",
            "paymasterV4Impl",
            "registry",
            "reputationSystem",
            "sbt",
            "staking",
            "superPaymaster",
            "xPNTsFactory"
        ];
        
        // 遍历并检查每个合约
        for (uint i = 0; i < contractKeys.length; i++) {
            string memory key = contractKeys[i];
            address contractAddr = vm.parseJsonAddress(json, string.concat(".", key));
            
            if (contractAddr == address(0)) {
                console.log("[SKIP] %s: not deployed", key);
                continue;
            }
            
            // 尝试调用 version()
            try IVersioned(contractAddr).version() returns (string memory ver) {
                console.log("[OK]   %-20s %s -> %s", key, contractAddr, ver);
            } catch {
                console.log("[N/A]  %-20s %s -> No version() interface", key, contractAddr);
            }
        }
        
        console.log("\n===========================================");
        console.log("Check Complete");
        console.log("===========================================");
    }
}
