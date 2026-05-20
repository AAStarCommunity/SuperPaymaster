// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

./**
 * @title MockDVTExecution
 * @notice Paper7 Step 2 — Execute DVT reputation proposals on-chain for gas measurement
 *
 * Uses a zero G2 signature (will fail BLS pairing on real chain = expected).
 * createProposal() succeeds and gives real on-chain gas.
 * executeWithProof() reverts at pairing but gas up to that point is measured.
 *
 * Run: forge script contracts/script/paper7/MockDVTExecution.s.sol
 *        --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
 * Env: PRIVATE_KEY, ENV
 */
import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/utils/BLS.sol";

contract MockDVTExecution is Script {

    function _proof(uint8 n) internal pure returns (bytes memory) {
        uint256 mask = 0;
        for (uint8 i = 0; i < n; i++) mask |= (1 << i);
        BLS.G2Point memory z;
        return abi.encode(mask, abi.encode(z));
    }

    function _batch(uint256 n) internal pure
        returns (address[] memory us, uint256[] memory sc)
    {
        us = new address[](n); sc = new uint256[](n);
        for (uint256 i = 0; i < n; i++) { us[i] = address(uint160(0x9000+i)); sc[i] = 100+i; }
    }

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", network, ".json"));
        address dvtAddr = vm.envOr("DVT_VALIDATOR_ADDR", stdJson.readAddress(cfg, ".dvtValidator"));
        DVTValidator dvt = DVTValidator(dvtAddr);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address v  = vm.addr(pk);

        require(dvt.isValidator(v), "Not a validator. Run RegisterDVTValidator first.");
        console.log("=== MockDVTExecution ===");
        console.log("network:", network, "validator:", v);

        uint256[] memory sizes = new uint256[](4);
        sizes[0]=1; sizes[1]=10; sizes[2]=50; sizes[3]=100;
        bytes memory proof = _proof(1);
        uint256 epoch = block.timestamp . 3600;

        vm.startBroadcast(pk);
        for (uint256 b = 0; b < sizes.length; b++) {
            uint256 sz = sizes[b];
            (address[] memory us, uint256[] memory sc) = _batch(sz);
            uint256 pid = dvt.createProposal(address(0), 0,
                string.concat("paper7_b", vm.toString(sz)));
            console.log("createProposal pid:", pid, "batchSize:", sz);
            try dvt.executeWithProof(pid, us, sc, epoch, proof) {
                console.log("  executeWithProof: SUCCESS");
            } catch {
                console.log("  executeWithProof: REVERTED (BLS pairing, expected)");
            }
        }
        vm.stopBroadcast();
        console.log("Done. Check Etherscan for gasUsed per tx.");
    }
}
