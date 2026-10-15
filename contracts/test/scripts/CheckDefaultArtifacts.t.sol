// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {APNTsCapped} from "../../src/tokens/APNTsCapped.sol";
import {xPNTsToken} from "../../src/tokens/xPNTsToken.sol";
import {CheckDefaultArtifacts} from "../../script/checks/CheckDefaultArtifacts.s.sol";

contract ArtifactFactoryFixture {
    address public implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }
}

contract CheckDefaultArtifactsHarness is CheckDefaultArtifacts {
    function checkAPNTs(address token, address factory, address timelock) external returns (uint256, uint256) {
        cfg = string.concat(
            '{"aPNTs":"',
            vm.toString(token),
            '","xPNTsFactory":"',
            vm.toString(factory),
            '","timelockController":"',
            vm.toString(timelock),
            '"}'
        );
        fails = 0;
        passes = 0;
        _classify("aPNTs");
        return (passes, fails);
    }

    function deployLegacyImplementation() external returns (address) {
        return _deployDefault("xPNTsToken", "");
    }
}

contract CheckDefaultArtifactsTest is Test {
    address constant SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;
    CheckDefaultArtifactsHarness checker;
    ArtifactFactoryFixture factory;
    TimelockController timelock;

    function setUp() public {
        vm.chainId(31337);
        checker = new CheckDefaultArtifactsHarness();
        factory = new ArtifactFactoryFixture(checker.deployLegacyImplementation());
        address[] memory safe = new address[](1);
        safe[0] = SAFE;
        timelock = new TimelockController(172800, safe, safe, address(0));
    }

    function _check(address token, bool shouldPass) internal {
        (uint256 passed, uint256 failed) = checker.checkAPNTs(token, address(factory), address(timelock));
        if (shouldPass) {
            assertGt(passed, 0);
            assertEq(failed, 0);
        } else {
            assertGt(failed, 0);
        }
    }

    function _capped(address owner) internal returns (APNTsCapped) {
        return new APNTsCapped("AAStar PNTs", "aPNTs", 10_000_000e18, owner, SAFE, SAFE);
    }

    function test_legacyClone_passes() public {
        _check(Clones.clone(factory.implementation()), true);
    }

    function test_cappedToken_passes() public {
        _check(address(_capped(address(timelock))), true);
    }

    function test_otherContract_rejected() public {
        _check(address(factory), false);
    }

    function test_legacyClone_wrongImplementation_rejected() public {
        _check(Clones.clone(address(new xPNTsToken())), false);
    }

    function test_cappedToken_wrongOwner_rejected() public {
        _check(address(_capped(address(this))), false);
    }

    function test_cappedToken_wrongCap_rejected() public {
        _check(address(new APNTsCapped("AAStar PNTs", "aPNTs", 1e18, address(timelock), SAFE, SAFE)), false);
    }

    function test_cappedToken_wrongMinter_rejected() public {
        _check(
            address(new APNTsCapped("AAStar PNTs", "aPNTs", 10_000_000e18, address(timelock), address(0xBAD), SAFE)),
            false
        );
    }

    function test_cappedToken_pendingHandover_rejected() public {
        APNTsCapped token = _capped(address(this));
        token.transferOwnership(address(timelock));
        _check(address(token), false);
    }

    function test_cappedToken_wrongTimelockDelay_rejected() public {
        address[] memory safe = new address[](1);
        safe[0] = SAFE;
        timelock = new TimelockController(1, safe, safe, address(0));
        _check(address(_capped(address(timelock))), false);
    }

    function test_cappedToken_changedRuntime_rejected() public {
        APNTsCapped token = _capped(address(timelock));
        bytes memory code = address(token).code;
        code[0] = bytes1(uint8(code[0]) ^ 1);
        vm.etch(address(token), code);
        _check(address(token), false);
    }

    function test_legacyClone_wrongRuntime_rejected() public {
        vm.etch(factory.implementation(), address(factory).code);
        _check(Clones.clone(factory.implementation()), false);
    }

    function test_cappedToken_wrongGuardian_rejected() public {
        _check(
            address(new APNTsCapped("AAStar PNTs", "aPNTs", 10_000_000e18, address(timelock), SAFE, address(0xBAD))),
            false
        );
    }

    function test_cappedToken_wrongNameAndPermitDomain_rejected() public {
        _check(address(new APNTsCapped("Wrong name", "aPNTs", 10_000_000e18, address(timelock), SAFE, SAFE)), false);
    }
}
