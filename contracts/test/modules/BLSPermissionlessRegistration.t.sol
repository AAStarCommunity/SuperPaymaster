// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";

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

    BLSAggregator bls;
    MockRegistryPermissionlessRegistration registry;
    MockStakingPermissionlessRegistration staking;

    address owner = address(0xA11CE);
    address sp = address(0xBEEF);
    address dvt = address(0xD17);
    address validator = address(0xCAFE);
    address stranger = address(0xBAD);

    function setUp() public {
        vm.etch(address(0x0b), hex"60806000f3"); // G1ADD returns 128 zero bytes.
        vm.etch(address(0x0c), hex"60806000f3"); // G1MUL returns identity.
        vm.etch(address(0x0d), hex"6101006000f3"); // G2ADD returns 256 zero bytes.
        vm.etch(address(0x11), hex"6101006000f3"); // MapFp2ToG2 returns 256 zero bytes.
        vm.etch(address(0x0F), hex"600060005260206000f3"); // Pairing returns false.

        vm.startPrank(owner);
        registry = new MockRegistryPermissionlessRegistration();
        staking = new MockStakingPermissionlessRegistration();
        registry.setStakingAddr(address(staking));
        bls = new BLSAggregator(address(registry), sp, dvt);
        vm.stopPrank();
    }

    function _key(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function test_defaultSwitchFalse() public view {
        assertEq(bls.permissionlessBLSRegistration(), false);
    }

    function test_ownerPathAlwaysWorks() public {
        vm.prank(owner);
        bls.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());

        (, uint8 slot, bool active) = bls.getBLSPublicKey(validator);
        assertTrue(active);
        assertEq(slot, 1);
    }

    function test_nonOwnerSwitchOff_revert() public {
        vm.prank(stranger);
        vm.expectRevert(BLSAggregator.PermissionlessRegistrationDisabled.selector);
        bls.registerBLSPublicKey(stranger, _key(1), 1, _emptyPoP());
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
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnauthorizedCaller.selector, stranger));
        bls.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());
    }

    function test_switchOn_noDVTRole_revert() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, false);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotValidatorRoleRevoked.selector, uint8(1), validator));
        bls.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());
    }

    function test_switchOn_validRoleInvalidPoP_revert() public {
        vm.prank(owner);
        bls.setPermissionlessBLSRegistration(true);
        registry.setHasDvtRole(validator, true);
        staking.setLocked(validator, 200);

        vm.prank(validator);
        vm.expectRevert(BLSAggregator.InvalidPoP.selector);
        bls.registerBLSPublicKey(validator, _key(1), 1, _emptyPoP());
    }

    function test_switchOn_validRoleValidPoP_TODO() public pure {
        // TODO: Constructing a valid BLS12-381 G1/G2 keypair plus proof-of-possession
        // requires real EIP-2537 precompile behavior and off-chain BLS signing, which is
        // impractical in this mocked unit-test context.
    }
}
