// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Interfaces & Core - Use standard path or local interface for simplicity
import "src/interfaces/v3/IRegistry.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

// --- Helper Library for UserOp Packing & Signing ---
library UserOpHelper {
    struct UserOp {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        bytes32 accountGasLimits;
        uint256 preVerificationGas;
        bytes32 gasFees;
        bytes paymasterAndData;
        bytes signature;
    }

    function pack(UserOp memory op) internal pure returns (bytes memory) {
        return abi.encode(
            op.sender,
            op.nonce,
            keccak256(op.initCode),
            keccak256(op.callData),
            op.accountGasLimits,
            op.preVerificationGas,
            op.gasFees,
            keccak256(op.paymasterAndData)
        );
    }

    function getUserOpHash(UserOp memory op, address entryPoint, uint256 chainId) internal pure returns (bytes32) {
        bytes32 userOpHash = keccak256(pack(op));
        return keccak256(abi.encode(userOpHash, entryPoint, chainId));
    }

    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function sign(UserOp memory op, uint256 privateKey, address entryPoint, uint256 chainId) internal pure returns (UserOp memory) {
        bytes32 hash = getUserOpHash(op, entryPoint, chainId);
        // SimpleAccount typically validates against UserOpHash directly or EthSignedMessage(UserOpHash)
        // Alchemy's SimpleAccount implementation uses:
        // ECDSA.recover(hash.toEthSignedMessageHash(), signature)
        bytes32 digest = toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }
}

