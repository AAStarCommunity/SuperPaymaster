// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

// Mock EntryPoint for testing
contract MockEntryPointUUPS {
    mapping(address => uint256) public balanceOf;
    function depositTo(address account) external payable { balanceOf[account] += msg.value; }
    function withdrawTo(address payable, uint256) external {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
}

// Mock Price Feed
contract MockPriceFeedUUPS {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

// V2 implementations for upgrade testing
contract RegistryV2 is Registry {
    function version() external pure override returns (string memory) {
        return "Registry-4.1.0-test";
    }
}

contract SuperPaymasterV2 is SuperPaymaster {
    constructor(
        IEntryPoint _entryPoint,
        IRegistry _registry,
        address _ethUsdPriceFeed
    ) SuperPaymaster(_entryPoint, _registry, _ethUsdPriceFeed) {}

    function version() external pure override returns (string memory) {
        return "SuperPaymaster-4.2.0-test";
    }
}

// V3 implementation for multi-step upgrade testing
contract RegistryV3 is Registry {
    function version() external pure override returns (string memory) {
        return "Registry-4.2.0-test";
    }
}

contract SuperPaymasterV3 is SuperPaymaster {
    constructor(
        IEntryPoint _entryPoint,
        IRegistry _registry,
        address _ethUsdPriceFeed
    ) SuperPaymaster(_entryPoint, _registry, _ethUsdPriceFeed) {}

    function version() external pure override returns (string memory) {
        return "SuperPaymaster-4.2.0-test";
    }
}

// Non-UUPS contract for negative testing
contract NonUUPSContract {
    uint256 public value;
    function version() external pure returns (string memory) { return "NotUUPS"; }
}

contract UUPSUpgradeTest is Test {
    Registry registry;
    SuperPaymaster paymaster;
    MockEntryPointUUPS entryPoint;
    MockPriceFeedUUPS priceFeed;

    address owner = address(0xAA);
    address nonOwner = address(0xBB);
    address mockStaking = address(0x11);
    address mockSBT = address(0x22);
    address mockAPNTs = address(0x33);
    address treasury = address(0x44);

    function setUp() public {
        vm.startPrank(owner);

        entryPoint = new MockEntryPointUUPS();
        priceFeed = new MockPriceFeedUUPS();

        // Deploy Registry via proxy
        registry = UUPSDeployHelper.deployRegistryProxy(owner, mockStaking, mockSBT);

        // Deploy SuperPaymaster via proxy
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            mockAPNTs,
            treasury,
            3600
        );

        vm.stopPrank();
    }

    // ====================================
    // Registry UUPS Tests
    // ====================================

    function test_Registry_InitialState() public view {
        assertEq(registry.owner(), owner);
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-4.1.0"));
        assertEq(address(registry.GTOKEN_STAKING()), mockStaking);
        assertEq(address(registry.MYSBT()), mockSBT);
        assertTrue(registry.isReputationSource(owner));
    }

    function test_Registry_UpgradeSuccess() public {
        vm.startPrank(owner);

        RegistryV2 newImpl = new RegistryV2();
        registry.upgradeToAndCall(address(newImpl), "");

        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-4.1.0-test"));
        // State preserved
        assertEq(registry.owner(), owner);
        assertEq(address(registry.GTOKEN_STAKING()), mockStaking);
        assertEq(address(registry.MYSBT()), mockSBT);
        assertTrue(registry.isReputationSource(owner));

        vm.stopPrank();
    }

    function test_Registry_UpgradeRejectedByNonOwner() public {
        vm.startPrank(nonOwner);

        RegistryV2 newImpl = new RegistryV2();
        vm.expectRevert();
        registry.upgradeToAndCall(address(newImpl), "");

        vm.stopPrank();
    }

    function test_Registry_CannotReinitialize() public {
        vm.startPrank(owner);
        vm.expectRevert();
        registry.initialize(nonOwner, address(0x99), address(0x88));
        vm.stopPrank();
    }

    function test_Registry_ImplCannotBeInitialized() public {
        Registry impl = new Registry();
        vm.expectRevert();
        impl.initialize(owner, mockStaking, mockSBT);
    }

    function test_Registry_StatePreservedAfterUpgrade() public {
        vm.startPrank(owner);

        // Set some state
        registry.setSuperPaymaster(address(0x55));
        registry.setReputationSource(address(0x66), true);

        // Upgrade
        RegistryV2 newImpl = new RegistryV2();
        registry.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(registry.SUPER_PAYMASTER(), address(0x55));
        assertTrue(registry.isReputationSource(address(0x66)));

        vm.stopPrank();
    }

    // ====================================
    // SuperPaymaster UUPS Tests
    // ====================================

    function test_SuperPaymaster_InitialState() public view {
        assertEq(paymaster.owner(), owner);
        assertEq(keccak256(bytes(paymaster.version())), keccak256("SuperPaymaster-4.1.0"));
        assertEq(paymaster.APNTS_TOKEN(), mockAPNTs);
        assertEq(paymaster.treasury(), treasury);
        assertEq(paymaster.priceStalenessThreshold(), 3600);
        assertEq(paymaster.aPNTsPriceUSD(), 0.02 ether);
        assertEq(paymaster.protocolFeeBPS(), 1000);
        assertEq(address(paymaster.REGISTRY()), address(registry));
        assertEq(address(paymaster.ETH_USD_PRICE_FEED()), address(priceFeed));
    }

    function test_SuperPaymaster_UpgradeSuccess() public {
        vm.startPrank(owner);

        // Set some state before upgrade
        paymaster.setAPNTsToken(address(0x77));
        paymaster.setTreasury(address(0x88));

        SuperPaymasterV2 newImpl = new SuperPaymasterV2(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        paymaster.upgradeToAndCall(address(newImpl), "");

        // Version updated
        assertEq(keccak256(bytes(paymaster.version())), keccak256("SuperPaymaster-4.2.0-test"));
        // State preserved
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.APNTS_TOKEN(), address(0x77));
        assertEq(paymaster.treasury(), address(0x88));
        assertEq(paymaster.priceStalenessThreshold(), 3600);
        // Immutables preserved (from new impl constructor)
        assertEq(address(paymaster.REGISTRY()), address(registry));
        assertEq(address(paymaster.ETH_USD_PRICE_FEED()), address(priceFeed));

        vm.stopPrank();
    }

    function test_SuperPaymaster_UpgradeRejectedByNonOwner() public {
        vm.startPrank(nonOwner);

        SuperPaymasterV2 newImpl = new SuperPaymasterV2(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        vm.expectRevert();
        paymaster.upgradeToAndCall(address(newImpl), "");

        vm.stopPrank();
    }

    function test_SuperPaymaster_CannotReinitialize() public {
        vm.startPrank(owner);
        vm.expectRevert();
        paymaster.initialize(nonOwner, address(0x99), address(0x88), 7200);
        vm.stopPrank();
    }

    function test_SuperPaymaster_ImplCannotBeInitialized() public {
        SuperPaymaster impl = new SuperPaymaster(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        vm.expectRevert();
        impl.initialize(owner, mockAPNTs, treasury, 3600);
    }

    // ====================================
    // Multisig Upgrade Simulation
    // ====================================

    function test_MultisigUpgrade_TransferAndUpgrade() public {
        address multisig = address(0xCAFE);

        // Transfer ownership to multisig
        vm.prank(owner);
        registry.transferOwnership(multisig);

        // Old owner can no longer upgrade
        RegistryV2 newImpl = new RegistryV2();
        vm.prank(owner);
        vm.expectRevert();
        registry.upgradeToAndCall(address(newImpl), "");

        // Multisig can upgrade
        vm.prank(multisig);
        registry.upgradeToAndCall(address(newImpl), "");
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-4.1.0-test"));
    }

    // ====================================
    // Proxy Address Stability
    // ====================================

    function test_ProxyAddressStableAfterUpgrade() public {
        address registryAddr = address(registry);
        address paymasterAddr = address(paymaster);

        vm.startPrank(owner);

        // Upgrade both
        RegistryV2 regImpl = new RegistryV2();
        registry.upgradeToAndCall(address(regImpl), "");

        SuperPaymasterV2 spImpl = new SuperPaymasterV2(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        paymaster.upgradeToAndCall(address(spImpl), "");

        // Proxy addresses unchanged
        assertEq(address(registry), registryAddr);
        assertEq(address(paymaster), paymasterAddr);

        vm.stopPrank();
    }

    // ====================================
    // Extended Coverage Tests
    // ====================================

    /// @notice Upgrade to non-UUPS implementation should revert (ERC-1967 safety)
    function test_Registry_UpgradeToNonUUPS_Reverts() public {
        vm.startPrank(owner);

        NonUUPSContract notUUPS = new NonUUPSContract();
        vm.expectRevert();
        registry.upgradeToAndCall(address(notUUPS), "");

        // Verify original still works
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-4.1.0"));

        vm.stopPrank();
    }

    /// @notice Upgrade to non-UUPS implementation should revert (SuperPaymaster)
    function test_SuperPaymaster_UpgradeToNonUUPS_Reverts() public {
        vm.startPrank(owner);

        NonUUPSContract notUUPS = new NonUUPSContract();
        vm.expectRevert();
        paymaster.upgradeToAndCall(address(notUUPS), "");

        // Verify original still works
        assertEq(keccak256(bytes(paymaster.version())), keccak256("SuperPaymaster-4.1.0"));

        vm.stopPrank();
    }

    /// @notice Multi-version upgrade chain: V1 → V2 → V3, state preserved throughout
    function test_Registry_DoubleUpgrade_StatePreserved() public {
        vm.startPrank(owner);

        // Set state in V1
        registry.setSuperPaymaster(address(0x55));
        registry.setReputationSource(address(0x66), true);

        // Upgrade V1 → V2
        RegistryV2 v2Impl = new RegistryV2();
        registry.upgradeToAndCall(address(v2Impl), "");
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-4.1.0-test"));
        assertEq(registry.SUPER_PAYMASTER(), address(0x55));

        // Upgrade V2 → V3
        RegistryV3 v3Impl = new RegistryV3();
        registry.upgradeToAndCall(address(v3Impl), "");
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-4.2.0-test"));

        // All state still preserved after two upgrades
        assertEq(registry.owner(), owner);
        assertEq(registry.SUPER_PAYMASTER(), address(0x55));
        assertTrue(registry.isReputationSource(address(0x66)));
        assertEq(address(registry.GTOKEN_STAKING()), mockStaking);
        assertEq(address(registry.MYSBT()), mockSBT);

        vm.stopPrank();
    }

    /// @notice Multi-version upgrade chain for SuperPaymaster
    function test_SuperPaymaster_DoubleUpgrade_StatePreserved() public {
        vm.startPrank(owner);

        // Set state in V1
        paymaster.setAPNTsToken(address(0x77));
        paymaster.setTreasury(address(0x88));

        // Upgrade V1 → V2
        SuperPaymasterV2 v2Impl = new SuperPaymasterV2(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        paymaster.upgradeToAndCall(address(v2Impl), "");

        // Upgrade V2 → V3
        SuperPaymasterV3 v3Impl = new SuperPaymasterV3(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        paymaster.upgradeToAndCall(address(v3Impl), "");

        // All state preserved after two upgrades
        assertEq(keccak256(bytes(paymaster.version())), keccak256("SuperPaymaster-4.2.0-test"));
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.APNTS_TOKEN(), address(0x77));
        assertEq(paymaster.treasury(), address(0x88));
        assertEq(paymaster.aPNTsPriceUSD(), 0.02 ether);
        assertEq(paymaster.protocolFeeBPS(), 1000);
        assertEq(paymaster.priceStalenessThreshold(), 3600);
        // Immutables correct
        assertEq(address(paymaster.REGISTRY()), address(registry));
        assertEq(address(paymaster.ETH_USD_PRICE_FEED()), address(priceFeed));

        vm.stopPrank();
    }

    /// @notice Business logic functions work correctly after upgrade
    function test_SuperPaymaster_BusinessLogicAfterUpgrade() public {
        vm.startPrank(owner);

        // Upgrade
        SuperPaymasterV2 newImpl = new SuperPaymasterV2(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        paymaster.upgradeToAndCall(address(newImpl), "");

        // Verify admin functions still work after upgrade
        paymaster.setAPNTsToken(address(0x99));
        assertEq(paymaster.APNTS_TOKEN(), address(0x99));

        paymaster.setTreasury(address(0xAB));
        assertEq(paymaster.treasury(), address(0xAB));

        paymaster.setProtocolFee(500);
        assertEq(paymaster.protocolFeeBPS(), 500);

        paymaster.setAPNTSPrice(0.05 ether);
        assertEq(paymaster.aPNTsPriceUSD(), 0.05 ether);

        paymaster.setBLSAggregator(address(0xCC));
        assertEq(paymaster.BLS_AGGREGATOR(), address(0xCC));

        // Deposit still works
        vm.deal(owner, 1 ether);
        paymaster.deposit{value: 0.1 ether}();

        vm.stopPrank();
    }

    /// @notice Registry business logic works after upgrade
    function test_Registry_BusinessLogicAfterUpgrade() public {
        vm.startPrank(owner);

        // Upgrade
        RegistryV2 newImpl = new RegistryV2();
        registry.upgradeToAndCall(address(newImpl), "");

        // Verify admin functions still work
        registry.setSuperPaymaster(address(0xDD));
        assertEq(registry.SUPER_PAYMASTER(), address(0xDD));

        registry.setReputationSource(address(0xEE), true);
        assertTrue(registry.isReputationSource(address(0xEE)));

        registry.setCreditTier(7, 5000 ether);
        assertEq(registry.creditTierConfig(7), 5000 ether);

        registry.addLevelThreshold(1000);
        assertEq(registry.levelThresholds(5), 1000);

        vm.stopPrank();
    }

    // ====================================
    // Immutable REGISTRY Tests
    // ====================================

    /// @notice GTokenStaking.REGISTRY is immutable and set at construction
    function test_StakingRegistryIsImmutable() public {
        vm.startPrank(owner);

        // Deploy a real GTokenStaking with registry address
        MockGTokenUUPS gtoken = new MockGTokenUUPS();
        GTokenStaking staking = new GTokenStaking(address(gtoken), owner, address(registry));

        // Verify REGISTRY is set correctly
        assertEq(staking.REGISTRY(), address(registry));

        // No setRegistry function exists — immutable by design
        vm.stopPrank();
    }

    /// @notice MySBT.REGISTRY is immutable and set at construction
    function test_MySBTRegistryIsImmutable() public {
        vm.startPrank(owner);

        MockGTokenUUPS gtoken = new MockGTokenUUPS();
        GTokenStaking staking = new GTokenStaking(address(gtoken), owner, address(registry));
        MySBT sbt = new MySBT(address(gtoken), address(staking), address(registry), owner);

        // Verify REGISTRY is set correctly
        assertEq(sbt.REGISTRY(), address(registry));

        // No setRegistry function exists — immutable by design
        vm.stopPrank();
    }

    /// @notice Registry.setStaking() triggers _syncExitFees for all active roles
    function test_RegistrySetStakingSyncsExitFees() public {
        vm.startPrank(owner);

        MockGTokenUUPS gtoken = new MockGTokenUUPS();

        // Deploy Registry with placeholder staking
        Registry reg = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));

        // Deploy real staking
        GTokenStaking staking = new GTokenStaking(address(gtoken), owner, address(reg));

        // setStaking triggers _syncExitFees
        reg.setStaking(address(staking));

        // Verify exit fees were synced for ROLE_COMMUNITY (exitFeePercent=500, minExitFee=1 ether)
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        (uint256 feePercent, uint256 minFee) = staking.roleExitConfigs(ROLE_COMMUNITY);
        assertEq(feePercent, 500, "Exit fee percent should be synced");
        assertEq(minFee, 1 ether, "Min exit fee should be synced");

        // Verify exit fees were synced for ROLE_ENDUSER (exitFeePercent=1000, minExitFee=0.05 ether)
        bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
        (uint256 feePercentUser, uint256 minFeeUser) = staking.roleExitConfigs(ROLE_ENDUSER);
        assertEq(feePercentUser, 1000, "Enduser exit fee percent should be synced");
        assertEq(minFeeUser, 0.05 ether, "Enduser min exit fee should be synced");

        vm.stopPrank();
    }
}

contract MockGTokenUUPS is ERC20 {
    constructor() ERC20("MockGToken", "mGT") {
        _mint(msg.sender, 1000000 ether);
    }
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
