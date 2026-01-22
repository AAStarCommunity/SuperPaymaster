// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/v4/Paymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockEntryPoint {
    function depositTo(address account) external payable {}
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce) { return 0; }
}

contract MockOracle {
    int256 public price;
    uint256 public updatedAt;
    uint8 public decimalsVal = 8;

    function setPrice(int256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 _updatedAt,
        uint80 answeredInRound
    ) {
        return (0, price, 0, updatedAt, 0);
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }
}

contract MockRegistry {
    function isPaymasterActive(address) external pure returns (bool) { return true; }
    function deactivate() external {}
}

contract PaymasterV4CriticalTest is Test {
    Paymaster paymaster;
    MockToken token;
    MockOracle oracle;
    MockEntryPoint entryPoint;
    MockRegistry registry;
    address owner = address(0x123);
    address user = address(0x456);
    address treasury = address(0x789);

    function setUp() public {
        token = new MockToken();
        oracle = new MockOracle();
        entryPoint = new MockEntryPoint();
        registry = new MockRegistry();

        // Deploy Implementation
        Paymaster implementation = new Paymaster(address(registry));
        
        // Deploy Proxy
        paymaster = Paymaster(payable(Clones.clone(address(implementation))));

        // Initialize
        paymaster.initialize(
            address(entryPoint),
            owner,
            treasury,
            address(oracle),
            100, // 1% fee
            1 ether, // maxGasCostCap
            3600 // staleness 1 hour
        );

        // Setup User Balance
        vm.prank(owner);
        paymaster.setTokenPrice(address(token), 1e8); // 1 Token = $1
        
        token.mint(address(paymaster), 1000 ether);
        // We need to use 'depositFor' to credit internal balance, but for test simplicity we can cheat or use depositFor
        // Mock depositFor logic:
        vm.prank(address(paymaster)); // Mock transferFrom success
        token.approve(address(paymaster), 1000 ether);
        
        vm.startPrank(user);
        token.mint(user, 100 ether);
        token.approve(address(paymaster), 100 ether);
        paymaster.depositFor(user, address(token), 50 ether);
        vm.stopPrank();
    }

    function test_Critical_ValidUntil() public {
        // 1. Set Oracle Price
        uint256 nowTime = 1000000;
        vm.warp(nowTime);
        
        oracle.setPrice(3000e8, nowTime); // ETH = $3000
        
        // Update Cache
        // Usually keeper calls updatePrice, or owner calls setCachedPrice
        vm.prank(owner);
        paymaster.setCachedPrice(3000e8, uint48(nowTime));

        // 2. Prepare UserOp
        PackedUserOperation memory userOp;
        userOp.sender = user;
        
        // paymasterAndData = [paymaster 20][offset padding 32][token 20] -> This format is wrong based on Offset 52
        // Offset 52 means: first 20 bytes is Paymaster Address (standard)
        // Then 32 bytes is... what? usually gas limits.
        // Wait, UserOp.paymasterAndData structure in 0.7:
        // [paymaster (20 bytes)] + [paymasterData (bytes)]
        // The EntryPoint passes the WHOLE `paymasterAndData` field to the Paymaster.
        // So index 0 is paymaster address.
        // Index 20 to 52 (32 bytes) is usually empty or specific to paymaster.
        // PaymasterBase expects Token at 52.
        
        bytes memory pmData = abi.encodePacked(
            address(paymaster),      // 0-20
            bytes32(0),              // 20-52 (Padding/GasLimits placeholder)
            address(token)           // 52-72
        );
        userOp.paymasterAndData = pmData;

        // 3. Validate
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.01 ether // maxCost
        );

        // 4. Verify ValidationData
        // validationData format: [authorizer(20)][validUntil(6)][validAfter(6)]
        // We expect authorizer=0 (success), validAfter=0.
        // validUntil = nowTime + 3600 = 1003600.
        
        // Unpack:
        // uint256(uint160(aggregator)) | (uint256(validUntil) << 160) | (uint256(validAfter) << (160 + 48))
        
        uint48 validUntil = uint48(validationData >> 160);
        uint48 validAfter = uint48(validationData >> (160 + 48));
        address authorizer = address(uint160(validationData));

        assertEq(authorizer, address(0), "Authorizer should be 0");
        assertEq(validAfter, 0, "ValidAfter should be 0");
        assertEq(validUntil, nowTime + 3600, "ValidUntil should be now + 1hr");
        
        console.log("Validation Data: ", validationData);
        console.log("Valid Until: ", validUntil);
    }
    
    function test_Offset_Logic() public {
         // Test strict length check
         PackedUserOperation memory userOp;
         userOp.sender = user;
         // Too short (71 bytes)
         userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            bytes32(0),
            bytes19(0) // 1 byte short
        );
        
        vm.prank(address(entryPoint));
        vm.expectRevert(); // Paymaster__InvalidPaymasterData
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.1 ether);
    }
}
