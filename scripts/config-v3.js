/**
 * Mycelium Protocol v3 Configuration
 * Updated from v2 to use unified registerRole() API
 */

const { ethers } = require("ethers");

// Role IDs for v3
const ROLE_ENDUSER = '0x454e445553455200000000000000000000000000000000000000000000000000';
const ROLE_COMMUNITY = '0x434f4d4d554e4954590000000000000000000000000000000000000000000000';
const ROLE_PAYMASTER = '0x5041594d41535445520000000000000000000000000000000000000000000000';
const ROLE_SUPER = '0x5355504552000000000000000000000000000000000000000000000000000000';

// Contract addresses (update these with v3 deployments)
const CONTRACTS_V3 = {
    REGISTRY_V3: process.env.REGISTRY_V3_ADDRESS || "0x...",
    MYSBT_V3: process.env.MYSBT_V3_ADDRESS || "0x...",
    GTOKEN_STAKING_V3: process.env.GTOKEN_STAKING_V3_ADDRESS || "0x...",

    // Existing contracts remain the same
    GTOKEN: "0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc",
    ENTRYPOINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
};

// Load v3 ABIs
const ABIS_V3 = {
    REGISTRY_V3: require("./abis/Registry_v3.json"),
    MYSBT_V3: require("./abis/MySBT_v3.json"),
    GTOKEN_STAKING_V3: require("./abis/IGTokenStakingV3.json"),
};

// Helper function: Encode role data for registerRole()
function encodeRoleData(roleId, data) {
    if (roleId === ROLE_COMMUNITY) {
        return ethers.utils.defaultAbiCoder.encode(
            ["tuple(string,string,address,address[],address,bool)", "uint256"],
            [data.profile, data.stakeAmount]
        );
    } else if (roleId === ROLE_ENDUSER) {
        return ethers.utils.defaultAbiCoder.encode(["string"], [data.metadata || ""]);
    }
    // Add other role encodings as needed
    return "0x";
}

module.exports = {
    ROLE_ENDUSER,
    ROLE_COMMUNITY,
    ROLE_PAYMASTER,
    ROLE_SUPER,
    CONTRACTS_V3,
    ABIS_V3,
    encodeRoleData
};
