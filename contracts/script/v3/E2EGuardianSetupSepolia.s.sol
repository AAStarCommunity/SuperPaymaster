// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/utils/BLS.sol";

interface IGT {
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IReg {
    function registerRole(bytes32, address, bytes calldata) external;
    function hasRole(bytes32, address) external view returns (bool);
}

/// @title  E2EGuardianSetupSepolia — CC-89 Phase-2 testnet E2E guardian wiring
/// @notice Pre-stages the 3-guardian set on the freshly deployed A' BLSAggregator:
///         registers 3 BLS keys (owner path), funds + ROLE_DVT-stakes the 2 throwaway
///         slot2/3 addresses so `_reconstructPkAgg` live-checks pass at verifyAndExecute
///         time. slot1 == jason is already ROLE_DVT-staked (30 GToken locked), so only
///         its BLS key is registered here. Does NOT set the fraud-proof verifier — that
///         waits on DVT's verifier address (see CC-89).
/// @dev    `--evm-version prague` is REQUIRED: registerBLSPublicKey invokes the EIP-2537
///         BLS12-381 precompiles (subgroup check), which activate in Prague. The repo
///         default evm_version = cancun has no such precompiles, so local simulation
///         reverts with InvalidBLSKeyNotInSubgroup() before broadcast even though the keys
///         are valid on the live (post-Pectra) Sepolia. Always pass it on BOTH dry-run and
///         broadcast.
///         Run (dry): forge script contracts/script/v3/E2EGuardianSetupSepolia.s.sol:E2EGuardianSetupSepolia \
///                      --rpc-url $SEPOLIA_RPC_URL --evm-version prague
///         Broadcast: same command + --broadcast.
///         Reads PRIVATE_KEY_JASON + GUARDIAN_SLOT{2,3}_KEY
///         + GUARDIAN_SLOT{1,2,3}_{PUBKEY,POP} from env (.env.e2e-guardians, gitignored).
contract E2EGuardianSetupSepolia is Script {
    address constant AGG      = 0xf44E7E51EFFa867114BE48fA92411fE216b1A285;
    address constant REG      = 0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71;
    address constant STAKING  = 0x472297B557c1d0F030f281a5Bb8A535f6c5AB65e;
    address constant GTOKEN   = 0x4c09aE57503Aa1E2A43b05621A38DbdD43b0Aa08;
    bytes32 constant ROLE_DVT = 0x3b5016dc6721b132ddcb7027030b137a739df81e419695dae0899a866c1c514d;
    address constant JASON    = 0xb5600060e6de5E11D3636731964218E53caadf0E;

    uint256 constant MINSTAKE = 30 ether;  // ROLE_DVT minStake
    uint256 constant TOTAL    = 33 ether;  // minStake (30) + ticketPrice (3)
    uint256 constant GAS_FUND = 0.02 ether;

    // 4×bytes32 (128B) and 8×bytes32 (256B) are plain static-field concatenations,
    // so abi.decode reconstructs the BLS point structs directly.
    function _g1(bytes memory b) internal pure returns (BLS.G1Point memory) {
        require(b.length == 128, "pubkey != 128B");
        return abi.decode(b, (BLS.G1Point));
    }
    function _g2(bytes memory b) internal pure returns (BLS.G2Point memory) {
        require(b.length == 256, "pop != 256B");
        return abi.decode(b, (BLS.G2Point));
    }

    function run() external {
        uint256 jasonPk = vm.envUint("PRIVATE_KEY_JASON");
        uint256 s2Pk = vm.envUint("GUARDIAN_SLOT2_KEY");
        uint256 s3Pk = vm.envUint("GUARDIAN_SLOT3_KEY");
        address s2 = vm.addr(s2Pk);
        address s3 = vm.addr(s3Pk);

        BLS.G1Point memory pk1 = _g1(vm.envBytes("GUARDIAN_SLOT1_PUBKEY"));
        BLS.G2Point memory pop1 = _g2(vm.envBytes("GUARDIAN_SLOT1_POP"));
        BLS.G1Point memory pk2 = _g1(vm.envBytes("GUARDIAN_SLOT2_PUBKEY"));
        BLS.G2Point memory pop2 = _g2(vm.envBytes("GUARDIAN_SLOT2_POP"));
        BLS.G1Point memory pk3 = _g1(vm.envBytes("GUARDIAN_SLOT3_PUBKEY"));
        BLS.G2Point memory pop3 = _g2(vm.envBytes("GUARDIAN_SLOT3_POP"));

        require(IReg(REG).hasRole(ROLE_DVT, JASON), "slot1/jason not ROLE_DVT-staked");

        // Phase 1 (jason/owner): register 3 BLS keys FIRST (a bad G1 point aborts before
        // any funds move), then fund the 2 throwaway guardians.
        vm.startBroadcast(jasonPk);
        BLSAggregator(AGG).registerBLSPublicKey(JASON, pk1, 1, pop1);
        BLSAggregator(AGG).registerBLSPublicKey(s2, pk2, 2, pop2);
        BLSAggregator(AGG).registerBLSPublicKey(s3, pk3, 3, pop3);
        IGT(GTOKEN).transfer(s2, TOTAL);
        IGT(GTOKEN).transfer(s3, TOTAL);
        (bool o2,) = s2.call{value: GAS_FUND}("");
        require(o2, "eth->s2");
        (bool o3,) = s3.call{value: GAS_FUND}("");
        require(o3, "eth->s3");
        vm.stopBroadcast();

        // Phase 2 (slot2 self): approve + self-register ROLE_DVT (registerRole gates msg.sender==user).
        vm.startBroadcast(s2Pk);
        IGT(GTOKEN).approve(STAKING, TOTAL);
        IReg(REG).registerRole(ROLE_DVT, s2, abi.encode(MINSTAKE));
        vm.stopBroadcast();

        // Phase 3 (slot3 self).
        vm.startBroadcast(s3Pk);
        IGT(GTOKEN).approve(STAKING, TOTAL);
        IReg(REG).registerRole(ROLE_DVT, s3, abi.encode(MINSTAKE));
        vm.stopBroadcast();

        // Post-conditions: 3 slots bound + 3 addresses hold ROLE_DVT.
        require(BLSAggregator(AGG).validatorAtSlot(1) == JASON, "slot1 bind");
        require(BLSAggregator(AGG).validatorAtSlot(2) == s2, "slot2 bind");
        require(BLSAggregator(AGG).validatorAtSlot(3) == s3, "slot3 bind");
        require(IReg(REG).hasRole(ROLE_DVT, s2), "slot2 role");
        require(IReg(REG).hasRole(ROLE_DVT, s3), "slot3 role");

        console.log("E2E guardian set wired: slot1(jason)/slot2/slot3 BLS-registered + ROLE_DVT-staked");
        console.log("slot2:", s2);
        console.log("slot3:", s3);
        console.log("NEXT: DVT gives verifier addr -> setFraudProofVerifier -> schedule signing window");
    }
}
