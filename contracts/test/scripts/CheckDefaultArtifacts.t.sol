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

    /// These suites exercise deploy-script checks against profile.default (cancun) artifacts. Under
    /// `forge test --evm-version prague` (the Prague real-precompile gate) out/ holds prague builds, which
    /// DefaultArtifacts correctly refuses as "not a profile.default build" — so the suite skips itself
    /// there, the same way the precompile-dependent suites skip on Cancun. Detection = the EIP-2537 G1ADD
    /// precompile answers (identical to contracts/test/paper7/*).
    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }
    address constant SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;
    CheckDefaultArtifactsHarness checker;
    ArtifactFactoryFixture factory;
    TimelockController timelock;

    function setUp() public {
        if (_hasPraguePrecompiles()) vm.skip(true);
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
        APNTsCapped token = _capped(address(timelock));
        vm.prank(address(timelock));
        token.transferOwnership(address(0xBAD));
        assertEq(token.owner(), address(timelock));
        assertEq(token.pendingOwner(), address(0xBAD));
        _check(address(token), false);
    }

    function test_cappedToken_overIssued_rejected() public {
        APNTsCapped token = _capped(address(timelock));
        uint256 cap = token.cap();
        vm.prank(address(timelock));
        token.raiseCap(cap + 1);
        vm.startPrank(SAFE);
        token.mint(SAFE, cap + 1);
        token.lowerCap(cap);
        vm.stopPrank();
        assertEq(token.cap(), cap);
        assertGt(token.totalSupply(), cap);
        assertTrue(token.isOverIssued());
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
        APNTsCapped token = _capped(address(timelock));
        APNTsCapped wrongDomain = new APNTsCapped("Wrong name", "aPNTs", 10_000_000e18, address(timelock), SAFE, SAFE);
        // Only the masked EIP-712 immutables change; ERC20's name remains correct in storage.
        vm.etch(address(token), address(wrongDomain).code);
        assertEq(token.name(), "AAStar PNTs");
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AAStar PNTs"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertNotEq(token.DOMAIN_SEPARATOR(), expected);
        _check(address(token), false);
    }

    function test_cappedToken_wrongName_rejected() public {
        APNTsCapped token = new APNTsCapped("Wrong name", "aPNTs", 10_000_000e18, address(timelock), SAFE, SAFE);
        APNTsCapped correctDomain = _capped(address(timelock));
        vm.etch(address(token), address(correctDomain).code);
        assertEq(token.name(), "Wrong name");
        _check(address(token), false);
    }
}