interface IEntryPoint {
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);
    function handleOps(UserOpHelper.UserOp[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(UserOpHelper.UserOp calldata userOp) external view returns (bytes32);
}

contract L4GaslessTest is Script {
    using UserOpHelper for UserOpHelper.UserOp;

    struct Config {
        address entryPoint;
        address superPaymaster;
        address registry;
        address gToken;
        address aPNTs;
        address xPNTsFactory;
        address oracle;
    }

    Config public config;
    IEntryPoint public entryPoint;
    SuperPaymaster public sp;
    IRegistry public reg;
    GToken public gToken;
    xPNTsToken public aPNTs;
    
    address public DEPLOYER;
    address public ANNI;
    address public USER;
    uint256 public userKey;
    
    address public paymasterV4; // Baseline PM

    function setUp() public {
        string memory json = vm.readFile("config.op-mainnet.json");
        config.entryPoint = vm.parseJsonAddress(json, ".contracts.entryPoint");
        config.superPaymaster = vm.parseJsonAddress(json, ".contracts.superPaymaster");
        config.registry = vm.parseJsonAddress(json, ".contracts.registry");
        config.gToken = vm.parseJsonAddress(json, ".contracts.gToken");
        config.aPNTs = vm.parseJsonAddress(json, ".contracts.aPNTs");
        config.xPNTsFactory = vm.parseJsonAddress(json, ".contracts.xPNTsFactory");
        config.oracle = vm.parseJsonAddress(json, ".contracts.oracle");

        entryPoint = IEntryPoint(config.entryPoint);
        sp = SuperPaymaster(payable(config.superPaymaster));
        reg = IRegistry(config.registry);
        gToken = GToken(config.gToken);
        aPNTs = xPNTsToken(config.aPNTs);

        DEPLOYER = vm.addr(vm.envUint("PRIVATE_KEY_JASON"));
        ANNI = vm.addr(vm.envUint("PRIVATE_KEY_ANNI"));
        userKey = vm.envUint("TEST_PRIVATE_KEY"); // Reuse Test Key for AA Owner
        address owner = vm.addr(userKey);
        
        console.log(unicode"-----------------------------------------");
        console.log(unicode"🧪 L4 Gasless Test Suite (OP Mainnet)");
        console.log(unicode"-----------------------------------------");
    }

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_JASON");
        vm.startBroadcast(deployerKey);

        // 1. Resolve AA Account (SimpleAccount)
        address accountFactory = 0xc6e7DF5E7b4f2A278906862b61205850344D4e7d; 
        try SimpleAccountFactory(accountFactory).getAddress(vm.addr(userKey), 0) returns (address addr) {
            USER = addr;
            console.log(unicode"✅ AA Account:", USER);
        } catch {
            console.log(unicode"❌ Failed to resolve AA. Ensure it is deployed.");
            return;
        }

        // 2. Setup / Checks
        _checkFunding();
        
        // 3. Run Scenarios
        // _runScenarioT1_PaymasterV4(); // Skip for now if V4 addr unknown
        _runScenarioT2_SuperPaymaster();
        _runScenarioT3_SBTMint();
        _runScenarioT5_CreditSettlement();

        vm.stopBroadcast();
    }

    function _checkFunding() internal {
        // Ensure Anni has credit in SP
        (uint128 credit,,,,,,,,,) = sp.operators(ANNI);
        console.log(unicode"   📊 Anni SP Credit:", credit / 1e18, "aPNTs");
        if (credit < 100 ether) {
            console.log(unicode"   ⚠️ Anni credit too low! Funding...");
            if (aPNTs.balanceOf(ANNI) >= 100 ether) {
               // Logic to fund if we were Anni... but we are Jason. 
               // Jason can fund Anni then Anni deposits? Or Jason deposits for Anni?
               // SP.depositFor(ANNI, amount)? No such function usually.
               console.log(unicode"   ❌ Manual funding required for Anni (Deposit to SP).");
            }
        }
    }

    function _runScenarioT2_SuperPaymaster() internal {
        console.log(unicode"\n🔹 [T2] Gasless Transfer via SuperPaymaster");
        
        // 1. Get Anni's Token (xPNTs)
        (address tokenAddr,,,,,,,,,) = sp.operators(ANNI);
        xPNTsToken token = xPNTsToken(tokenAddr);
        console.log(unicode"   Token:", address(token));
        
        // 2. Mint xPNTs to User if needed (Jason can mint if Owner/Factory)
        if (token.balanceOf(USER) < 1 ether) {
            console.log(unicode"   ⚠️ Minting 10 xPNTs to User...");
            
            // Switch to Anni context to mint? No, wait, if Jason is Deployer...
            // Let's assume current broadcast (Jason) has permission or Anni key is needed.
            // We use try/catch to attempt mint.
            // If mint fails, maybe try Anni key.
            try token.mint(USER, 10 ether) {
                console.log(unicode"   ✅ Minted.");
            } catch {
                 console.log(unicode"   ❌ Mint failed (Auth?). Try manual funding.");
            }
        }

        // 3. Build UserOp
        UserOpHelper.UserOp memory op;
        op.sender = USER;
        op.nonce = entryPoint.getNonce(USER, 0);
        op.initCode = ""; 
        op.callData = abi.encodeWithSelector(xPNTsToken.transfer.selector, DEPLOYER, 0.1 ether);
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(200000), uint128(100000))); 
        op.preVerificationGas = 50000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        
        bytes memory pmData = abi.encodePacked(
            config.superPaymaster,
            uint128(100000), 
            uint128(50000),
            ANNI             
        );
        op.paymasterAndData = pmData;
        
        // Sign
        op = UserOpHelper.sign(op, userKey, config.entryPoint, 10);

        // Execute
        UserOpHelper.UserOp[] memory ops = new UserOpHelper.UserOp[](1);
        ops[0] = op;
        
        try entryPoint.handleOps(ops, payable(DEPLOYER)) {
            console.log(unicode"   ✅ T2 UserOp Success!");
        } catch Error(string memory reason) {
             console.log(unicode"   ❌ T2 Failed:", reason);
        } catch (bytes memory lowLevelData) {
             console.log(unicode"   ❌ T2 Failed (Low Level)");
        }
    }

    function _runScenarioT3_SBTMint() internal {
         console.log(unicode"\n🔹 [T3] Gasless SBT Mint (Storage Heavy)");
         
         // UserOp to call Registry.registerRole for EndUser
         // Role: ENDUSER
         bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
         
         // Check if already registered
         if (reg.hasRole(ROLE_ENDUSER, USER)) {
             console.log(unicode"   ✅ User already has SBT. Skipping Mint.");
             return;
         }

         bytes memory data = abi.encode(USER, ANNI, "ipfs://avatar", "user.eth", uint256(0));
         bytes memory callData = abi.encodeWithSelector(IRegistry.registerRole.selector, ROLE_ENDUSER, USER, data);
         
         UserOpHelper.UserOp memory op;
         op.sender = USER;
         op.nonce = entryPoint.getNonce(USER, 0);
         op.initCode = ""; 
         op.callData = callData;
         // Higher gas limits for storage/SBT mint
         op.accountGasLimits = bytes32(abi.encodePacked(uint128(1000000), uint128(500000))); 
         op.preVerificationGas = 100000; // Bump for storage
         op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
         
         bytes memory pmData = abi.encodePacked(
            config.superPaymaster,
            uint128(500000), // Higher PM verification
            uint128(200000), // PM PostOp
            ANNI             
        );
        op.paymasterAndData = pmData;
        
        op = UserOpHelper.sign(op, userKey, config.entryPoint, 10);

        UserOpHelper.UserOp[] memory ops = new UserOpHelper.UserOp[](1);
        ops[0] = op;
        
        try entryPoint.handleOps(ops, payable(DEPLOYER)) {
            console.log(unicode"   ✅ T3 SBT Mint Success!");
        } catch Error(string memory reason) {
             console.log(unicode"   ❌ T3 Failed:", reason);
        } catch (bytes memory lowLevelData) {
             console.log(unicode"   ❌ T3 Failed (Low Level)");
        }
    }

    function _runScenarioT5_CreditSettlement() internal {
        console.log(unicode"\n🔹 [T5] Credit Settlement (Debit Test)");
        // Logic: Empty User's xPNTs, try tx, check Debt
        // Requires User to have 0 xPNTs.
        // We can just query `debts` mapping on Token.
        // If we want to simulate debt, we need to drain user.
        // For now, just log existing debt.
        (address tokenAddr,,,,,,,,,) = sp.operators(ANNI);
        xPNTsToken token = xPNTsToken(tokenAddr);
        uint256 debt = token.debts(USER);
        console.log(unicode"   📊 User Debt:", debt);
    }
}

interface SimpleAccountFactory {
    function getAddress(address owner, uint256 salt) external view returns (address);
}
