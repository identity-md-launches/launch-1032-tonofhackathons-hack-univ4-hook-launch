// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract HookTest is MachineFixture {
    using StateLibrary for IPoolManager;

    function test_initializationAndPermissions() public {
        Hooks.Permissions memory p = machine.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertEq(HookFlags.flagsOf(address(machine)), FLAGS);
        manager.initialize(key, ONE);
        assertTrue(machine.initialized());
        assertLe(address(machine).code.length, 24576);
    }

    function test_everyCallbackAuthenticatesManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, ONE / 2);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.beforeInitialize(address(this), key, ONE);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.beforeSwap(address(this), key, params, "");
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.unlockCallback(abi.encode(uint8(1), uint256(0), uint256(1 ether)));
        vm.prank(address(manager));
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.unlockCallback(abi.encode(uint8(1), uint256(0), uint256(1 ether)));
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.buyWinnerToken(1, 1 ether);
    }

    function test_onlyFactoryCanInitializeOnlyLaunchPair() public {
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(key, ONE);
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, ONE);
        manager.initialize(key, ONE);
        bad.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(bad, ONE);
    }

    function testFuzz_fourSwapModesCollectOnlyIMD(bool buy, bool exactInput, uint96 input) public {
        seed();
        uint256 amount = bound(input, 1 ether, 1000 ether);
        BalanceDelta d = trade(buy, exactInput, amount, 0);
        int128 imdDelta = Currency.unwrap(key.currency0) == address(imd) ? d.amount0() : d.amount1();
        uint256 fee = machine.feeClaims();
        if (buy && exactInput) {
            assertEq(fee, amount * 200 / 10000);
            assertEq(int256(imdDelta), -int256(amount));
        } else if (!buy && !exactInput) {
            assertEq(fee, (amount * 200 + 9799) / 9800);
            assertEq(uint256(uint128(imdDelta)), amount);
        } else {
            uint256 base = buy ? uint256(-int256(imdDelta)) - fee : uint256(uint128(imdDelta)) + fee;
            assertEq(fee, base * 200 / 10000);
        }
        assertGt(fee, 0);
        assertEq(hack.balanceOf(address(machine)), 0);
        assertEq(imd.balanceOf(address(machine)), 0);
        assertEq(machine.totalPot(), fee);
        machine.redeemFeeClaims();
        assertEq(imd.balanceOf(address(machine)), fee);
        assertAccounting();
    }

    function test_freshManagerWithOnlyHackLiquidityCanBuy() public {
        manager.initialize(key, ONE);
        bool imdIs0 = Currency.unwrap(key.currency0) == address(imd);
        liquidity.modifyLiquidity(
            key,
            imdIs0
                ? ModifyLiquidityParams(-120, -60, 100_000 ether, 0)
                : ModifyLiquidityParams(60, 120, 100_000 ether, 0),
            ""
        );
        assertEq(imd.balanceOf(address(manager)), 0);
        trade(true, true, 10 ether, 0);
        assertEq(machine.feeClaims(), 0.2 ether);
        machine.redeemFeeClaims();
        assertAccounting();
    }

    function test_partialSellChargesExecutedOutput() public {
        seed();
        bool zeroForOne = Currency.unwrap(key.currency0) != address(imd);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        BalanceDelta d = trade(false, true, 100_000 ether, limit);
        int128 hackDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 imdDelta = zeroForOne ? d.amount1() : d.amount0();
        assertLt(uint256(-int256(hackDelta)), 100_000 ether);
        uint256 gross = uint256(uint128(imdDelta)) + machine.feeClaims();
        assertEq(machine.feeClaims(), gross * 200 / 10000);
        assertAccounting();
    }

    function test_partialSpecifiedIMDSwapRevertsWithoutTakingFee() public {
        seed();
        bool imdIs0 = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(-60) : int24(60));
        vm.expectRevert();
        trade(true, true, 100_000 ether, limit);
        assertEq(machine.feeClaims(), 0);
        limit = TickMath.getSqrtPriceAtTick(imdIs0 ? int24(60) : int24(-60));
        vm.expectRevert();
        trade(false, false, 100_000 ether, limit);
        assertEq(machine.feeClaims(), 0);
    }

    function test_unknownPoolAndForgedHookDataCannotStealApprovals() public {
        seed();
        uint256 balanceBefore = imd.balanceOf(alice);
        SwapParams memory params = SwapParams(
            Currency.unwrap(key.currency0) == address(imd),
            -1 ether,
            Currency.unwrap(key.currency0) == address(imd) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        // Arbitrary hook data has no payer semantics; the router settles only its caller's funds.
        swapper.swap(key, params, swapperSettings(), abi.encode(alice, type(uint256).max));
        assertEq(imd.balanceOf(alice), balanceBefore);
        PoolKey memory bad = key;
        bad.fee = 1;
        vm.prank(address(manager));
        vm.expectRevert(HackathonMachine.WrongPool.selector);
        machine.beforeSwap(alice, bad, params, "");
    }

    function swapperSettings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }
}

import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Repeat real-manager swap coverage with the opposite IMD currency ordering.
contract ReverseOrderHookTest is HookTest {
    function setUp() public override {
        super.setUp();
        bool wasFirst = address(imd) < address(hack);
        address newImd = wasFirst ? address(type(uint160).max - 1) : address(uint160(0x10000000));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("IdentityMD", "IMD", 1_000_000_000 ether), newImd);
        imd = MockERC20(newImd);
        address newHook = address(uint160(0x300000) | FLAGS);
        deployCodeTo(
            "HackathonMachine.sol:HackathonMachine",
            abi.encode(manager, owner, address(this), address(hack), newImd, vm.addr(SIGNER_KEY)),
            newHook
        );
        machine = HackathonMachine(newHook);
        key = pairKey(address(hack), IHooks(newHook));
        imd.approve(address(machine), type(uint256).max);
        imd.approve(address(swapper), type(uint256).max);
        imd.approve(address(liquidity), type(uint256).max);
        vm.prank(owner);
        machine.setQuestionHash(QUESTION);
        assertTrue(wasFirst != (address(imd) < address(hack)));
    }
}
