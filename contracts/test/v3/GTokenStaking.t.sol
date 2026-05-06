// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

contract MockGTokenForStakingSync is ERC20 {
    constructor() ERC20("GToken", "GT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegistrySyncStub {
    GTokenStaking public staking;
    bool public shouldRevert;
    address public lastUser;
    bytes32 public lastRoleId;
    uint256 public lastAmount;

    function setStaking(GTokenStaking _staking) external {
        staking = _staking;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function lockStake(address user, bytes32 roleId, uint256 amount, address payer) external {
        staking.lockStakeWithTicket(user, roleId, amount, 0, payer);
    }

    function syncStakeFromStaking(address user, bytes32 roleId, uint256 newAmount) external {
        if (shouldRevert) revert("sync failed");
        lastUser = user;
        lastRoleId = roleId;
        lastAmount = newAmount;
    }

    function getEffectiveStake(address user, bytes32 roleId) external view returns (uint256) {
        return staking.getLockedStake(user, roleId);
    }
}

contract GTokenStakingSyncTest is Test {
    event SyncFailed(address indexed registry, bytes reason);

    bytes32 internal constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    MockGTokenForStakingSync internal gtoken;
    RegistrySyncStub internal registry;
    GTokenStaking internal staking;
    address internal treasury = address(0xA11CE);
    address internal user = address(0xB0B);

    function setUp() public {
        gtoken = new MockGTokenForStakingSync();
        registry = new RegistrySyncStub();
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        registry.setStaking(staking);

        gtoken.mint(user, 1_000 ether);
        vm.prank(user);
        gtoken.approve(address(staking), type(uint256).max);
    }

    function test_SyncStakeFromStaking_SucceedsWhenRegistryAccepts() public {
        registry.lockStake(user, ROLE_PAYMASTER_SUPER, 50 ether, user);

        assertEq(registry.lastUser(), user);
        assertEq(registry.lastRoleId(), ROLE_PAYMASTER_SUPER);
        assertEq(registry.lastAmount(), 50 ether);
        assertEq(staking.getLockedStake(user, ROLE_PAYMASTER_SUPER), 50 ether);
        assertEq(registry.getEffectiveStake(user, ROLE_PAYMASTER_SUPER), 50 ether);
    }

    function test_SyncFailed_EmittedWhenRegistryReverts() public {
        registry.setShouldRevert(true);

        bytes memory reason = abi.encodeWithSignature("Error(string)", "sync failed");
        vm.expectEmit(true, false, false, true, address(staking));
        emit SyncFailed(address(registry), reason);

        registry.lockStake(user, ROLE_PAYMASTER_SUPER, 50 ether, user);

        assertEq(staking.getLockedStake(user, ROLE_PAYMASTER_SUPER), 50 ether);
        assertEq(gtoken.balanceOf(address(staking)), 50 ether);
        assertEq(registry.lastAmount(), 0);
    }
}
