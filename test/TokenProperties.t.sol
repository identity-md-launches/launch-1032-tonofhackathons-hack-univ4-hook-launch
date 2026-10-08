// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HackToken} from "src/HackToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenTransferHandler is Test {
    HackToken public token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(HackToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("token holder ", vm.toString(i)));
        }
        expectedBalance[actors[0]] = 1_000_000_000 ether;
    }

    function transfer(uint8 fromIndex, uint8 toIndex, uint96 value) external {
        address from = actors[fromIndex % actors.length];
        address to = actors[toIndex % actors.length];
        uint256 amount = bound(value, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint8 ownerIndex, uint8 spenderIndex, uint256 amount) external {
        address holder = actors[ownerIndex % actors.length];
        address spender = actors[spenderIndex % actors.length];
        vm.prank(holder);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[holder][spender] = amount;
    }

    function transferFrom(uint8 ownerIndex, uint8 spenderIndex, uint8 toIndex, uint96 value) external {
        address holder = actors[ownerIndex % actors.length];
        address spender = actors[spenderIndex % actors.length];
        address to = actors[toIndex % actors.length];
        uint256 approved = expectedAllowance[holder][spender];
        uint256 available = expectedBalance[holder] < approved ? expectedBalance[holder] : approved;
        uint256 amount = bound(value, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, to, amount));
        expectedBalance[holder] -= amount;
        expectedBalance[to] += amount;
        if (approved != type(uint256).max) expectedAllowance[holder][spender] -= amount;
    }

    function overdraft(uint8 ownerIndex, uint8 spenderIndex) external {
        address holder = actors[ownerIndex % actors.length];
        address spender = actors[spenderIndex % actors.length];
        uint256 amount = expectedBalance[holder] + 1;
        uint256 approved = expectedAllowance[holder][spender];
        vm.prank(spender);
        if (amount > approved) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, holder, expectedBalance[holder], amount
                )
            );
        }
        token.transferFrom(holder, spender, amount);
    }

    function checkModel() external view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), expectedBalance[actors[i]]);
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), expectedAllowance[actors[i]][actors[j]]);
            }
        }
        assertEq(sum, 1_000_000_000 ether);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TokenPropertiesTest is Test {
    HackToken internal token;
    TokenTransferHandler internal handler;

    function setUp() public {
        token = new HackToken();
        handler = new TokenTransferHandler(token);
        assertTrue(token.transfer(handler.actors(0), token.totalSupply()));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.overdraft.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyBalancesAndAllowancesFollowERC20Operations() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        handler.checkModel();
    }

    function test_zeroTransferSelfTransferAndInfiniteApproval() public {
        address holder = handler.actors(0);
        address spender = handler.actors(1);
        uint256 supply = token.totalSupply();
        vm.startPrank(holder);
        assertTrue(token.transfer(spender, 0));
        assertTrue(token.transfer(holder, supply));
        assertTrue(token.approve(spender, type(uint256).max));
        vm.stopPrank();
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, spender, supply));
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(spender), token.totalSupply());
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferFailureRestoresTheAllowanceItWouldHaveSpent() public {
        address holder = handler.actors(0);
        address spender = handler.actors(1);
        uint256 supply = token.totalSupply();
        uint256 amount = supply + 1;
        vm.prank(holder);
        assertTrue(token.approve(spender, amount));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, supply, amount));
        token.transferFrom(holder, spender, amount);
        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.balanceOf(holder), token.totalSupply());
        assertEq(token.balanceOf(spender), 0);
    }
}
