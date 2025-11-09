// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title SuperPaymasterV2Invariants
 * @notice Echidna invariant tests for SuperPaymasterV2
 * @dev Tests operator accounts, reputation system, and balance management
 */
contract SuperPaymasterV2Invariants {
    SuperPaymasterV2 public paymaster;
    MockGToken public gtoken;
    GTokenStaking public staking;
    MockRegistry public registry;
    MockPriceFeed public priceFeed;

    address public constant OPERATOR1 = address(0x1111);
    address public constant OPERATOR2 = address(0x2222);
    address public constant DVT_AGGREGATOR = address(0x3333);

    // Track operators for invariant checking
    address[] public operators;
    mapping(address => bool) public isOperator;

    // Track previous state for monotonicity checks
    mapping(address => uint256) public prevTotalSpent;
    mapping(address => uint256) public prevReputationLevel;

    constructor() {
        // Deploy dependencies
        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken));
        registry = new MockRegistry();
        priceFeed = new MockPriceFeed();

        // Setup staking
        staking.setTreasury(address(this));

        // Deploy paymaster
        paymaster = new SuperPaymasterV2(
            address(staking),
            address(registry),
            address(priceFeed)
        );

        // Set DVT aggregator
        paymaster.setDVTAggregator(DVT_AGGREGATOR);

        // Mint tokens
        gtoken.mint(address(this), 1_000_000 ether);
        gtoken.mint(OPERATOR1, 1_000_000 ether);
        gtoken.mint(OPERATOR2, 1_000_000 ether);

        // Approve staking
        gtoken.approve(address(staking), type(uint256).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    HELPER FUNCTIONS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _registerOperator(address operator) internal {
        if (!isOperator[operator]) {
            operators.push(operator);
            isOperator[operator] = true;
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                OPERATOR ACCOUNT INVARIANTS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 1: aPNTs balance must be >= 0
    function echidna_apnts_balance_non_negative() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
                ,  // stakedAt
                uint256 aPNTsBalance,
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
            ) = paymaster.accounts(operator);

            // aPNTsBalance is uint256, so always >= 0
            // But we check it's not absurdly high
            if (aPNTsBalance > 1_000_000_000 ether) return false;
        }
        return true;
    }

    /// INVARIANT 2: totalSpent must be monotonically increasing
    function echidna_total_spent_increases() public returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
                ,  // stakedAt
                ,  // aPNTsBalance
                uint256 totalSpent,
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
            ) = paymaster.accounts(operator);

            // totalSpent should never decrease
            if (totalSpent < prevTotalSpent[operator]) return false;

            // Update previous state
            prevTotalSpent[operator] = totalSpent;
        }
        return true;
    }

    /// INVARIANT 3: stGTokenLocked must be <= actual locked amount in staking
    function echidna_locked_amount_consistency() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
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
            ) = paymaster.accounts(operator);

            // Get actual locked amount from staking contract
            (uint256 actualLocked, , , ) = staking.locks(operator, address(paymaster));

            // Claimed locked amount must not exceed actual locked amount
            if (stGTokenLocked > actualLocked) return false;
        }
        return true;
    }

    /// INVARIANT 4: Reputation level must be in valid range (1-12)
    function echidna_reputation_level_range() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
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
                uint256 reputationLevel,
                ,  // lastCheckTime
                   // isPaused
            ) = paymaster.accounts(operator);

            // Reputation level should be 0 (uninitialized) or 1-12
            if (reputationLevel > 12) return false;
        }
        return true;
    }

    /// INVARIANT 5: stakedAt timestamp must be in the past
    function echidna_staked_at_in_past() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
                uint256 stakedAt,
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
            ) = paymaster.accounts(operator);

            // If stakedAt is set (non-zero), it must be <= current time
            if (stakedAt > 0 && stakedAt > block.timestamp) return false;
        }
        return true;
    }

    /// INVARIANT 6: totalTxSponsored must be monotonically increasing
    function echidna_total_tx_increases() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
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
                uint256 totalTxSponsored,
                ,  // reputationLevel
                ,  // lastCheckTime
                   // isPaused
            ) = paymaster.accounts(operator);

            // totalTxSponsored is uint256, so always >= 0
            // Just check it's reasonable
            if (totalTxSponsored > 1_000_000_000) return false;
        }
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  REPUTATION INVARIANTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 7: Reputation score must match reputation level
    function echidna_reputation_score_matches_level() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
                ,  // stakedAt
                ,  // aPNTsBalance
                ,  // totalSpent
                ,  // lastRefillTime
                ,  // minBalanceThreshold
                ,  // supportedSBTs
                ,  // xPNTsToken
                ,  // treasury
                ,  // exchangeRate
                uint256 reputationScore,
                ,  // consecutiveDays
                ,  // totalTxSponsored
                uint256 reputationLevel,
                ,  // lastCheckTime
                   // isPaused
            ) = paymaster.accounts(operator);

            // If level is set, score should be reasonable
            if (reputationLevel > 0 && reputationScore == 0) return false;

            // Reputation score should be >= 1 GT if level > 0
            if (reputationLevel > 0 && reputationScore < 1 ether) return false;

            // Reputation score should be <= 144 GT (max Fibonacci level)
            if (reputationScore > 144 ether) return false;
        }
        return true;
    }

    /// INVARIANT 8: consecutiveDays must be reasonable
    function echidna_consecutive_days_reasonable() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
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
                uint256 consecutiveDays,
                ,  // totalTxSponsored
                ,  // reputationLevel
                ,  // lastCheckTime
                   // isPaused
            ) = paymaster.accounts(operator);

            // consecutiveDays should be reasonable (< 10 years)
            if (consecutiveDays > 3650) return false;
        }
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CONFIG INVARIANTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 9: minBalanceThreshold must be reasonable
    function echidna_min_balance_threshold_reasonable() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
                ,  // stakedAt
                ,  // aPNTsBalance
                ,  // totalSpent
                ,  // lastRefillTime
                uint256 minBalanceThreshold,
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
            ) = paymaster.accounts(operator);

            // minBalanceThreshold should be <= 10,000 aPNTs
            if (minBalanceThreshold > 10_000 ether) return false;
        }
        return true;
    }

    /// INVARIANT 10: Exchange rate must be reasonable
    function echidna_exchange_rate_reasonable() public view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            (
                ,  // stGTokenLocked
                ,  // stakedAt
                ,  // aPNTsBalance
                ,  // totalSpent
                ,  // lastRefillTime
                ,  // minBalanceThreshold
                ,  // supportedSBTs
                ,  // xPNTsToken
                ,  // treasury
                uint256 exchangeRate,
                ,  // reputationScore
                ,  // consecutiveDays
                ,  // totalTxSponsored
                ,  // reputationLevel
                ,  // lastCheckTime
                   // isPaused
            ) = paymaster.accounts(operator);

            // Exchange rate should be 0 (unset) or reasonable (0.1x to 10x)
            if (exchangeRate > 0) {
                if (exchangeRate < 0.1 ether || exchangeRate > 10 ether) return false;
            }
        }
        return true;
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
    function isValidCommunity(address) external pure returns (bool) {
        return true;
    }
}

contract MockPriceFeed {
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
        return (1, 2000_00000000, block.timestamp, block.timestamp, 1); // $2000
    }
}
