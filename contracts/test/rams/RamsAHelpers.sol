// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol";
import "src/interfaces/v3/IRegistry.sol";
import {Math} from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";

interface RamsTokenLimits {
    function maxSingleTxLimit() external view returns (uint256);
    function exchangeRate() external view returns (uint256);
    function SUPERPAYMASTER_ADDRESS() external view returns (address);
    function emergencyDisabled() external view returns (bool);
    function getDebt(address) external view returns (uint256);
}

interface RamsLegacyDebt {
    function pendingDebts(address token, address user) external view returns (uint256);
}

library RamsBudget {
    /// @dev Conservative v1 transferFrom chunk: the guard compares floor(x * 1e18 / rate)
    /// to the aPNTs limit. Also keep the raw chunk <= limit.
    function depositChunk(uint256 limit, uint256 rate) internal pure returns (uint256) {
        require(limit != 0 && rate != 0, "RAMS: zero deposit limit/rate");
        uint256 chunk = Math.min(limit, Math.mulDiv(limit, rate, 1 ether));
        // The token floors its conversion: a one-wei chunk can still be legal
        // when the conservative inverse rounded to zero (e.g. limit=1, rate=0.7e18).
        if (chunk == 0 && 1 ether / rate <= limit) chunk = 1;
        require(chunk != 0, "RAMS: deposit limit cannot fund one token wei");
        return chunk;
    }

    /// @dev EntryPoint v0.7 _getRequiredPrefund, including BOTH paymaster gas limits.
    /// Short/malformed paymaster data is used only by the global-pause negative controls.
    function requiredGas(PackedUserOperation memory op) internal pure returns (uint256 gas) {
        gas = uint128(uint256(op.accountGasLimits) >> 128) + uint256(uint128(uint256(op.accountGasLimits)))
            + op.preVerificationGas;
        bytes memory pmd = op.paymasterAndData;
        if (pmd.length >= 52) {
            uint256 packed;
            assembly { packed := mload(add(pmd, 52)) }
            gas += (packed >> 128) + uint256(uint128(packed));
        }
    }

    function maxCost(PackedUserOperation memory op) internal pure returns (uint256) {
        return requiredGas(op) * uint128(uint256(op.gasFees));
    }

    /// @dev Both 5.4.2 and 5.5.0 round up twice and add the same 10% validation buffer.
    function reservation(uint256 cost, uint256 price, uint8 decimals, uint256 aPrice, uint256 feeBps)
        internal
        pure
        returns (uint256)
    {
        require(price != 0 && aPrice != 0, "RAMS: invalid reservation price");
        uint256 base = Math.mulDiv(cost * price, 1 ether, (10 ** uint256(decimals)) * aPrice, Math.Rounding.Ceil);
        return Math.mulDiv(base, 10_000 + feeBps + 1000, 10_000, Math.Rounding.Ceil);
    }
}

interface RamsRegistry {
    struct CommunityData {
        string name;
        string ensName;
        uint256 stakeAmount;
    }
    function owner() external view returns (address);
    function GTOKEN_STAKING() external view returns (address);
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory);
    function registerRole(bytes32, address, bytes calldata) external;
}

interface RamsStaking {
    function GTOKEN() external view returns (address);
}

interface RamsFactory {
    function deployxPNTsToken(string calldata, string calldata, string calldata, string calldata, uint256, address)
        external
        returns (address);
    function getTokenAddress(address) external view returns (address);
}

interface RamsMint {
    function mint(address, uint256) external;
}

interface RamsSafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @dev Compiler-derived layout only. Never installed in the live proxy.
contract RamsStorageSlots is SuperPaymasterStorage {
    constructor(IEntryPoint ep, IRegistry registry, address feed) SuperPaymasterStorage(ep, registry, feed) {}

    function slots()
        external
        pure
        returns (uint256 gasSlot, uint256 pendingSlot, uint256 pauseSlot, uint256 operatorsSlot)
    {
        assembly {
            gasSlot := _gasParams.slot
            pendingSlot := _pendingGasParams.slot
            pauseSlot := guardian.slot
            operatorsSlot := operators.slot
        }
    }

    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external
        pure
        override
        returns (bytes memory, uint256)
    {
        revert("layout only");
    }

    function postOp(PostOpMode, bytes calldata, uint256, uint256) external pure override {
        revert("layout only");
    }
}

contract RamsTarget {
    uint256 public hits;

    function hit() external {
        ++hits;
    }
}
