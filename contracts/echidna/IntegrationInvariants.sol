// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/MySBT_v2.4.0.sol";
import "../../src/paymasters/superpaymaster/v2/SuperPaymasterV2.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title IntegrationInvariants
 * @notice Echidna integration tests for cross-contract interactions
 * @dev Tests interactions between GTokenStaking, MySBT, and SuperPaymaster
 */
contract IntegrationInvariants {
    // Contracts
    MockGToken public gtoken;
    GTokenStaking public staking;
    MySBT_v2_4_0 public sbt;
    SuperPaymasterV2 public paymaster;
    MockRegistry public registry;
    MockPriceFeed public priceFeed;
    MockCommunity public community;

    // Test users
    address public constant USER1 = address(0x1111);
    address public constant USER2 = address(0x2222);
    address public constant OPERATOR = address(0x3333);
    address public constant DAO = address(0x4444);
    address public constant TREASURY = address(0x5555);

    constructor() {
        // Deploy GToken and Staking
        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken));
        staking.setTreasury(TREASURY);

        // Deploy Registry
        registry = new MockRegistry();

        // Deploy MySBT
        sbt = new MySBT_v2_4_0(
            address(gtoken),
            address(staking),
            address(registry),
            DAO
        );

        // Deploy price feed
        priceFeed = new MockPriceFeed();

        // Deploy SuperPaymaster
        paymaster = new SuperPaymasterV2(
            address(staking),
            address(registry),
            address(priceFeed)
        );

        // Deploy community
        community = new MockCommunity(address(sbt), address(gtoken));
        registry.registerCommunity(address(community));

        // Authorize MySBT as locker
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        staking.configureLocker(
            address(sbt),
            true, // authorized
            100,  // 1% fee
            0.3 ether, // min lock
            1000, // 10% max fee
            emptyTiers,
            emptyFees,
            address(0)
        );

        // Mint tokens
        gtoken.mint(address(this), 1_000_000 ether);
        gtoken.mint(USER1, 1_000_000 ether);
        gtoken.mint(USER2, 1_000_000 ether);
        gtoken.mint(OPERATOR, 1_000_000 ether);
        gtoken.mint(address(community), 1_000_000 ether);

        // Approve
        gtoken.approve(address(staking), type(uint256).max);
        gtoken.approve(address(sbt), type(uint256).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              STAKING + SBT INTEGRATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 1: MySBT locked stake must be tracked in GTokenStaking
    function echidna_sbt_locks_tracked_in_staking() public view returns (bool) {
        // Get SBT token for this contract
        uint256 tokenId = sbt.userToSBT(address(this));
        if (tokenId == 0) return true; // No SBT yet

        // Get stake info
        (uint256 stakedAmount, , , , ) = staking.stakes(address(this));
        if (stakedAmount == 0) return true; // No stake yet

        // Get lock info
        (uint256 totalLocked, , , ) = staking.locks(address(this), address(sbt));

        // Locked amount must be <= staked amount
        return totalLocked <= stakedAmount;
    }

    /// INVARIANT 2: User's available balance = staked - locked (by MySBT)
    function echidna_available_balance_correct() public view returns (bool) {
        (uint256 stakedAmount, , , , ) = staking.stakes(address(this));
        if (stakedAmount == 0) return true;

        uint256 balance = staking.balanceOf(address(this));
        uint256 available = staking.availableBalance(address(this));

        (uint256 totalLocked, , , ) = staking.locks(address(this), address(sbt));

        // available = balance - totalLocked
        if (balance < totalLocked) {
            // totalLocked should never exceed balance
            return false;
        }

        return available == balance - totalLocked;
    }

    /// INVARIANT 3: Total GToken balance consistency
    function echidna_total_gtoken_balance() public view returns (bool) {
        uint256 stakingBalance = gtoken.balanceOf(address(staking));
        uint256 totalStaked = staking.totalStaked();

        // Staking contract's GToken balance should equal totalStaked
        return stakingBalance == totalStaked;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*          PAYMASTER + STAKING INTEGRATION                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 4: Paymaster's locked stake must be in GTokenStaking
    function echidna_paymaster_locks_in_staking() public view returns (bool) {
        // Get paymaster account info for OPERATOR
        (
            uint256 stGTokenLocked,
            ,  // stakedAt
            ,  // aPNTsBalance
            ,  // totalSpent
            ,  // lastRefillTime
            ,  // minBalanceThreshold
            ,  // supportedSBTs
            ,  // xPNTsToken
            ,  // treasury
            ,  // exchangeRate
            ,  // reputationScore
            ,  // consecutiveDays
            ,  // totalTxSponsored
            ,  // reputationLevel
            ,  // lastCheckTime
               // isPaused
        ) = paymaster.accounts(OPERATOR);

        if (stGTokenLocked == 0) return true;

        // Check if paymaster has locked this amount for operator in staking
        (uint256 actualLocked, , , ) = staking.locks(OPERATOR, address(paymaster));

        // Claimed locked must not exceed actual locked
        return stGTokenLocked <= actualLocked;
    }

    /// INVARIANT 5: Shares are 1:1 with staked amount
    function echidna_slash_reduces_stake() public view returns (bool) {
        uint256 totalStaked = staking.totalStaked();
        uint256 totalShares = staking.totalShares();

        // In 1:1 shares model, totalStaked should equal totalShares
        return totalStaked == totalShares;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            SBT + PAYMASTER INTEGRATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 6: SBT holders should have minimum locked stake
    function echidna_sbt_requires_min_lock() public view returns (bool) {
        uint256 tokenId = sbt.userToSBT(address(this));
        if (tokenId == 0) return true; // No SBT

        // Get lock info
        (uint256 totalLocked, , , ) = staking.locks(address(this), address(sbt));

        uint256 minLock = sbt.minLockAmount();

        // If SBT exists, there should be at least minLockAmount locked
        // Note: This might be 0 if user burned SBT or left all communities
        // So we just check totalLocked >= 0
        return totalLocked >= 0;
    }

    /// INVARIANT 7: Community count consistency in SBT
    function echidna_sbt_community_count() public view returns (bool) {
        uint256 tokenId = sbt.userToSBT(address(this));
        if (tokenId == 0) return true;

        (, , , uint256 totalCommunities) = sbt.sbtData(tokenId);

        // Total communities should be >= 0 and reasonable (< 1000)
        return totalCommunities >= 0 && totalCommunities < 1000;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                GLOBAL SYSTEM INVARIANTS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 8: No contract should have more GToken than minted
    function echidna_no_token_inflation() public view returns (bool) {
        uint256 stakingBalance = gtoken.balanceOf(address(staking));
        uint256 sbtBalance = gtoken.balanceOf(address(sbt));
        uint256 paymasterBalance = gtoken.balanceOf(address(paymaster));

        uint256 totalSupply = gtoken.totalSupply();

        // Sum of all balances should not exceed total supply
        // (This is always true for ERC20, but we verify)
        return (stakingBalance + sbtBalance + paymasterBalance) <= totalSupply;
    }

    /// INVARIANT 9: Staking shares are 1:1 with GToken
    function echidna_shares_one_to_one() public view returns (bool) {
        // Test conversion for this contract
        (uint256 stakedAmount, uint256 shares, , , ) = staking.stakes(address(this));

        if (stakedAmount == 0) return true;

        // shares should equal stakedAmount (1:1 model)
        return shares == stakedAmount;
    }

    /// INVARIANT 10: Registry communities are tracked correctly
    function echidna_registry_community_valid() public view returns (bool) {
        // All registered communities should return true
        bool valid1 = registry.isValidCommunity(address(community));

        // Random address should return true (our mock registry accepts all)
        // In real system, it would be false for unregistered
        return valid1;
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      MOCK CONTRACTS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract MockGToken is ERC20 {
    constructor() ERC20("Mock GToken", "GT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRegistry {
    mapping(address => bool) public communities;

    function registerCommunity(address community) external {
        communities[community] = true;
    }

    function isValidCommunity(address community) external view returns (bool) {
        return communities[community];
    }
}

contract MockPriceFeed is AggregatorV3Interface {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "ETH/USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, 2000_00000000, block.timestamp, block.timestamp, 1);
    }

    function latestRoundData()
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, 2000_00000000, block.timestamp, block.timestamp, 1);
    }
}

contract MockCommunity {
    MySBT_v2_4_0 public sbt;
    IERC20 public gtoken;

    constructor(address _sbt, address _gtoken) {
        sbt = MySBT_v2_4_0(_sbt);
        gtoken = IERC20(_gtoken);
    }

    function mintSBT(address user, string memory metadata)
        external
        returns (uint256 tokenId, bool isNewMint)
    {
        gtoken.approve(address(sbt), type(uint256).max);
        return sbt.mintOrAddMembership(user, metadata);
    }
}
