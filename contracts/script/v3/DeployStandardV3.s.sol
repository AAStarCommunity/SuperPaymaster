// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core Imports
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";

// Paymaster Imports
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/paymasters/v4/PaymasterV4.sol";
import "src/paymasters/v4/PaymasterV4_2.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

// Module Imports
import "src/modules/reputation/ReputationSystemV3.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/modules/validators/BLSValidator.sol";

// External Interfaces
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title DeployStandardV3
 * @notice 标准化 V3/V4 部署脚本
 * @dev 继承自原有 FullLocal/FullSepolia 逻辑，采用五步规范化重构
 */
contract DeployStandardV3 is Script {
    // -----------------------------------------------------------------------
    // 环境配置
    // -----------------------------------------------------------------------
    uint256 deployerPK;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;
    string configPath;

    // -----------------------------------------------------------------------
    // 合约实例
    // -----------------------------------------------------------------------
    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymasterV3 superPaymaster;
    ReputationSystemV3 repSystem;
    BLSAggregatorV3 aggregator;
    DVTValidatorV3 dvt;
    BLSValidator blsValidator;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    PaymasterV4_2 pmV4Impl;

    function setUp() public {
        // Default to Anvil if no chain ID specific env is set
        if (block.chainid == 31337) { 
            deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
            entryPointAddr = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789; 
        } else {
            // Safely read PRIVATE_KEY, only revert if it's actually needed in run()
            deployerPK = vm.envOr("PRIVATE_KEY", uint256(0));
            priceFeedAddr = vm.envOr("ETH_USD_FEED", address(0));
            entryPointAddr = vm.envOr("ENTRY_POINT", address(0));
        }
        
        if (deployerPK != 0) {
            deployer = vm.addr(deployerPK);
        }

        string memory root = vm.projectRoot();
        string memory configFileName = vm.envOr("CONFIG_FILE", string("config.json"));
        configPath = string.concat(root, "/", configFileName);
    }

    function run() external {
        vm.warp(block.timestamp + 1 days); // 预防价格检查下溢
        vm.startBroadcast(deployerPK);

        console.log("=== Step 1: Deploy Foundation (Asset Layer) ===");
        _deployFoundation();

        console.log("=== Step 2: Deploy Core (Logic Layer) ===");
        _deployCore();

        console.log("=== Step 3: Deploy Modules (Feature Layer) ===");
        _deployModules();

        console.log("=== Step 4: The Grand Wiring (Interconnection) ===");
        _executeWiring();

        console.log("=== Step 5: Role Orchestration (Bootstrapping) ===");
        _orchestrateRoles();

        vm.stopBroadcast();

        _generateConfig();
        console.log("Deployment Complete. Config saved to:", configPath);
    }

    // 1. 基础资产层
    function _deployFoundation() internal {
        gtoken = new GToken(21_000_000 * 1e18);
        staking = new GTokenStaking(address(gtoken), deployer);
        
        // 预计算 Registry 地址，因为 MySBT 构造函数可能需要（或使用 setter）
        uint256 nonce = vm.getNonce(deployer);
        address precomputedRegistry = vm.computeCreateAddress(deployer, nonce + 1);
        
        mysbt = new MySBT(address(gtoken), address(staking), precomputedRegistry, deployer);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));
    }

    // 2. 核心逻辑层
    function _deployCore() internal {
        // 部署 aPNTs (作为全局账本)
        apnts = new xPNTsToken("AAStar PNTs", "aPNTs", deployer, "GlobalHub", "local.eth", 1e18);
        
        // 部署 SuperPaymaster (Registry 为 immutable)
        superPaymaster = new SuperPaymasterV3(
            IEntryPoint(entryPointAddr),
            deployer,
            registry,
            address(apnts),
            priceFeedAddr,
            deployer
        );
    }

    // 3. 功能模块层
    function _deployModules() internal {
        repSystem = new ReputationSystemV3(address(registry));
        
        aggregator = new BLSAggregatorV3(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidatorV3(address(registry));
        blsValidator = new BLSValidator();
        
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));
        pmFactory = new PaymasterFactory();
        
        // 部署 V4.2 实现合约 (Registry 为 immutable)
        pmV4Impl = new PaymasterV4_2(address(registry));
    }

    // 4. 全局互联 (Setters)
    function _executeWiring() internal {
        // 核心网关设置
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        
        // 信用与风控设置
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        registry.setBLSValidator(address(blsValidator));
        
        // DVT & Aggregator 互联
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        
        // 代币防火墙与回调设置
        apnts.setSuperPaymasterAddress(address(superPaymaster));
        mysbt.setSuperPaymaster(address(superPaymaster));
        
        // 工厂模板设置
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        
        // 初始化 SuperPaymaster 价格缓存
        superPaymaster.updatePrice();
    }

    // 5. 角色初始化
    function _orchestrateRoles() internal {
        // 注册部署者为第一个 Operator
        gtoken.mint(deployer, 1000 ether);
        gtoken.approve(address(staking), 1000 ether);
        
        bytes memory opData = abi.encode(
            Registry.CommunityRoleData("Genesis Operator", "genesis.eth", "http://aastar.io", "Genesis Hub", "", 30 ether)
        );
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, opData);
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), deployer, "");
        
        // 给 Paymaster 存入初始 ETH 押金
        IEntryPoint(entryPointAddr).depositTo{value: 0.5 ether}(address(superPaymaster));
        
        // 给 Operator 分配初始 aPNTs 额度
        apnts.mint(deployer, 1000 ether);
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.depositFor(deployer, 1000 ether);
    }

    function _getChainName(uint256 id) internal pure returns (string memory) {
        if (id == 31337) return "anvil";
        if (id == 11155111) return "sepolia";
        if (id == 1) return "mainnet";
        if (id == 10) return "optimism";
        if (id == 8453) return "base";
        return vm.toString(id);
    }

    // 生成 config.json
    function _generateConfig() internal {
        string memory chainName = _getChainName(block.chainid);
        string memory dirPath = string.concat(vm.projectRoot(), "/deployments/");
        string memory finalPath = string.concat(dirPath, chainName, ".json");

        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(superPaymaster));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(pmFactory)); 
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "blsValidator", address(blsValidator));
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);

        vm.writeFile(finalPath, finalJson);
        
        // Also log ENV style for easy copy-paste
        console.log("\n--- Deployment Summary (%s) ---", chainName);
        console.log("REGISTRY_ADDR=%s", address(registry));
        console.log("SUPER_PAYMASTER_ADDR=%s", address(superPaymaster));
        console.log("APNTS_ADDR=%s", address(apnts));
        console.log("STAKING_ADDR=%s", address(staking));
        console.log("PAYMASTER_V4_IMPL=%s", address(pmV4Impl));
        console.log("Config saved to: %s", finalPath);
        console.log("------------------------------\n");
    }
}
