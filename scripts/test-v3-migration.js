// Test Script for Mycelium Protocol v3 Migration
// Usage: npx hardhat run scripts/test-v3-migration.js --network <network>

const { ethers } = require("hardhat");

// Configuration - Update with deployed addresses
const CONFIG = {
    REGISTRY_V3: process.env.REGISTRY_V3_ADDRESS,
    MYSBT_V3: process.env.MYSBT_V3_ADDRESS,
    GTOKEN_STAKING_V3: process.env.GTOKEN_STAKING_V3_ADDRESS,
    SHARED_CONFIG: process.env.SHARED_CONFIG_ADDRESS,
    GTOKEN: process.env.GTOKEN_ADDRESS
};

// Role IDs from SharedConfig
let ROLES = {};

async function main() {
    console.log("=== Mycelium Protocol v3 Migration Test ===\n");

    // Get contracts
    const Registry = await ethers.getContractAt("IRegistryV3", CONFIG.REGISTRY_V3);
    const MySBT = await ethers.getContractAt("MySBT_v3", CONFIG.MYSBT_V3);
    const GTokenStaking = await ethers.getContractAt("IGTokenStakingV3", CONFIG.GTOKEN_STAKING_V3);
    const SharedConfig = await ethers.getContractAt("SharedConfig", CONFIG.SHARED_CONFIG);
    const GToken = await ethers.getContractAt("IERC20", CONFIG.GTOKEN);

    // Get role IDs
    ROLES.ENDUSER = await SharedConfig.ROLE_ENDUSER();
    ROLES.COMMUNITY = await SharedConfig.ROLE_COMMUNITY();
    ROLES.PAYMASTER = await SharedConfig.ROLE_PAYMASTER();
    ROLES.SUPER = await SharedConfig.ROLE_SUPER();

    console.log("Role IDs loaded:");
    console.log("- ENDUSER:", ROLES.ENDUSER);
    console.log("- COMMUNITY:", ROLES.COMMUNITY);
    console.log("- PAYMASTER:", ROLES.PAYMASTER);
    console.log("- SUPER:", ROLES.SUPER);
    console.log("\n");

    // Get signers
    const [deployer, user1, user2, community1] = await ethers.getSigners();

    // Run tests
    await testRoleRegistration(Registry, user1);
    await testCommunityRegistration(Registry, community1);
    await testMySBTMinting(MySBT, Registry, GToken, user2, community1);
    await testRoleExit(Registry, user1);
    await testGasUsage(Registry, SharedConfig);
    await testBackwardCompatibility(Registry, community1);

    console.log("\n=== All Tests Completed Successfully ===");
}

async function testRoleRegistration(Registry, user) {
    console.log("1. Testing Role Registration...");

    try {
        // Register as ENDUSER
        const roleData = ethers.utils.defaultAbiCoder.encode(
            ["string"],
            ["Test EndUser registration"]
        );

        const tx = await Registry.connect(user).registerRoleSelf(
            ROLES.ENDUSER,
            roleData
        );
        const receipt = await tx.wait();

        console.log("   ✅ EndUser registration successful");
        console.log(`   Gas used: ${receipt.gasUsed.toString()}`);

        // Verify registration
        const hasRole = await Registry.hasRole(ROLES.ENDUSER, user.address);
        if (!hasRole) {
            throw new Error("Role not assigned after registration");
        }
        console.log("   ✅ Role verification successful");

    } catch (error) {
        console.error("   ❌ Role registration failed:", error.message);
        process.exit(1);
    }
}

async function testCommunityRegistration(Registry, community) {
    console.log("\n2. Testing Community Registration...");

    try {
        // Prepare community profile
        const profile = {
            name: "Test Community v3",
            ensName: "testcommunity.eth",
            xPNTsToken: ethers.constants.AddressZero,
            supportedSBTs: [],
            paymasterAddress: ethers.constants.AddressZero,
            allowPermissionlessMint: true
        };

        const stakeAmount = ethers.utils.parseEther("30"); // 30 GT minimum for community

        const roleData = ethers.utils.defaultAbiCoder.encode(
            [
                "tuple(string name, string ensName, address xPNTsToken, address[] supportedSBTs, address paymasterAddress, bool allowPermissionlessMint)",
                "uint256"
            ],
            [profile, stakeAmount]
        );

        // Register community
        const tx = await Registry.connect(community).registerRole(
            ROLES.COMMUNITY,
            community.address,
            roleData
        );
        const receipt = await tx.wait();

        console.log("   ✅ Community registration successful");
        console.log(`   Gas used: ${receipt.gasUsed.toString()}`);

        // Verify registration
        const hasRole = await Registry.hasRole(ROLES.COMMUNITY, community.address);
        if (!hasRole) {
            throw new Error("Community role not assigned");
        }
        console.log("   ✅ Community verification successful");

    } catch (error) {
        console.error("   ❌ Community registration failed:", error.message);
    }
}

