// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/v2/core/GTokenStaking.sol";
import "../../src/v2/tokens/MySBT.sol";
import "../../contracts/test/mocks/MockERC20.sol";

interface ISimpleAccount {
    function execute(address dest, uint256 value, bytes calldata func) external;
}

/**
 * @title MintSBTForSimpleAccount
 * @notice Mint SBT for SimpleAccount via execute() calls
 */
contract MintSBTForSimpleAccount is Script {

    MockERC20 gtoken;
    GTokenStaking gtokenStaking;
    MySBT mysbt;
    ISimpleAccount simpleAccount;

    address operator;
    uint256 ownerKey;

    function setUp() public {
        // Load contracts
        gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));
        gtokenStaking = GTokenStaking(vm.envAddress("GTOKEN_STAKING_ADDRESS"));
        mysbt = MySBT(vm.envAddress("MYSBT_ADDRESS"));
        simpleAccount = ISimpleAccount(vm.envAddress("SIMPLE_ACCOUNT_B"));

        operator = vm.envAddress("OWNER2_ADDRESS");
        ownerKey = vm.envUint("OWNER_PRIVATE_KEY"); // SimpleAccount owner's key
    }

    function run() public {
        console.log("=== Mint SBT for SimpleAccount ===\n");
        console.log("SimpleAccount:", address(simpleAccount));
        console.log("Operator/Community:", operator);

        // 1. Deployer mints GToken to SimpleAccount
        console.log("\n1. Minting GToken to SimpleAccount...");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        gtoken.mint(address(simpleAccount), 1 ether);
        console.log("   Minted 1 GToken");
        vm.stopBroadcast();

        // 2. SimpleAccount approves GToken to GTokenStaking
        console.log("\n2. SimpleAccount approving GToken...");
        bytes memory approveCalldata = abi.encodeWithSelector(
            gtoken.approve.selector,
            address(gtokenStaking),
            0.3 ether
        );

        vm.startBroadcast(ownerKey);
        simpleAccount.execute(address(gtoken), 0, approveCalldata);
        console.log("   Approved 0.3 GToken to GTokenStaking");

        // 3. SimpleAccount stakes GToken
        console.log("\n3. SimpleAccount staking GToken...");
        bytes memory stakeCalldata = abi.encodeWithSelector(
            gtokenStaking.stake.selector,
            0.3 ether
        );
        simpleAccount.execute(address(gtokenStaking), 0, stakeCalldata);
        console.log("   Staked 0.3 GToken");

        // 4. SimpleAccount approves GToken to MySBT for mintFee
        console.log("\n4. SimpleAccount approving GToken for mintFee...");
        bytes memory approveMintFeeCalldata = abi.encodeWithSelector(
            gtoken.approve.selector,
            address(mysbt),
            0.1 ether
        );
        simpleAccount.execute(address(gtoken), 0, approveMintFeeCalldata);
        console.log("   Approved 0.1 GToken to MySBT");

        // 5. SimpleAccount mints SBT
        console.log("\n5. SimpleAccount minting SBT...");
        bytes memory mintSBTCalldata = abi.encodeWithSelector(
            mysbt.mintSBT.selector,
            operator
        );
        simpleAccount.execute(address(mysbt), 0, mintSBTCalldata);
        console.log("   Minted SBT for community:", operator);

        vm.stopBroadcast();

        // 6. Verify
        console.log("\n6. Verifying...");
        uint256 sbtBalance = mysbt.balanceOf(address(simpleAccount));
        uint256 tokenId = mysbt.userCommunityToken(address(simpleAccount), operator);

        console.log("   SimpleAccount SBT balance:", sbtBalance);
        console.log("   SBT tokenId:", tokenId);

        require(sbtBalance > 0, "SBT mint failed");
        require(tokenId > 0, "SBT mapping failed");

        console.log("\n[SUCCESS] SBT minted for SimpleAccount!");
    }
}
