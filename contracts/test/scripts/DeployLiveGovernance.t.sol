// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {DeployLive} from "../../script/v3/DeployLive.s.sol";
import {DeployNewBLSModules} from "../../script/v3/DeployNewBLSModules.s.sol";
import {BLSAggregator} from "../../src/modules/monitoring/BLSAggregator.sol";
import {DVTValidator} from "../../src/modules/monitoring/DVTValidator.sol";

contract SingleStepOwnedFixture {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        owner = newOwner;
    }
}

contract DeployLiveGovernanceHarness is DeployLive {
    function deployOwnershipFixtures() external {
        aggregator = BLSAggregator(address(new SingleStepOwnedFixture()));
        dvt = DVTValidator(address(new SingleStepOwnedFixture()));
    }

    function settleAggregatorGovernance() external {
        _settleAggregatorGovernance();
    }

    function owners() external view returns (address aggregatorOwner, address dvtOwner) {
        return (aggregator.owner(), dvt.owner());
    }
}

contract DeployNewBLSModulesGovernanceHarness is DeployNewBLSModules {
    function deployAndSettleOwnershipFixtures() external returns (address blsOwner, address dvtOwner) {
        BLSAggregator bls = BLSAggregator(address(new SingleStepOwnedFixture()));
        DVTValidator dvt = DVTValidator(address(new SingleStepOwnedFixture()));
        _settleGovernance(bls, dvt);
        return (bls.owner(), dvt.owner());
    }
}

contract DeployLiveGovernanceTest is Test {
    function test_DeployLiveTransfersAggregatorAndDVTToSameOwner() public {
        address governance = address(0xBEEF);
        vm.setEnv("GOVERNANCE_OWNER", vm.toString(governance));

        DeployLiveGovernanceHarness harness = new DeployLiveGovernanceHarness();
        harness.deployOwnershipFixtures();
        harness.settleAggregatorGovernance();

        (address aggregatorOwner, address dvtOwner) = harness.owners();
        assertEq(aggregatorOwner, governance);
        assertEq(dvtOwner, governance);
        assertEq(dvtOwner, aggregatorOwner);
    }

    function test_DeployNewBLSModulesTransfersAggregatorAndDVTToSameOwner() public {
        address governance = address(0xBEEF);
        vm.setEnv("GOVERNANCE_OWNER", vm.toString(governance));

        DeployNewBLSModulesGovernanceHarness harness = new DeployNewBLSModulesGovernanceHarness();
        (address blsOwner, address dvtOwner) = harness.deployAndSettleOwnershipFixtures();

        assertEq(blsOwner, governance);
        assertEq(dvtOwner, governance);
        assertEq(dvtOwner, blsOwner);
    }
}
