// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HackToken} from "../src/HackToken.sol";

contract TokenTest is Test {
    function test_fixedSupplyMetadataAndTransfer() public {
        HackToken token = new HackToken();
        address recipient = makeAddr("recipient");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.name(), "TONOFHACKATHONS");
        assertEq(token.symbol(), "HACK");
        assertEq(token.decimals(), 18);
        assertTrue(token.transfer(recipient, 1 ether));
        assertEq(token.balanceOf(recipient), 1 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        bytes4[5] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("stake(uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSelector(selectors[i], recipient, 1 ether));
            assertFalse(success);
        }
    }
}
