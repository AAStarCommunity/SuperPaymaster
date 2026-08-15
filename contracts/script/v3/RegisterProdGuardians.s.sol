// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/utils/BLS.sol";

/// @title  RegisterProdGuardians — CC-89 Sepolia production activation
/// @notice Owner-path registration of the 3 persistent DVT guardian BLS keys on the
///         production aggregator (0x174b60bB...). DVT already ROLE_DVT-staked the 3
///         validator EOAs (30 GToken each), so this only binds their BLS keys to
///         slots 1/2/3. Does NOT rewire Registry/SP/DVTValidator — that is done at
///         applyBLSAggregator time (after the 24h SP timelock).
/// @dev    REQUIRES `--evm-version prague` (EIP-2537 BLS precompiles for the on-curve
///         + subgroup validation in registerBLSPublicKey). Run:
///           forge script contracts/script/v3/RegisterProdGuardians.s.sol:RegisterProdGuardians \
///             --rpc-url $SEPOLIA_RPC_URL --evm-version prague --broadcast
///         Reads PRIVATE_KEY_JASON + PROD_G{1,2,3}_{EOA,PUBKEY,POP} (.env.prod-guardians).
contract RegisterProdGuardians is Script {
    address constant PRODAGG = 0x174b60bB462b00550F0EC7Bc35Fe39dDB6310158;

    function _g1(bytes memory b) internal pure returns (BLS.G1Point memory) {
        require(b.length == 128, "pubkey != 128B");
        return abi.decode(b, (BLS.G1Point));
    }
    function _g2(bytes memory b) internal pure returns (BLS.G2Point memory) {
        require(b.length == 256, "pop != 256B");
        return abi.decode(b, (BLS.G2Point));
    }

    function run() external {
        // Hardcoded Sepolia addresses — fail closed on any other chain so this can
        // never broadcast against mainnet/another network.
        require(block.chainid == 11155111, "not Sepolia (11155111)");
        uint256 pk = vm.envUint("PRIVATE_KEY_JASON");
        BLSAggregator agg = BLSAggregator(PRODAGG);
        require(keccak256(bytes(agg.version())) == keccak256("BLSAggregator-4.3.0"), "unexpected version");

        vm.startBroadcast(pk);
        for (uint8 i = 1; i <= 3; i++) {
            address eoa = vm.envAddress(string.concat("PROD_G", vm.toString(i), "_EOA"));
            BLS.G1Point memory pub = _g1(vm.envBytes(string.concat("PROD_G", vm.toString(i), "_PUBKEY")));
            BLS.G2Point memory pop = _g2(vm.envBytes(string.concat("PROD_G", vm.toString(i), "_POP")));
            agg.registerBLSPublicKey(eoa, pub, i, pop);
        }
        vm.stopBroadcast();

        require(agg.validatorAtSlot(1) == vm.envAddress("PROD_G1_EOA"), "slot1");
        require(agg.validatorAtSlot(2) == vm.envAddress("PROD_G2_EOA"), "slot2");
        require(agg.validatorAtSlot(3) == vm.envAddress("PROD_G3_EOA"), "slot3");
        console.log("3 prod guardian BLS keys registered on", PRODAGG);
    }
}
