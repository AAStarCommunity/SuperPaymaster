// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/MySBT.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title MintSBTForSimpleAccount
 * @notice Mint SBT for SimpleAccount using SimpleAccount.execute()
 *
 * Flow:
 * 1. Deployer mint GT to SimpleAccount owner
 * 2. Owner stake GT -> get stGToken
 * 3. Owner use SimpleAccount.execute() to call MySBT.mintSBT()
 */
contract MintSBTForSimpleAccount is Script {

    MockERC20 gtoken;
    GTokenStaking gtokenStaking;
    MySBT mysbt;

    address simpleAccount;
    address owner;
    uint256 ownerKey;
    address operator;

    function setUp() public {
        // Load contracts
        gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        mysbt = MySBT(vm.envAddress("MYSBT_ADDRESS"));

        // Accounts
        simpleAccount = vm.envAddress("SIMPLE_ACCOUNT_B");
        ownerKey = vm.envUint("OWNER_PRIVATE_KEY");
        owner = vm.addr(ownerKey);
        operator = vm.envAddress("OWNER2_ADDRESS");
    }

    function run() public {
        console.log("=== Mint SBT for SimpleAccount ===\n");
        console.log("SimpleAccount:", simpleAccount);
        console.log("Owner:", owner);
        console.log("Operator (community):", operator);

        // 1. Deployer mint GT to owner
        console.log("\n1. Minting GT to owner...");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        gtoken.mint(owner, 1 ether);
        console.log("   Minted 1 GT to owner");
        vm.stopBroadcast();

        // 2. Owner stake GT to get stGToken
        console.log("\n2. Owner staking GT...");
        vm.startBroadcast(ownerKey);

        gtoken.approve(address(gtokenStaking), 0.4 ether); // 0.3 for lock + 0.1 for mint fee
        gtokenStaking.stake(0.4 ether);
        console.log("   Staked 0.4 GT");

        uint256 stGTokenBalance = gtokenStaking.balanceOf(owner);
        console.log("   Got stGToken:", stGTokenBalance / 1e18, "sGT");

        // 3. Approve GT for MySBT mint fee (0.1 GT)
        gtoken.approve(address(mysbt), 0.1 ether);
        console.log("   Approved 0.1 GT for mint fee");

        // 4. Construct calldata for MySBT.mintSBT(operator)
        bytes memory mintSBTCalldata = abi.encodeWithSignature("mintSBT(address)", operator);

        // 5. Use SimpleAccount.execute() to call MySBT.mintSBT()
        console.log("\n3. SimpleAccount executing mintSBT...");
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            address(mysbt),
            0,
            mintSBTCalldata
        );

        // Call SimpleAccount.execute()
        (bool success,) = simpleAccount.call(executeCalldata);
        require(success, "SimpleAccount.execute() failed");

        console.log("   SimpleAccount executed mintSBT successfully");

        vm.stopBroadcast();

        // 4. Verify
        console.log("\n4. Verifying...");
        uint256 sbtBalance = mysbt.balanceOf(simpleAccount);
        console.log("   SimpleAccount SBT balance:", sbtBalance);

        require(sbtBalance > 0, "SimpleAccount has no SBT");

        console.log("\n[SUCCESS] SimpleAccount now has SBT!");
    }
}
