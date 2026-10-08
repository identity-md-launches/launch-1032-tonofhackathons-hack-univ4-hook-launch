// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    bool public failTransfers;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        if (reenterTarget != address(0)) {
            (bool success,) = reenterTarget.call(reenterData);
            reentrySucceeded = success;
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        if (reenterTarget != address(0)) {
            (bool success,) = reenterTarget.call(reenterData);
            reentrySucceeded = success;
        }
        return super.transferFrom(from, to, amount);
    }
}
