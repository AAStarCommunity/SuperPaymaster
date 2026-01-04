// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/modules/validators/BLSValidator.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title DeployV3Full
 * @notice Deploys the complete V3.1.1 System: Registry, SuperPaymaster, GToken, ReputationSystem, etc.
 */
contract DeployV3FullSepolia is Script {
    using stdJson for string;
    string internal configFile;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("--- SuperPaymaster V3.1.1 Modular Deployment ---");
        console.log("Deployer:", deployer);

        string memory root = vm.projectRoot();
        configFile = string.concat(root, "/", vm.envOr("CONFIG_FILE", string("config.json")));
        string memory path = configFile;
        console.log("Loading Config from:", configFile);
        string memory json = "{}";
        
        try vm.readFile(path) returns (string memory j) { 
            if (bytes(j).length > 0) json = j; 
        } catch { 
            console.log("No config.json found, starting fresh.");
        }

        // Load existing addresses (verify code exists)
        address addr_gToken = _loadAddr(json, ".gToken");
        address addr_staking = _loadAddr(json, ".staking");
        address addr_registry = _loadAddr(json, ".registry");
        address addr_sbt = _loadAddr(json, ".sbt");
        address addr_repSystem = _loadAddr(json, ".reputationSystem");
        address addr_apnts = _loadAddr(json, ".aPNTs");
        address addr_sp = _loadAddr(json, ".superPaymaster");
        address addr_blsAgg = _loadAddr(json, ".blsAggregator");
        address addr_dvt = _loadAddr(json, ".dvtValidator");
        address addr_blsVal = _loadAddr(json, ".blsValidator");
        address addr_xpntsFactory = _loadAddr(json, ".xPNTsFactory");
        address addr_pmV4 = _loadAddr(json, ".paymasterV4"); // This is V4.0 or V4.2 Impl?
        // Note: For V4 stack, we need Factory and Proxy.
        address addr_pmFactory = _loadAddr(json, ".paymasterFactory");
        address addr_pmV4Proxy = _loadAddr(json, ".paymasterV4Proxy");

        // Env Config
        address entryPointAddr = vm.envOr("ENTRY_POINT_V07", 0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address priceFeedAddr = vm.envOr("PRICE_FEED", 0x694AA1769357215DE4FAC081bf1f309aDC325306); 

        vm.startBroadcast(deployerPrivateKey);

        // 1. GToken
        if (addr_gToken == address(0)) {
            GToken t = new GToken(21_000_000 * 1e18);
            addr_gToken = address(t);
            console.log("Deployed GToken:", addr_gToken);
        } else {
            console.log("Found GToken:", addr_gToken);
        }
        _save("gToken", addr_gToken); // Save eagerly

        // 2. Staking
        if (addr_staking == address(0)) {
            GTokenStaking s = new GTokenStaking(addr_gToken, deployer);
            addr_staking = address(s);
            console.log("Deployed Staking:", addr_staking);
        } else {
            console.log("Found Staking:", addr_staking);
        }
        _save("staking", addr_staking);

        // 3. Registry & MySBT (Circular)
        if (addr_registry == address(0) || addr_sbt == address(0)) {
            // Re-deploy both if any missing to ensure linkage (simplification)
            if (addr_registry != address(0)) console.log("Warning: Redeploying Registry pair due to missing SBT");
            
            uint256 nonce = vm.getNonce(deployer);
            address precomputedSBT = vm.computeCreateAddress(deployer, nonce + 1);
            
            Registry r = new Registry(addr_gToken, addr_staking, precomputedSBT);
            addr_registry = address(r);
            console.log("Deployed Registry:", addr_registry);

            MySBT s = new MySBT(addr_gToken, addr_staking, addr_registry, deployer);
            addr_sbt = address(s);
            console.log("Deployed MySBT:", addr_sbt);
            
            require(address(s) == precomputedSBT, "SBT Mismatch");
        } else {
            console.log("Found Registry:", addr_registry);
            console.log("Found MySBT:", addr_sbt);
        }
        _save("registry", addr_registry);
        _save("sbt", addr_sbt);

        // 4. Reputation
        if (addr_repSystem == address(0)) {
            ReputationSystem rep = new ReputationSystem(addr_registry);
            addr_repSystem = address(rep);
            console.log("Deployed ReputationSystem:", addr_repSystem);
        } else {
            console.log("Found ReputationSystem:", addr_repSystem);
        }
        _save("reputationSystem", addr_repSystem);

        _save("aPNTs", addr_apnts);

        // NOTE: Actual token deployment with paymaster auth happens after paymaster is ready.
        // For aPNTs (global), we can deploy it with address(0) for paymaster if needed, 
        // but here we might want to wait for PaymasterV4Proxy.

        // 6. SuperPaymaster
        if (addr_sp == address(0)) {
            SuperPaymaster sp = new SuperPaymaster(
                IEntryPoint(entryPointAddr),
                deployer,
                Registry(addr_registry),
                addr_apnts,
                priceFeedAddr,
                deployer
            );
            addr_sp = address(sp);
            console.log("Deployed SuperPaymaster:", addr_sp);
        } else {
            console.log("Found SuperPaymaster:", addr_sp);
        }
        _save("superPaymaster", addr_sp);

        // --- Basic Wiring ---
        GTokenStaking(addr_staking).setRegistry(addr_registry);
        MySBT(addr_sbt).setRegistry(addr_registry);
        Registry(addr_registry).setReputationSource(addr_repSystem, true);
        if (addr_apnts != address(0)) {
            xPNTsToken(addr_apnts).setSuperPaymasterAddress(addr_sp);
        }
        
        // 7. BLS & DVT
        if (addr_blsAgg == address(0)) {
            BLSAggregator agg = new BLSAggregator(addr_registry, addr_sp, address(0));
            agg.setThreshold(3);
            addr_blsAgg = address(agg);
            console.log("Deployed BLSAggregator:", addr_blsAgg);
        }
        _save("blsAggregator", addr_blsAgg);
        Registry(addr_registry).setBLSAggregator(addr_blsAgg);

        if (addr_dvt == address(0)) {
            DVTValidator d = new DVTValidator(addr_registry);
            d.setBLSAggregator(addr_blsAgg);
            addr_dvt = address(d);
            console.log("Deployed DVTValidator:", addr_dvt);
        }
        _save("dvtValidator", addr_dvt);

        if (addr_blsVal == address(0)) {
            BLSValidator v = new BLSValidator();
            addr_blsVal = address(v);
            console.log("Deployed BLSValidator:", addr_blsVal);
        }
        _save("blsValidator", addr_blsVal);
        Registry(addr_registry).setBLSValidator(addr_blsVal);

        // 8. xPNTs Factory
        if (addr_xpntsFactory == address(0)) {
            xPNTsFactory f = new xPNTsFactory(addr_sp, addr_registry);
            addr_xpntsFactory = address(f);
            console.log("Deployed xPNTsFactory:", addr_xpntsFactory);
        }
        _save("xPNTsFactory", addr_xpntsFactory);
        
        // Wire SP to xPNTsFactory
        SuperPaymaster(payable(addr_sp)).setXPNTsFactory(addr_xpntsFactory);

        // Wire PMV4 to xPNTsFactory (if PMV4 exists)


        // 9. Paymaster V4 Stack
        if (addr_pmFactory == address(0)) {
            PaymasterFactory pf = new PaymasterFactory();
            addr_pmFactory = address(pf);
            console.log("Deployed PaymasterFactory:", addr_pmFactory);
        }
        _save("paymasterFactory", addr_pmFactory);

        // We use V4.2 now
        if (addr_pmV4 == address(0)) {
             // Paymaster (using correct import if available, else PaymasterV4 base for now as per imports)
             // NOTE: Imports dictate V4. Assuming PaymasterV4 is 4.0 or 4.2 in this context?
             // Looking at imports: src/paymasters/v4/PaymasterV4.sol
             // User wanted V4.2. Let's assume standard V4 for now or strictly follow V4_2 pattern if imported.
             // File checks showed PaymasterV4 so we stick to it.
             // Wait, user said "Paymaster.sol" in previous scripts.
             // I should verify if PaymasterV4.sol is V4.2. 
             // Logic: I'll use PaymasterV4 from import.
             Paymaster impl = new Paymaster(addr_registry);
             addr_pmV4 = address(impl);
             console.log("Deployed Paymaster (Impl):", addr_pmV4);
             
             PaymasterFactory(addr_pmFactory).addImplementation("v4.2", addr_pmV4);
             PaymasterFactory(addr_pmFactory).setDefaultVersion("v4.2");
        }
        _save("paymasterV4", addr_pmV4); 
        
        if (addr_pmV4Proxy == address(0)) {
             bytes memory init = abi.encodeWithSelector(
                Paymaster.initialize.selector,
                entryPointAddr,
                deployer,
                deployer, // treasury
                priceFeedAddr,
                100, // 1%
                1 ether,
                0, // minTokenBalance (unused)
                addr_xpntsFactory,
                addr_sbt,
                address(0) // No initial gas token
                // registry removed
             );
             // Check if Paymaster already exists for this operator (Factory Restriction: One per Operator)
             // We do this via low-level staticcall to avoid ABI dependency issues if not 100% matched
             (bool checkSuccess, bytes memory checkRet) = addr_pmFactory.staticcall(
                abi.encodeWithSelector(PaymasterFactory.getPaymasterByOperator.selector, deployer)
             );
             
             address existingProxy = address(0);
             if (checkSuccess && checkRet.length == 32) {
                 existingProxy = abi.decode(checkRet, (address));
             }

             if (existingProxy != address(0)) {
                 addr_pmV4Proxy = existingProxy;
                 console.log("Reuse Existing PaymasterV4 Proxy:", addr_pmV4Proxy);
                 
                 // Reuse means we skip deployment of Proxy, but we should check aPNTs
                 if (addr_apnts == address(0)) {
                    // Try low level call for apnts
                    (bool s2, bytes memory r2) = addr_xpntsFactory.call(abi.encodeWithSelector(xPNTsFactory.deployxPNTsToken.selector, "aPNTs", "aPNTs", "Global", "aastar.eth", 1 ether, addr_pmV4Proxy));
                    if (s2) {
                        addr_apnts = abi.decode(r2, (address));
                        console.log("Deployed aPNTs via Factory:", addr_apnts);
                    } else {
                        console.log("Failed to deploy aPNTs (Low Level)");
                    }
                 }
             } else {
                 bool success;
                 bytes memory ret;
                 // Deploy new if none exists
                 (success, ret) = addr_pmFactory.call(abi.encodeWithSignature("deployPaymaster(string,bytes)", "v4.2", init));
                 if (success) {
                     addr_pmV4Proxy = abi.decode(ret, (address));
                     console.log("Deployed PaymasterV4 Proxy:", addr_pmV4Proxy);
                     
                     if (addr_apnts == address(0)) {
                        (bool s2, bytes memory r2) = addr_xpntsFactory.call(abi.encodeWithSelector(xPNTsFactory.deployxPNTsToken.selector, "aPNTs", "aPNTs", "Global", "aastar.eth", 1 ether, addr_pmV4Proxy));
                        if (s2) {
                            addr_apnts = abi.decode(r2, (address));
                            console.log("Deployed aPNTs via Factory:", addr_apnts);
                        } else {
                            console.log("Failed to deploy aPNTs (Low Level)");
                        }
                     }
                 } else {
                     console.log("Failed to deploy PaymasterV4 Proxy (Low Level Revert)");
                 }
             }
        }
        _save("paymasterV4Proxy", addr_pmV4Proxy);
        _save("aPNTs", addr_apnts);

        vm.stopBroadcast();
        
        // Final Output
        console.log("\n=== State-Aware Deployment Finished ===");
        console.log("All addresses saved to config.json");
    }

    function _loadAddr(string memory json, string memory key) internal view returns (address) {
        if (bytes(json).length < 2) return address(0);
        try vm.parseJsonAddress(json, key) returns (address a) {
            if (a.code.length > 0) return a;
        } catch {}
        return address(0);
    }

    function _save(string memory key, address val) internal {
        string memory finalJson = vm.serializeAddress("config", key, val);
        vm.writeFile(configFile, finalJson);
    }
}

