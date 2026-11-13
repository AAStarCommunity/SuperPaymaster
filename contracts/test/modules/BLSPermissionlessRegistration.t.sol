// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import {DVTValidator} from "src/modules/monitoring/DVTValidator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";
import {GenuineBLS} from "../helpers/GenuineBLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

contract MockStakingPermissionlessRegistration {
    mapping(address => uint128) public lockedAmount;

    function setLocked(address user, uint128 amount) external {
        lockedAmount[user] = amount;
    }

    function roleLocks(address user, bytes32 roleId)
        external
        view
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (lockedAmount[user], 0, 0, roleId, "");
    }
}

contract MockRegistryPermissionlessRegistration is IRegistry {
    address public stakingAddr;
    mapping(address => bool) public dvtRoleHolders;
    uint256 public minStake = 100;

    function setStakingAddr(address s) external {
        stakingAddr = s;
    }

    function setHasDvtRole(address validator, bool hasRole_) external {
        dvtRoleHolders[validator] = hasRole_;
    }

    function setMinStake(uint256 ms) external {
        minStake = ms;
    }

    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }

    function hasRole(bytes32 roleId, address user) external view override returns (bool) {
        return roleId == ROLE_DVT && dvtRoleHolders[user];
    }

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(minStake, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }

    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external
        override
    {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}

    function getRoleUserCount(bytes32) external view override returns (uint256) {
        return 0;
    }

    function getUserRoles(address) external view override returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function registerRole(bytes32, address, bytes calldata) external override {}

    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) {
        return 0;
    }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}

    function getCreditLimit(address) external view override returns (uint256) {
        return 100 ether;
    }

    function isReputationSource(address) external pure override returns (bool) {
        return true;
    }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}

    function version() external pure override returns (string memory) {
        return "MockRegistryPermissionlessRegistration";
    }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}

    function getEffectiveStake(address, bytes32) external view override returns (uint256) {
        return 0;
    }
}

