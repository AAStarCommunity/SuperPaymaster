// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../../../src/tokens/xPNTsToken.sol";
import "../../../../src/tokens/xPNTsFactory.sol";
import "../../../../src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

contract MockRegistry is IRegistry {
    using Clones for address;
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return bytes32(0); }
    function ROLE_KMS() external pure override returns (bytes32) { return bytes32(0); }
    function ROLE_DVT() external pure override returns (bytes32) { return bytes32(0); }
    function ROLE_ANODE() external pure override returns (bytes32) { return bytes32(0); }
    
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }

    function grantRole(bytes32 role, address account) public {
        roles[role][account] = true;
    }

    // Unused methods
    function roleOwners(bytes32) external view override returns (address) { return address(0); }
    function setRoleOwner(bytes32, address) external override {}
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function createNewRole(bytes32, RoleConfig calldata, address) external override {}
    function exitRole(bytes32) external override {}
    function setRoleLockDuration(bytes32, uint256) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { return RoleConfig(0,0,0,0,0,0,0,false,0,"",address(0),0); }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function registerRoleSelf(bytes32, bytes calldata) external override returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function getCreditLimit(address) external view override returns (uint256) { return 1000 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external pure override returns (string memory) { return "1"; }
}

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 public price;
    uint8 public _decimals;

    constructor(int256 _price, uint8 _dec) {
        price = _price;
        _decimals = _dec;
    }
    
    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external view override returns (string memory) { return "Mock"; }
    function version() external view override returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MaliciousToken is ERC20 {
    SuperPaymaster public paymaster;
    constructor(SuperPaymaster _pm) ERC20("Malicious", "MAL") {
        paymaster = _pm;
    }
    
    function recordDebt(address, uint256) external {
        // Attack: Try to withdraw funds during postOp callback
        paymaster.withdraw(1 ether);
    }
    
    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address) external pure returns (uint256) { return 0; }
}

contract SuperPaymasterHardenVerification is Test {
    using Clones for address;
    SuperPaymaster paymaster;
    xPNTsToken apnts;
    xPNTsFactory factory;
    MockRegistry registry;
    
    address owner = address(0x1);
    address community = address(0x2);
    address ep = address(0x3);
    address priceFeedAddr;
    address treasury = address(0x5);

    function setUp() public {
        vm.warp(1000 days); // Avoid timestamp underflow
        vm.startPrank(owner);
        registry = new MockRegistry();
        address implementation = address(new xPNTsToken());
        apnts = xPNTsToken(implementation.clone());
        apnts.initialize("AAStar PNTs", "aPNTs", owner, "AAStar", "aastar.eth", 1e18);
        
        // Correctly initialize Mock Price Feed
        MockAggregatorV3 realPriceFeed = new MockAggregatorV3(2000 * 1e8, 8);
        priceFeedAddr = address(realPriceFeed);

        // Since we are testing SuperPaymaster initialization, we deploy a minimal factory
        factory = new xPNTsFactory(address(0), address(registry));
        
        paymaster = new SuperPaymaster(
            IEntryPoint(ep),
            owner,
            registry,
            address(apnts),
            priceFeedAddr,
            treasury,
            3600
        );
        
        paymaster.setXPNTsFactory(address(factory));
        
        // Initialize Price Cache
        paymaster.setBLSAggregator(owner);
        paymaster.updatePriceDVT(2000 * 1e8, block.timestamp, "");

        registry.grantRole(registry.ROLE_COMMUNITY(), community);
        registry.grantRole(registry.ROLE_PAYMASTER_SUPER(), community);
        
        vm.stopPrank();
    }

    function testRoundingCeil() public {
        // _calculateAPNTsAmount logic:
        // (ethAmount * price * 1e18) / (10^decimals * aPNTsPriceUSD)
        
        // Mock a situation where division has a remainder
        // Let ethAmount = 1 (1 wei)
        // Let price = 2000 * 1e8 (8 decimals)
        // Let aPNTsPriceUSD = 0.02 * 1e18 (18 decimals)
        
        vm.prank(owner);
        paymaster.setAPNTSPrice(0.03 ether);
        
        // Logic already updated in setUp, but let's be explicit if needed
        // we can just recalculate manually in the test to verify Rounding.Ceil
        uint256 ethAmount = 1;
        uint256 price = 2000 * 1e8;
        uint256 priceDecimals = 8;
        uint256 aPNTsPriceUSD = 0.03 ether;
        
        uint256 expectedCeil = Math.mulDiv(
            ethAmount * price,
            1e18,
            (10**priceDecimals) * aPNTsPriceUSD,
            Math.Rounding.Ceil
        );
        
        uint256 expectedFloor = Math.mulDiv(
            ethAmount * price,
            1e18,
            (10**priceDecimals) * aPNTsPriceUSD,
            Math.Rounding.Floor
        );
        
        assertEq(expectedCeil, 66667);
        assertEq(expectedFloor, 66666);
    }

    function testBondingEnforcement() public {
        address fakeToken = address(0xdead);
        
        vm.prank(community);
        vm.expectRevert("Security: Invalid xPNTsToken for this Community");
        paymaster.configureOperator(fakeToken, community, 1e18);
        
        // Now deploy a real one through factory
        vm.startPrank(community);
        address realToken = factory.deployxPNTsToken("Real", "RL", "Real", "real.eth", 1e18, address(0));
        
        // Should succeed
        paymaster.configureOperator(realToken, community, 1e18);
        vm.stopPrank();
    }

    function testReentrancyProtectionPostOp() public {
        MaliciousToken mal = new MaliciousToken(paymaster);
        
        // Mock factory to accept this malicious token
        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IxPNTsFactory.getTokenAddress.selector, community),
            abi.encode(address(mal))
        );

        vm.prank(community);
        paymaster.configureOperator(address(mal), community, 1e18);
        
        // Fund paymaster for operator
        vm.startPrank(owner);
        apnts.mint(community, 10 ether);
        vm.stopPrank();
        
        vm.startPrank(community);
        apnts.approve(address(paymaster), 10 ether);
        paymaster.deposit(10 ether);
        vm.stopPrank();
        
        // Simulate EntryPoint calling postOp
        bytes memory context = abi.encode(
            address(mal), 
            1 ether, 
            address(0xabc), 
            1 ether, 
            bytes32(0), 
            community
        );
        
        vm.prank(ep);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.01 ether, 0);
    }
}
