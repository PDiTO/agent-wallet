// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Call target that records what it received.
contract MockTarget {
    uint256 public pings;
    uint256 public lastValue;
    address public lastCaller;

    error Nope();

    function ping(uint256 n) external payable returns (uint256) {
        pings += n;
        lastValue = msg.value;
        lastCaller = msg.sender;
        return pings;
    }

    function other() external pure returns (uint256) {
        return 42;
    }

    function fail() external pure {
        revert Nope();
    }

    receive() external payable {}
}
