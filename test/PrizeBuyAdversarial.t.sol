// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "src/HackathonMachine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract PrizeBuyAdversarialTest is MachineFixture {
    using StateLibrary for IPoolManager;

    MockERC20 internal prize;
    PoolKey internal prizePool;

    function setUp() public override {
        super.setUp();
        prize = new MockERC20("Builder prize token", "BUILD", 10_000_000 ether);
        prizePool = pairKey(address(prize), IHooks(address(0)));
        manager.initialize(prizePool, ONE);
        prize.approve(address(liquidity), type(uint256).max);
    }

    function seedPrize() internal {
        liquidity.modifyLiquidity(prizePool, ModifyLiquidityParams(-60000, 60000, 1_000_000 ether, 0), "");
    }

    function configuredEntry(uint256 rate) internal returns (uint256 id) {
        id = enter(alice, address(prize));
        vm.prank(alice);
        machine.configureBuy(id, prizePool, rate);
    }

    function test_successfulExternalPoolBuySpendsOwnFundsAndPaysOnlyWinner() public {
        seedPrize();
        uint256 rate = ONE * 9 / 10;
        uint256 id = configuredEntry(rate);
        machine.fundRound(990 ether);
        uint256 managerBefore = imd.balanceOf(address(manager));
        uint256 payerBefore = imd.balanceOf(address(this));
        uint256 prizeBefore = prize.balanceOf(address(manager));
        closeRound();
        settle(id);
        assertEq(imd.balanceOf(address(manager)) - managerBefore, 99 ether);
        assertEq(imd.balanceOf(address(this)), payerBefore);
        assertEq(prizeBefore - prize.balanceOf(address(manager)), prize.balanceOf(alice));
        assertGe(prize.balanceOf(alice) * ONE, 99 ether * rate);
        assertEq(prize.balanceOf(owner), 0);
        assertEq(prize.balanceOf(keeper), 0);
        assertEq(prize.balanceOf(address(machine)), 0);
        assertEq(machine.streamLiability(), 693 ether);
        assertEq(machine.totalPot(), 198 ether);
        assertEq(imd.balanceOf(keeper), 10 ether);
        assertEq(imd.allowance(address(machine), address(manager)), 0);
        assertAccounting();
    }

    function test_emptyPoolFallsBackWithoutSpendingAnyIMD() public {
        uint256 id = configuredEntry(ONE / 2);
        machine.fundRound(990 ether);
        closeRound();
        settle(id);
        assertFallback(id, 792 ether, 198 ether);
        assertEq(imd.balanceOf(address(manager)), 0);
    }

    function test_partialBuyRevertsAllPoolEffectsBeforeFallingBack() public {
        seedPrize();
        uint256 id = configuredEntry(ONE / 2);
        // The 10% buy is much larger than can fill within the 1% movement limit.
        machine.fundRound(999_990 ether);
        (uint160 priceBefore, int24 tickBefore,,) = IPoolManager(address(manager)).getSlot0(prizePool.toId());
        uint256 imdBefore = imd.balanceOf(address(manager));
        uint256 prizeBefore = prize.balanceOf(address(manager));
        closeRound();
        settle(id);
        assertFallback(id, 792_000 ether, 198_000 ether);
        (uint160 priceAfter, int24 tickAfter,,) = IPoolManager(address(manager)).getSlot0(prizePool.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(imd.balanceOf(address(manager)), imdBefore);
        assertEq(prize.balanceOf(address(manager)), prizeBefore);
    }

    function test_impossibleOutputFloorRollsBackTheSwapAndItsTransfers() public {
        seedPrize();
        uint256 id = configuredEntry(ONE * 2);
        machine.fundRound(990 ether);
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(prizePool.toId());
        uint256 imdBefore = imd.balanceOf(address(manager));
        uint256 prizeBefore = prize.balanceOf(address(manager));
        closeRound();
        settle(id);
        assertFallback(id, 792 ether, 198 ether);
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(prizePool.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(imd.balanceOf(address(manager)), imdBefore);
        assertEq(prize.balanceOf(address(manager)), prizeBefore);
    }

    function test_liquidityRemovedAfterConfigurationStillAllowsSettlement() public {
        seedPrize();
        uint256 id = configuredEntry(ONE / 2);
        liquidity.modifyLiquidity(prizePool, ModifyLiquidityParams(-60000, 60000, -1_000_000 ether, 0), "");
        closeRound();
        settle(id);
        assertFallback(id, 4 ether, 1 ether);
    }

    function test_prizeTokenCallbackCannotReenterOrClaimDuringSettlement() public {
        seedPrize();
        uint256 id = configuredEntry(ONE / 2);
        uint256 older = enter(bob, address(0));
        closeRound();
        settle(older);
        // Next week's winner tries to claim the preceding winner's vested stream from a token callback.
        id = configuredEntry(ONE / 2);
        machine.fundRound(990 ether);
        closeRound();
        uint256 oldLiability = machine.streamLiability();
        prize.setReenter(address(machine), abi.encodeCall(machine.claim, (older)));
        settle(id);
        assertFalse(prize.reentrySucceeded());
        assertEq(imd.balanceOf(bob), 0);
        assertGt(prize.balanceOf(alice), 0);
        assertGt(machine.streamLiability(), oldLiability);
        assertGt(machine.claim(older), 0);
        assertAccounting();
    }

    function test_invalidBuyConfigurationsCannotReplaceTheEntrantsCommitment() public {
        seedPrize();
        uint256 rate = ONE / 2;
        uint256 id = configuredEntry(rate);
        for (uint256 i; i < 5; ++i) {
            PoolKey memory bad = prizePool;
            uint256 minimum = rate;
            if (i == 0) minimum = 0;
            if (i == 1) bad = pairKey(address(hack), IHooks(address(0)));
            if (i == 2) bad.fee = 100_001;
            if (i == 3) bad.tickSpacing = 0;
            if (i == 4) (bad.currency0, bad.currency1) = (bad.currency1, bad.currency0);
            vm.prank(alice);
            vm.expectRevert(HackathonMachine.InvalidInput.selector);
            machine.configureBuy(id, bad, minimum);
        }
        PoolKey memory uninitialized = prizePool;
        uninitialized.fee = 3000;
        vm.prank(alice);
        vm.expectRevert(HackathonMachine.WrongPool.selector);
        machine.configureBuy(id, uninitialized, rate);
        HackathonMachine.BuyConfig memory saved = machine.buyConfig(id);
        assertEq(saved.minRateX96, rate);
        assertEq(abi.encode(saved.key), abi.encode(prizePool));
    }

    function assertFallback(uint256 id, uint256 stream, uint256 carry) internal view {
        (address payout,,, uint256 total,) = machine.streams(id);
        assertEq(payout, alice);
        assertEq(total, stream);
        assertEq(machine.totalPot(), carry);
        assertEq(prize.balanceOf(alice), 0);
        assertTrue(machine.settled(uint64(id >> 32)));
        assertAccounting();
    }
}
