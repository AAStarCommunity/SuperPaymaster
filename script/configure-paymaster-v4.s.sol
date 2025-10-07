// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/v3/PaymasterV4.sol";

/// @title Configure PaymasterV4
/// @notice Script for managing SBT and GasToken arrays
contract ConfigurePaymasterV4 is Script {
    PaymasterV4 public paymaster;

    function setUp() public {
        // Set paymaster address from environment or deployment
        address paymasterAddr = vm.envAddress("PAYMASTER_V4_ADDRESS");
        paymaster = PaymasterV4(payable(paymasterAddr));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      SBT MANAGEMENT                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Add a new SBT contract
    function addSBT(address sbt) public {
        require(sbt != address(0), "Invalid SBT address");

        vm.startBroadcast();

        // Verify not already added
        if (paymaster.isSBTSupported(sbt)) {
            console.log("SBT already supported:", sbt);
            vm.stopBroadcast();
            return;
        }

        // Verify array limit
        address[] memory currentSBTs = paymaster.getSupportedSBTs();
        require(currentSBTs.length < paymaster.MAX_SBTS(), "SBT array full");

        // Add SBT
        paymaster.addSBT(sbt);
        console.log("Added SBT:", sbt);

        vm.stopBroadcast();
    }

    /// @notice Remove an SBT contract
    function removeSBT(address sbt) public {
        require(sbt != address(0), "Invalid SBT address");

        vm.startBroadcast();

        // Verify exists
        if (!paymaster.isSBTSupported(sbt)) {
            console.log("SBT not found:", sbt);
            vm.stopBroadcast();
            return;
        }

        // Remove SBT
        paymaster.removeSBT(sbt);
        console.log("Removed SBT:", sbt);

        vm.stopBroadcast();
    }

    /// @notice List all supported SBTs
    function listSBTs() public view {
        address[] memory sbts = paymaster.getSupportedSBTs();
        console.log("Supported SBTs:", sbts.length);
        for (uint256 i = 0; i < sbts.length; i++) {
            console.log("  [%d]", i, sbts[i]);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   GASTOKEN MANAGEMENT                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Add a new GasToken contract
    function addGasToken(address token) public {
        require(token != address(0), "Invalid token address");

        vm.startBroadcast();

        // Verify not already added
        if (paymaster.isGasTokenSupported(token)) {
            console.log("GasToken already supported:", token);
            vm.stopBroadcast();
            return;
        }

        // Verify array limit
        address[] memory currentTokens = paymaster.getSupportedGasTokens();
        require(currentTokens.length < paymaster.MAX_GAS_TOKENS(), "GasToken array full");

        // Add GasToken
        paymaster.addGasToken(token);
        console.log("Added GasToken:", token);

        vm.stopBroadcast();
    }

    /// @notice Remove a GasToken contract
    function removeGasToken(address token) public {
        require(token != address(0), "Invalid token address");

        vm.startBroadcast();

        // Verify exists
        if (!paymaster.isGasTokenSupported(token)) {
            console.log("GasToken not found:", token);
            vm.stopBroadcast();
            return;
        }

        // Remove GasToken
        paymaster.removeGasToken(token);
        console.log("Removed GasToken:", token);

        vm.stopBroadcast();
    }

    /// @notice List all supported GasTokens
    function listGasTokens() public view {
        address[] memory tokens = paymaster.getSupportedGasTokens();
        console.log("Supported GasTokens:", tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("  [%d]", i, tokens[i]);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   PARAMETER MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Set treasury address
    function setTreasury(address treasury) public {
        require(treasury != address(0), "Invalid treasury address");

        vm.startBroadcast();
        paymaster.setTreasury(treasury);
        console.log("Treasury updated to:", treasury);
        vm.stopBroadcast();
    }

    /// @notice Set gas to USD conversion rate
    function setGasToUSDRate(uint256 rate) public {
        require(rate > 0, "Invalid rate");

        vm.startBroadcast();
        paymaster.setGasToUSDRate(rate);
        console.log("GasToUSDRate updated to:", rate);
        vm.stopBroadcast();
    }

    /// @notice Set PNT price in USD
    function setPntPriceUSD(uint256 price) public {
        require(price > 0, "Invalid price");

        vm.startBroadcast();
        paymaster.setPntPriceUSD(price);
        console.log("PntPriceUSD updated to:", price);
        vm.stopBroadcast();
    }

    /// @notice Set service fee rate
    function setServiceFeeRate(uint256 rate) public {
        require(rate <= paymaster.MAX_SERVICE_FEE(), "Fee too high");

        vm.startBroadcast();
        paymaster.setServiceFeeRate(rate);
        console.log("ServiceFeeRate updated to:", rate, "bps");
        vm.stopBroadcast();
    }

    /// @notice Set max gas cost cap
    function setMaxGasCostCap(uint256 cap) public {
        vm.startBroadcast();
        paymaster.setMaxGasCostCap(cap);
        console.log("MaxGasCostCap updated to:", cap);
        vm.stopBroadcast();
    }

    /// @notice Set min token balance
    function setMinTokenBalance(uint256 balance) public {
        require(balance > 0, "Invalid balance");

        vm.startBroadcast();
        paymaster.setMinTokenBalance(balance);
        console.log("MinTokenBalance updated to:", balance);
        vm.stopBroadcast();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    STATUS & EMERGENCY                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Display current paymaster configuration
    function showConfig() public view {
        console.log("=== PaymasterV4 Configuration ===");
        console.log("Version:", paymaster.VERSION());
        console.log("Owner:", paymaster.owner());
        console.log("Treasury:", paymaster.treasury());
        console.log("GasToUSDRate:", paymaster.gasToUSDRate());
        console.log("PntPriceUSD:", paymaster.pntPriceUSD());
        console.log("ServiceFeeRate:", paymaster.serviceFeeRate(), "bps");
        console.log("MaxGasCostCap:", paymaster.maxGasCostCap());
        console.log("MinTokenBalance:", paymaster.minTokenBalance());
        console.log("Paused:", paymaster.paused());
        console.log("EntryPoint deposit:", paymaster.getDeposit());

        console.log("\n--- Supported SBTs ---");
        listSBTs();

        console.log("\n--- Supported GasTokens ---");
        listGasTokens();
    }

    /// @notice Pause the paymaster
    function pause() public {
        vm.startBroadcast();
        paymaster.pause();
        console.log("Paymaster paused");
        vm.stopBroadcast();
    }

    /// @notice Unpause the paymaster
    function unpause() public {
        vm.startBroadcast();
        paymaster.unpause();
        console.log("Paymaster unpaused");
        vm.stopBroadcast();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    BATCH OPERATIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Batch add multiple SBTs
    function batchAddSBTs(address[] memory sbts) public {
        vm.startBroadcast();

        for (uint256 i = 0; i < sbts.length; i++) {
            if (!paymaster.isSBTSupported(sbts[i])) {
                paymaster.addSBT(sbts[i]);
                console.log("Added SBT:", sbts[i]);
            } else {
                console.log("Skipped (already exists):", sbts[i]);
            }
        }

        vm.stopBroadcast();
    }

    /// @notice Batch add multiple GasTokens
    function batchAddGasTokens(address[] memory tokens) public {
        vm.startBroadcast();

        for (uint256 i = 0; i < tokens.length; i++) {
            if (!paymaster.isGasTokenSupported(tokens[i])) {
                paymaster.addGasToken(tokens[i]);
                console.log("Added GasToken:", tokens[i]);
            } else {
                console.log("Skipped (already exists):", tokens[i]);
            }
        }

        vm.stopBroadcast();
    }
}