contract BLSPermissionlessRegistrationTest is Test {
    event PermissionlessBLSRegistrationSet(bool enabled);

    BLS.G1Point genuineKey;
    BLS.G2Point validPoP;
    bool realPrecompiles;
    BLSAggregator bls;
    DVTValidator gateway;
    MockRegistryPermissionlessRegistration registry;
    MockStakingPermissionlessRegistration staking;

    address owner = address(0xA11CE);
    address sp = address(0xBEEF);
    address dvt = address(0xD17);
    address validator = address(0xCAFE);
    address stranger = address(0xBAD);

    function setUp() public {
        realPrecompiles = MockedPrecompiles.praguePrecompilesAvailable();
        if (!realPrecompiles) {
            vm.etch(address(0x0b), hex"60806000f3"); // G1ADD returns 128 zero bytes.
            vm.etch(address(0x0c), hex"60806000f3"); // G1MUL returns identity.
            vm.etch(address(0x0d), hex"6101006000f3"); // G2ADD returns 256 zero bytes.
            vm.etch(address(0x11), hex"6101006000f3"); // MapFp2ToG2 returns 256 zero bytes.
            vm.etch(address(0x0F), hex"600060005260206000f3"); // Pairing returns false.
        }

        vm.startPrank(owner);
        registry = new MockRegistryPermissionlessRegistration();
        staking = new MockStakingPermissionlessRegistration();
        registry.setStakingAddr(address(staking));
        gateway = new DVTValidator(address(registry), 1, address(0));
        dvt = address(gateway);
        bls = new BLSAggregator(address(registry), sp, dvt);
        gateway.setBLSAggregator(address(bls));
        vm.stopPrank();
        if (realPrecompiles) {
            genuineKey = GenuineBLS.publicKey(1);
            validPoP = GenuineBLS.pop(bls, validator, 1);
        }
    }

    function _key(uint256 seed) internal view returns (BLS.G1Point memory pk) {
        if (realPrecompiles) return genuineKey;
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function test_defaultSwitchFalse() public view {
        assertEq(bls.permissionlessBLSRegistration(), false);
    }

    /// CC-48 round-3: the owner path no longer skips proof-of-possession. This suite's
    /// pairing precompile answers FALSE, so an owner registration without a valid PoP
    /// is rejected exactly like a permissionless one. Before round-3 this same call
    /// succeeded — that was the hole: `blsKeyOwner` is a permanent binding, so an owner
    /// typo (or a deliberate pre-emption of a validator's own registration) bound a
    /// third party's public key to the wrong address with no way back.
    function test_ownerPathAlsoRequiresPoP() public {
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidPoP.selector);
        gateway.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());

        (, , bool active) = bls.getBLSPublicKey(validator);
        assertFalse(active, "no key may be bound without a PoP");
        assertEq(bls.blsKeyOwner(keccak256(abi.encode(_key(1).x_a, _key(1).x_b, _key(1).y_a, _key(1).y_b))), address(0));
    }

    /// Registration succeeds with a valid PoP; Cancun uses the pairing stub.
    function test_ownerPathWorksWithAValidPoP() public {
        if (!realPrecompiles) vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        vm.prank(owner);
        gateway.registerBLSPublicKey(validator, _key(1), 1, validPoP);

        (, uint8 slot, bool active) = bls.getBLSPublicKey(validator);
        assertTrue(active);
        assertEq(slot, 1);
    }

    function test_nonOwnerSwitchOff_revert() public {
        vm.prank(stranger);
        vm.expectRevert(DVTValidator.PermissionlessRegistrationDisabled.selector);
        gateway.registerBLSPublicKey(stranger, _key(1), 1, _emptyPoP());
    }

    function test_setSwitch_ownerSucceeds_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit PermissionlessBLSRegistrationSet(true);
        bls.setPermissionlessBLSRegistration(true);

        assertTrue(bls.permissionlessBLSRegistration());
    }

    function test_setSwitch_nonOwner_revert() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        bls.setPermissionlessBLSRegistration(true);
    }

    function test_switchOn_mismatchedSender_revert() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnauthorizedCaller.selector, stranger));
        gateway.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());
    }

    function test_switchOn_noDVTRole_revert() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, false);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorRoleRevoked.selector, validator));
        gateway.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());
    }

    function test_switchOn_validRoleInvalidPoP_revert() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, true);
        staking.setLocked(validator, 200);

        vm.prank(validator);
        vm.expectRevert(BLSAggregator.InvalidPoP.selector);
        gateway.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());
    }

    function test_switchOn_validRoleValidPoP() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, true);
        staking.setLocked(validator, 200);
        if (!realPrecompiles) vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        vm.prank(validator);
        gateway.registerBLSPublicKey(validator, _key(1), 1, validPoP);
        (BLS.G1Point memory stored, uint8 slot, bool active) = bls.getBLSPublicKey(validator);
        assertTrue(active, "self-registration activates key");
        assertEq(slot, 1, "self-registration assigns slot");
        assertEq(abi.encode(stored), abi.encode(_key(1)), "self-registration stores key");
        assertEq(bls.validatorAtSlot(1), validator, "self-registration binds validator");
    }
    function test_switchOn_lowStake_revert() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, true);
        staking.setLocked(validator, 99);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorStakeBelowMinimum.selector, 99, 100));
        gateway.registerBLSPublicKey(validator, _key(1), 1, validPoP);
    }

    function test_permissionlessAssignsLowestFreeSlotAndKeepsItOnReregistration() public {
        BLS.G1Point memory otherKey = realPrecompiles ? GenuineBLS.publicKey(2) : _key(2);
        BLS.G2Point memory otherPoP;
        if (realPrecompiles) otherPoP = GenuineBLS.pop(bls, stranger, 2);
        else vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        vm.startPrank(owner);
        bls.setPermissionlessBLSRegistration(true);
        gateway.registerBLSPublicKey(stranger, otherKey, 1, otherPoP);
        vm.stopPrank();
        registry.setHasDvtRole(validator, true);
        staking.setLocked(validator, 200);
        assertFalse(gateway.isValidator(validator), "no owner admission needed");
        vm.prank(validator);
        gateway.registerBLSPublicKey(validator, _key(1), 64, validPoP);
        (, uint8 slot,) = bls.getBLSPublicKey(validator);
        assertEq(slot, 2, "caller cannot choose its slot");
        vm.prank(owner);
        bls.revokeBLSPublicKey(stranger);
        vm.prank(validator);
        gateway.registerBLSPublicKey(validator, _key(1), 64, validPoP);
        (, slot,) = bls.getBLSPublicKey(validator);
        assertEq(slot, 2, "active registration keeps its slot even if a lower slot is free");
    }

    function test_ownerCanSuspendPermissionlessKeyWithoutLocalAdmission() public {
        if (!realPrecompiles) vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, true);
        staking.setLocked(validator, 200);
        vm.prank(validator);
        gateway.registerBLSPublicKey(validator, _key(1), 1, validPoP);
        assertFalse(gateway.isValidator(validator));
        // One key is below all configured quorums, so removing it destroys none.
        vm.prank(owner);
        gateway.removeValidator(validator);
        assertTrue(gateway.isSuspended(validator));
        (,, bool active) = bls.getBLSPublicKey(validator);
        assertFalse(active);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorSuspended.selector, validator));
        gateway.registerBLSPublicKey(validator, _key(1), 1, validPoP);
        vm.prank(owner);
        gateway.addValidator(validator);
        vm.prank(validator);
        gateway.registerBLSPublicKey(validator, _key(1), 1, validPoP);
        (,, active) = bls.getBLSPublicKey(validator);
        assertTrue(active);
    }

}
