// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The factory receives the entire fixed supply and performs the launch allocation.
contract HackToken is ERC20 {
    constructor() ERC20("TONOFHACKATHONS", "HACK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
