// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {DeployLive} from "../../script/v3/DeployLive.s.sol";
import {DeployNewBLSModules} from "../../script/v3/DeployNewBLSModules.s.sol";
import {BLSAggregator} from "../../src/modules/monitoring/BLSAggregator.sol";
import {DVTValidator} from "../../src/modules/monitoring/DVTValidator.sol";
import {Registry} from "../../src/core/Registry.sol";
import {ReputationSystem} from "../../src/modules/reputation/ReputationSystem.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

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
    address internal governanceForTest;

    function setGovernanceForTest(address g) external {
        governanceForTest = g;
    }

    function _governanceOwner() internal view override returns (address) {
        return governanceForTest;
    }

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

    /// @dev The Registry built the way DeployLive builds it: owner (and hence an initial reputation
    ///      source, Registry.sol:172) is the deployer, here this harness.
    function buildRegistryLikeDeployLive(address rep, address agg) external {
        deployer = address(this);
        registry = UUPSDeployHelper.deployRegistryProxy(deployer, address(0), address(0));
        repSystem = ReputationSystem(rep);
        aggregator = BLSAggregator(agg);
    }

    function wireReputationSources() external {
        _wireReputationSources();
    }

    function assertReputationSources() external view {
        _assertReputationSources();
    }

    function registryAddr() external view returns (Registry) {
        return registry;
    }
}

contract DeployNewBLSModulesGovernanceHarness is DeployNewBLSModules {
    address internal governanceForTest;

    function setGovernanceForTest(address g) external {
        governanceForTest = g;
    }

    function _governanceOwner() internal view override returns (address) {
        return governanceForTest;
    }

    function deployAndSettleOwnershipFixtures() external returns (address blsOwner, address dvtOwner) {
        BLSAggregator bls = BLSAggregator(address(new SingleStepOwnedFixture()));
        DVTValidator dvt = DVTValidator(address(new SingleStepOwnedFixture()));
        _settleGovernance(bls, dvt);
        return (bls.owner(), dvt.owner());
    }
}

contract DeployLiveGovernanceTest is Test {
    /// #633 review B1: DeployLive's reputation-source readback against a Registry initialised the
    /// way DeployLive initialises it. Without the deployer revocation the readback must fail.
    function test_DeployLiveReputationSourceReadbackPassesAfterWiring() public {
        DeployLiveGovernanceHarness h = new DeployLiveGovernanceHarness();
        h.buildRegistryLikeDeployLive(address(0x4E9), address(0xA66));
        assertTrue(h.registryAddr().isReputationSource(address(h)), "initialize made the deployer a source");
        vm.expectRevert(bytes("wire: registry.setReputationSource(repSystem)"));
        h.assertReputationSources();
        h.wireReputationSources();
        h.assertReputationSources();
        assertFalse(h.registryAddr().isReputationSource(address(h)), "deployer revoked");
        assertTrue(h.registryAddr().isReputationSource(address(0xA66)), "aggregator is a source");
    }

    function test_DeployLiveReputationSourceReadbackRejectsDeployerSource() public {
        DeployLiveGovernanceHarness h = new DeployLiveGovernanceHarness();
        h.buildRegistryLikeDeployLive(address(0x4E9), address(0xA66));
        Registry r = h.registryAddr();
        vm.startPrank(address(h));
        r.setReputationSource(address(0x4E9), true);
        r.setReputationSource(address(0xA66), true);
        vm.stopPrank();
        vm.expectRevert(bytes("wire: unexpected reputation source"));
        h.assertReputationSources();
    }

    function test_DeployLiveTransfersAggregatorAndDVTToSameOwner() public {
        address governance = address(0xBEEF);
        DeployLiveGovernanceHarness harness = new DeployLiveGovernanceHarness();
        harness.setGovernanceForTest(governance);
        harness.deployOwnershipFixtures();
        harness.settleAggregatorGovernance();

        (address aggregatorOwner, address dvtOwner) = harness.owners();
        assertEq(aggregatorOwner, governance);
        assertEq(dvtOwner, governance);
        assertEq(dvtOwner, aggregatorOwner);
    }

    function test_DeployNewBLSModulesTransfersAggregatorAndDVTToSameOwner() public {
        address governance = address(0xBEEF);
        DeployNewBLSModulesGovernanceHarness harness = new DeployNewBLSModulesGovernanceHarness();
        harness.setGovernanceForTest(governance);
        (address blsOwner, address dvtOwner) = harness.deployAndSettleOwnershipFixtures();

        assertEq(blsOwner, governance);
        assertEq(dvtOwner, governance);
        assertEq(dvtOwner, blsOwner);
    }
}
