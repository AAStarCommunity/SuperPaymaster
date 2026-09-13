// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @dev Minimal declaration of the Halmos symbolic cheatcodes used by the D5c-1 harnesses
///      (selectors match halmos 0.3.3 `halmos/cheatcodes.py::halmos_cheat_code.handlers`).
///      Deliberately self-written instead of vendoring halmos-cheatcodes: the harness needs
///      only these few entries. The address is `address(uint160(uint256(keccak256("svm cheat code"))))`.
///      Under plain `forge test` these functions are never reached: every function that uses
///      them is named `check_*`, which forge does not run (forge only runs `test*` / `invariant*`).
interface HalmosSVM {
    function createUint256(string calldata name) external pure returns (uint256);
    function createUint(uint256 bitSize, string calldata name) external pure returns (uint256);
    function createAddress(string calldata name) external pure returns (address);
    function createBool(string calldata name) external pure returns (bool);
    function createBytes32(string calldata name) external pure returns (bytes32);
    function createBytes4(string calldata name) external pure returns (bytes4);
    /// @dev Symbolic calldata over every non-view function of `contractName` (plus the empty
    ///      and fallback-shaped inputs), as a single symbolic value that branches per selector.
    function createCalldata(string calldata contractName) external pure returns (bytes memory);
    function createCalldata(string calldata contractName, bool includeViewFunctions)
        external pure returns (bytes memory);
    function createCalldata(string calldata filename, string calldata contractName, bool includeViewFunctions)
        external pure returns (bytes memory);
    /// @dev Makes every storage slot of `target` an unconstrained symbol (arbitrary pre-state).
    function enableSymbolicStorage(address target) external;
}

abstract contract HalmosBase {
    HalmosSVM internal constant svm = HalmosSVM(0xF3993A62377BCd56AE39D773740A5390411E8BC9);

    /// @dev First four bytes of `data` (0 when shorter).
    function _sel(bytes memory data) internal pure returns (bytes4 s) {
        if (data.length < 4) return bytes4(0);
        assembly {
            s := and(mload(add(data, 32)), 0xffffffff00000000000000000000000000000000000000000000000000000000)
        }
    }
}