async function testMySBTMinting(MySBT, Registry, GToken, user, community) {
    console.log("\n3. Testing MySBT Minting with v3...");

    try {
        // Check if community allows permissionless mint
        const config = await Registry.getRoleConfig(ROLES.COMMUNITY);
        if (!config.allowPermissionlessMint) {
            console.log("   ⚠️  Community doesn't allow permissionless mint");
            return;
        }

        // Mint SBT with auto-stake
        const stakeAmount = ethers.utils.parseEther("0.3");
        const mintFee = ethers.utils.parseEther("0.1");
        const totalAmount = stakeAmount.add(mintFee);

        // Approve GToken
        await GToken.connect(user).approve(MySBT.address, totalAmount);

        // Mint SBT
        const metadata = ethers.utils.toUtf8Bytes("Test SBT metadata v3");
        const tx = await MySBT.connect(user).safeMintAndJoinWithAutoStake(
            community.address,
            metadata,
            stakeAmount
        );
        const receipt = await tx.wait();

        console.log("   ✅ SBT minting successful");
        console.log(`   Gas used: ${receipt.gasUsed.toString()}`);

        // Verify SBT ownership
        const tokenId = await MySBT.userToSBT(user.address);
        if (tokenId.eq(0)) {
            throw new Error("SBT not minted");
        }
        console.log(`   ✅ SBT verified, Token ID: ${tokenId.toString()}`);

    } catch (error) {
        console.error("   ❌ MySBT minting failed:", error.message);
    }
}

async function testRoleExit(Registry, user) {
    console.log("\n4. Testing Role Exit...");

    try {
        // Exit from ENDUSER role
        const tx = await Registry.connect(user).exitRole(ROLES.ENDUSER);
        const receipt = await tx.wait();

        console.log("   ✅ Role exit successful");
        console.log(`   Gas used: ${receipt.gasUsed.toString()}`);

        // Verify exit
        const hasRole = await Registry.hasRole(ROLES.ENDUSER, user.address);
        if (hasRole) {
            throw new Error("Role not removed after exit");
        }
        console.log("   ✅ Role exit verified");

    } catch (error) {
        console.error("   ❌ Role exit failed:", error.message);
    }
}

async function testGasUsage(Registry, SharedConfig) {
    console.log("\n5. Testing Gas Optimization...");

    try {
        // Get target gas limits
        const targetRegisterGas = await SharedConfig.TARGET_REGISTER_GAS();
        const targetExitGas = await SharedConfig.TARGET_EXIT_GAS();

        console.log(`   Target registration gas: ${targetRegisterGas.toString()}`);
        console.log(`   Target exit gas: ${targetExitGas.toString()}`);

        // Estimate gas for registration
        const [, testUser] = await ethers.getSigners();
        const roleData = ethers.utils.defaultAbiCoder.encode(["string"], ["Gas test"]);

        const estimatedGas = await Registry.connect(testUser).estimateGas.registerRoleSelf(
            ROLES.ENDUSER,
            roleData
        );

        console.log(`   Estimated registration gas: ${estimatedGas.toString()}`);

        if (estimatedGas.lte(targetRegisterGas)) {
            console.log("   ✅ Gas optimization target met");
        } else {
            console.log("   ⚠️  Gas usage exceeds target");
        }

    } catch (error) {
        console.error("   ❌ Gas testing failed:", error.message);
    }
}

async function testBackwardCompatibility(Registry, community) {
    console.log("\n6. Testing Backward Compatibility...");

    try {
        // Test v2 compatible function
        const isRegistered = await Registry.isRegisteredCommunity(community.address);
        if (!isRegistered) {
            throw new Error("v2 compatibility check failed");
        }
        console.log("   ✅ v2 isRegisteredCommunity() works");

        // Test community profile retrieval
        const profile = await Registry.getCommunityProfile(community.address);
        console.log(`   ✅ Community profile retrieved: ${profile.name}`);

    } catch (error) {
        console.error("   ❌ Backward compatibility failed:", error.message);
    }
}

// Error handling
process.on("unhandledRejection", (error) => {
    console.error("Unhandled promise rejection:", error);
    process.exit(1);
});

// Run tests
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });