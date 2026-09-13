#!/usr/bin/env python3
"""Measurement-only: GOV-2 (guardian + global pause + two-step base) applied to the UNSPLIT SP."""
import sys
p = sys.argv[1]
s = open(p).read()
def rep(a, b):
    global s
    assert a in s, a[:60]
    s = s.replace(a, b)
rep("""    uint256[25] private __gap;""", """    address public guardian;
    bool public paused;
    uint256[24] private __gap;
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event GlobalPauseSet(address indexed by, bool paused_);
    function setGuardian(address g) external onlyOwner { emit GuardianSet(guardian, g); guardian = g; }
    function setGlobalPaused(bool p) external {
        if (msg.sender != owner() && !(p && msg.sender == guardian)) revert Unauthorized();
        paused = p; emit GlobalPauseSet(msg.sender, p);
    }""")
rep("""    function setOperatorPaused(address operator, bool paused) external onlyOwner {
        operators[operator].isPaused = paused;
        if (paused) {""", """    function setOperatorPaused(address operator, bool p) external {
        if (msg.sender != owner() && !(p && msg.sender == guardian)) revert Unauthorized();
        operators[operator].isPaused = p;
        if (p) {""")
rep("""        // 1. Extract Operator
        address operator = _extractOperator(userOp);""", """        if (paused) return ("", _packValidationData(true, 0, 0));
        // 1. Extract Operator
        address operator = _extractOperator(userOp);""")
open(p, 'w').write(s)
