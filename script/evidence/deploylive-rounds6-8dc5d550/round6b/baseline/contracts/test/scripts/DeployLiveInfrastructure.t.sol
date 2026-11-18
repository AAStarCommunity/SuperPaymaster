// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import {DeployLiveInputs} from "../../script/v3/DeployLiveInputs.sol";

contract InfrastructureHarness is DeployLiveInputs {
    function validate(address ep, address feed, address factory) external view {
        _validateInfrastructure(ep, feed, factory);
    }
}
contract DeployLiveInfrastructureTest is Test {
    InfrastructureHarness h;
    address ep = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address feed = address(100);
    address factory = address(101);
    address impl = address(102);
    function setUp() public {
        vm.warp(10000);
        h = new InfrastructureHarness();
        vm.etch(ep, hex"00"); vm.etch(feed, hex"00"); vm.etch(factory, hex"00"); vm.etch(impl, hex"00");
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        round(2000e8, block.timestamp);
        vm.mockCall(factory, abi.encodeWithSignature("accountImplementation()"), abi.encode(impl));
        vm.mockCall(impl, abi.encodeWithSignature("entryPoint()"), abi.encode(ep));
    }
    function round(int256 price, uint256 timestamp) internal {
        vm.mockCall(feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), price, timestamp, timestamp, uint80(1)));
    }
    function test_ValidInfrastructure() public view { h.validate(ep, feed, factory); }
    function test_EachRequiredContractNeedsCode() public {
        address[4] memory addresses = [ep, feed, factory, impl];
        for (uint256 i; i < addresses.length; ++i) {
            vm.etch(addresses[i], hex""); vm.expectRevert(); h.validate(ep, feed, factory);
            vm.etch(addresses[i], hex"00");
        }
    }
    function test_WrongEntryPoint() public {
        vm.expectRevert("DeployLive: EntryPoint v0.7"); h.validate(address(999), feed, factory);
    }
    function test_WrongFeedDecimals() public {
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert("DeployLive: feed decimals"); h.validate(ep, feed, factory);
    }
    function test_StaleZeroFutureAndNegativePrices() public {
        uint256[4] memory timestamps = [uint256(0), 5799, 10001, 10000];
        for (uint256 i; i < timestamps.length; ++i) {
            round(i == 3 ? int256(-1) : int256(2000e8), timestamps[i]);
            vm.expectRevert("DeployLive: stale/invalid feed"); h.validate(ep, feed, factory);
        }
        round(0, 10000); vm.expectRevert("DeployLive: stale/invalid feed"); h.validate(ep, feed, factory);
        round(2000e8, 5800); h.validate(ep, feed, factory);
    }
    function test_WrongAccountEntryPoint() public {
        vm.mockCall(impl, abi.encodeWithSignature("entryPoint()"), abi.encode(address(999)));
        vm.expectRevert("DeployLive: account EntryPoint"); h.validate(ep, feed, factory);
    }
    function test_FeedFailurePropagates() public {
        vm.mockCallRevert(feed, abi.encodeWithSignature("latestRoundData()"), "feed down");
        vm.expectRevert(); h.validate(ep, feed, factory);
    }
}
