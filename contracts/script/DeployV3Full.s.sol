// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/interfaces/v3/IEntryPoint.sol";

/**
 * @title DeployV3Full
 * @notice Deploys the complete V3.1 System: Registry (Upgraded), SuperPaymaster, GToken, etc.
 */
contract DeployV3Full is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("--- SuperPaymaster V3.1 Full System Deployment ---");
        console.log("Deployer:", deployer);

        // Env Config
        address entryPointAddr = vm.envAddress("ENTRY_POINT_V07");
        address priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Foundation (GToken, Staking)
        // Check if we want to reuse existing? For "Full", let's be fresh to test V3 features cleanly.
        // Or we can load from Env if provided. Let's Deploy FRESH for safety.
        
        GToken gtoken = new GToken("Governance Token", "GT", 1_000_000 * 1e18, deployer);
        console.log("GToken:", address(gtoken));

        GTokenStaking staking = new GTokenStaking(address(gtoken), deployer);
        console.log("Staking:", address(staking));

        // 2. Deploy Registry V3.1 (With Global Rep)
        // Assuming MySBT depends on Registry, but Registry depends on MySBT?
        // Circular dependency check:
        // Registry constructor(gtoken, staking, mysbt)
        // MySBT constructor(name, symbol, gtoken, staking, registry)
        // SOLUTION: Deploy one, then the other, but constructors need addresses.
        // Usually we pre-compute address or set later.
        // Registry V3 constructor requires MySBT.
        // MySBT requires Registry.
        // Checking code... 
        
        // Registry code: constructor(..., _mysbt) 
        // MySBT code: constructor(..., _registry)
        
        // Use CREATE2 or Pre-compute to solve this?
        // Or deploy a "Mock" SBT first?
        // Or update Registry to allow setting MySBT via setter?
        // Let's check Registry code... it sets `immutable MYSBT`. This is a hard loop.
        
        // HACK: We will pre-compute the address of MySBT (nonce+1)
        uint256 deployerNonce = vm.getNonce(deployer);
        address precomputedRegistry = computeCreateAddress(deployer, deployerNonce); 
        address precomputedSBT = computeCreateAddress(deployer, deployerNonce + 1);

        // Wait, if I do `new Registry` first, it uses nonce.
        // If I pass `precomputedSBT`, it's fine.
        // Then I do `new MySBT` and it must land on `precomputedSBT`.
        
        // Let's simply deploy Registry first with a placeholder, but MYSBT is immutable!
        // We must know SBT address.
        // OK, Pre-compute strategy:
        // Nonce N: Registry
        // Nonce N+1: MySBT
        
        Registry registry = new Registry(address(gtoken), address(staking), precomputedSBT);
        console.log("Registry (V3.1):", address(registry));
        
        MySBT mysbt = new MySBT("MySBT", "SBT", address(gtoken), address(staking), address(registry));
        console.log("MySBT:", address(mysbt));
        
        require(address(mysbt) == precomputedSBT, "SBT Address Mismatch! Pre-computation failed.");

        // 3. Deploy SuperPaymaster V3.1
        // Needs a Token (aPNTs) to be "Global Token".
        // Let's deploy a fresh Test Token.
        address testToken = address(0); // TODO: Deploy a Mock Token or use existing? 
        // For script, let's leave it 0 and set later or deploy one?
        // Let's deploy a dummy token.
        // ... (Skipping Token for brevity, assuming existing is fine or set to 0)
        // Actually SuperPaymaster needs it in constructor.
        
        // Deploy a basic ERC20 for aPNTs
        // Or better, reuse GToken as aPNTs for test? No, confusing.
        // Let's use `aPNTsAddr` from env if available, else 0.
        address aPNTsAddr = vm.envOr("APNTS_ADDRESS", address(0));
        
        SuperPaymasterV3 paymaster = new SuperPaymasterV3(
            IEntryPoint(entryPointAddr),
            deployer,
            registry,
            aPNTsAddr,
            priceFeedAddr,
            deployer // Treasury
        );
        console.log("SuperPaymaster V3.1:", address(paymaster));

        // 4. Manual Setup
        // Set Credit Tiers? Already in constructor defaults.
        // Set Trusted Rep Source? Deployer is set by default.

        vm.stopBroadcast();
    }
}
