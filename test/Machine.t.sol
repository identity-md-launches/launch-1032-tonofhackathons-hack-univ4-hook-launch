// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MachineTest is MachineFixture {
    function test_entrySponsorAndWeekBoundary() public {
        uint64 round = machine.currentRound();
        uint256 id = enter(alice, address(0));
        assertEq(id, (uint256(round) << 32) | 1);
        machine.fundRound(30 ether);
        assertEq(machine.sponsorship(round, address(this)), 30 ether);
        assertEq(machine.potForRound(round), 40 ether);
        vm.warp(machine.roundClose(round) - 1);
        enter(bob, address(0));
        vm.warp(machine.roundClose(round));
        uint256 nextId = enter(bob, address(0));
        assertEq(nextId >> 32, round + 1);
        assertEq(machine.closingPot(), 50 ether);
        assertEq(machine.openPot(), 10 ether);
        assertAccounting();
    }

    function test_entryValidationAndCallerOnlyTransfers() public {
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        enter(owner, address(0));
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        enter(address(0), address(0));
        enter(alice, address(0));
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        enter(alice, address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.register(string(new bytes(65)), "url", "ref", bob, address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.register("name", string(new bytes(201)), "ref", bob, address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.register("name", "url", string(new bytes(65)), bob, address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        enter(bob, address(imd));
        vm.prank(bob);
        vm.expectRevert();
        enter(bob, address(0)); // This contract's allowance does not let Bob charge it.
        assertEq(machine.entryCount(machine.currentRound()), 1);
        assertAccounting();
    }

    function test_settlementStreamingKeeperAndCarry() public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(990 ether);
        uint64 round = machine.currentRound();
        closeRound();
        enter(bob, address(0)); // New entries do not subsidize the closed week.
        settle(id);
        assertEq(imd.balanceOf(keeper), 10 ether);
        (address payout, uint64 start,, uint256 total, uint256 claimed) = machine.streams(id);
        assertEq(payout, alice);
        assertEq(total, 792 ether); // No token: 70% + 10% of 990.
        assertEq(claimed, 0);
        assertEq(machine.openPot(), 208 ether);
        assertTrue(machine.settled(round));
        assertEq(machine.claim(id), 0);
        vm.warp(start + 14 days);
        vm.prank(bob); // Permissionless caller, immutable recipient.
        assertEq(machine.claim(id), 396 ether);
        assertEq(imd.balanceOf(alice), 396 ether);
        vm.warp(start + 28 days);
        assertEq(machine.claim(id), 396 ether);
        assertEq(machine.claim(id), 0);
        assertEq(machine.streamLiability(), 0);
        assertAccounting();
    }

    function testFuzz_rewardMinimumAndAllocationConserve(uint96 funding, uint16 share) public {
        share = uint16(bound(share, 5000, 9000));
        vm.prank(owner);
        machine.setWinnerBps(share);
        uint256 id = enter(alice, address(0));
        uint256 amount = bound(funding, 1, 1_000_000 ether);
        machine.fundRound(amount);
        uint256 pot = machine.totalPot();
        closeRound();
        settle(id);
        uint256 reward = pot / 100;
        if (reward < 5 ether) reward = 5 ether;
        assertEq(imd.balanceOf(keeper), reward);
        assertEq(machine.totalPot() + machine.streamLiability() + reward, pot);
        assertAccounting();
    }

    function test_smallPotRewardIsOnePercentBelowFive() public {
        vm.prank(owner);
        machine.setEntryFee(1 ether);
        uint256 id = enter(alice, address(0));
        closeRound();
        settle(id);
        assertEq(imd.balanceOf(keeper), 0.01 ether);
        assertAccounting();
    }

    function test_roundAndRequestCannotSettleTwice() public {
        uint256 id = enter(alice, address(0));
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        machine.submitResult(a, sig);
        vm.expectRevert(HackathonMachine.RoundAlreadySettled.selector);
        machine.submitResult(a, sig);
        uint256 second = enter(bob, address(0));
        closeRound();
        OracleAttestation.Attestation memory b = attestation(second);
        b.requestId = a.requestId;
        sig = signature(b);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        machine.submitResult(b, sig);
    }

    function test_rolloverWholeAndStaleRoundCannotSettle() public {
        uint64 round = machine.currentRound();
        uint256 id = enter(alice, address(0));
        machine.fundRound(90 ether);
        closeRound();
        OracleAttestation.Attestation memory stale = attestation(id);
        bytes memory sig = signature(stale);
        uint256 next = enter(bob, address(0));
        closeRound();
        machine.advanceRound();
        assertEq(machine.closingPot(), 110 ether);
        assertFalse(machine.settled(round));
        vm.expectRevert(HackathonMachine.InvalidResult.selector);
        machine.submitResult(stale, sig);
        settle(next);
        assertAccounting();
    }

    function test_manySkippedWeeksRollWithoutLoops() public {
        enter(alice, address(0));
        machine.fundRound(90 ether);
        vm.warp(block.timestamp + 1000 weeks);
        machine.advanceRound();
        assertEq(machine.closingPot(), 100 ether);
        enter(bob, address(0));
        closeRound();
        assertEq(machine.potForRound(machine.currentRound() - 1), 110 ether);
        assertAccounting();
    }

    function test_winnerCooldownFourRoundsAndEarlyEntryCannotBypass() public {
        uint64 won = machine.currentRound();
        uint256 id = enter(alice, address(0));
        closeRound();
        uint256 preentered = enter(alice, address(0));
        settle(id);
        closeRound();
        OracleAttestation.Attestation memory a = attestation(preentered);
        bytes memory sig = signature(a);
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        machine.submitResult(a, sig);
        for (uint64 r = won + 2; r <= won + 4; ++r) {
            vm.warp(machine.roundClose(r - 1));
            vm.expectRevert(HackathonMachine.Ineligible.selector);
            enter(alice, address(0));
        }
        vm.warp(machine.roundClose(won + 4));
        enter(alice, address(0));
    }

    function test_pauseBlocksOnlyEntries() public {
        uint256 id = enter(alice, address(0));
        vm.prank(owner);
        machine.pauseEntries(true);
        vm.expectRevert(HackathonMachine.EntriesPaused.selector);
        enter(bob, address(0));
        machine.fundRound(100 ether);
        closeRound();
        settle(id);
        vm.warp(block.timestamp + 28 days);
        assertGt(machine.claim(id), 0);
        assertAccounting();
    }

    function test_denyDelayClaimsAndUnpaidRecycling() public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(990 ether);
        closeRound();
        settle(id);
        vm.prank(owner);
        machine.queueDeny(alice);
        uint64 at = machine.denyAt(alice);
        vm.warp(at - 1);
        assertFalse(machine.isDenied(alice));
        assertGt(machine.claim(id), 0);
        uint256 remaining = machine.streamLiability();
        uint256 pot = machine.totalPot();
        vm.warp(at);
        assertTrue(machine.isDenied(alice));
        machine.recycleDeniedStream(id);
        assertEq(machine.totalPot(), pot + remaining);
        assertEq(machine.streamLiability(), 0);
        assertEq(machine.claim(id), 0);
        assertAccounting();
    }

    function test_removingActiveDenyDoesNotRestoreUnpaidStream() public {
        uint256 id = enter(alice, address(0));
        closeRound();
        settle(id);
        vm.prank(owner);
        machine.queueDeny(alice);
        vm.warp(machine.denyAt(alice));
        vm.prank(owner);
        machine.removeDeny(alice);
        assertFalse(machine.isDenied(alice));
        assertEq(machine.claim(id), 0);
        assertEq(machine.streamLiability(), 0);
        assertAccounting();
    }

    function test_pendingDenyCanBeCancelledAndDeniedWinnerCannotSettle() public {
        uint256 id = enter(alice, address(0));
        vm.prank(owner);
        machine.queueDeny(alice);
        vm.prank(owner);
        machine.removeDeny(alice);
        vm.warp(block.timestamp + 2 days);
        assertFalse(machine.isDenied(alice));
        vm.prank(owner);
        machine.queueDeny(alice);
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        machine.submitResult(a, sig);
    }

    function test_falseReturnAndReentrancyCannotChangeAccounting() public {
        imd.setFailTransfers(true);
        vm.expectRevert();
        enter(alice, address(0));
        assertEq(machine.totalPot(), 0);
        imd.setFailTransfers(false);
        imd.setReenter(address(machine), abi.encodeCall(machine.fundRound, (1 ether)));
        uint256 id = enter(alice, address(0));
        assertFalse(imd.reentrySucceeded());
        closeRound();
        settle(id);
        assertFalse(imd.reentrySucceeded());
        vm.warp(block.timestamp + 28 days);
        imd.setFailTransfers(true);
        uint256 liability = machine.streamLiability();
        vm.expectRevert();
        machine.claim(id);
        assertEq(machine.streamLiability(), liability);
        imd.setFailTransfers(false);
        imd.setReenter(address(machine), abi.encodeCall(machine.claim, (id)));
        machine.claim(id);
        assertFalse(imd.reentrySucceeded());
        assertAccounting();
    }

    function test_donationsDoNotIncreaseInternalPot() public {
        imd.transfer(address(machine), 100 ether);
        assertEq(machine.totalPot(), 0);
        assertEq(machine.liquidBalance(), 0);
        assertEq(machine.streamLiability(), 0);
    }

    function test_adminCapsAndNoWithdrawal() public {
        vm.prank(alice);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.setEntryFee(20 ether);
        vm.startPrank(owner);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setEntryFee(100 ether + 1);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setEntryFee(1 ether - 1);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setWinnerBps(4999);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setWinnerBps(9001);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setPanelFloors(4, 4);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setPanelFloors(5, 3);
        machine.setPanelFloors(5, 4);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setQuestionHash(keccak256("other"));
        (bool success,) = address(machine).call(abi.encodeWithSignature("withdraw(address,uint256)", owner, 1 ether));
        assertFalse(success);
        vm.stopPrank();
    }

    function test_buyTokenAndFixedRecipient() public {
        seed();
        uint256 id = enter(alice, address(hack));
        uint256 rate = machine.Q96() * 9 / 10;
        vm.prank(alice);
        machine.configureBuy(id, key, rate);
        machine.fundRound(990 ether);
        closeRound();
        settle(id);
        (,,, uint256 total,) = machine.streams(id);
        assertEq(total, 693 ether);
        assertGt(hack.balanceOf(alice), 89 ether);
        assertEq(hack.balanceOf(keeper), 0);
        assertEq(machine.totalPot(), 199.98 ether); // Carry plus 2% hook fee on its own HACK purchase.
        assertEq(machine.feeClaims(), 0); // That fee remains liquid; no unnecessary claims round trip.
        assertAccounting();
    }

    function test_slippageFailureAddsBuyToStream() public {
        seed();
        uint256 id = enter(alice, address(hack));
        uint256 rate = machine.Q96() * 2;
        vm.prank(alice);
        machine.configureBuy(id, key, rate);
        machine.fundRound(990 ether);
        closeRound();
        settle(id);
        (,,, uint256 total,) = machine.streams(id);
        assertEq(total, 792 ether);
        assertEq(hack.balanceOf(alice), 0);
        assertAccounting();
    }

    function test_missingPoolConfigurationAddsBuyToStream() public {
        uint256 id = enter(alice, address(hack));
        machine.fundRound(990 ether);
        closeRound();
        settle(id);
        (,,, uint256 total,) = machine.streams(id);
        assertEq(total, 792 ether);
        assertAccounting();
    }

    function test_poolConfigCannotBeChangedAfterCloseOrByOthers() public {
        seed();
        uint256 id = enter(alice, address(hack));
        uint256 rate = machine.Q96();
        vm.prank(owner);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.configureBuy(id, key, rate);
        closeRound();
        vm.prank(alice);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.configureBuy(id, key, rate);
    }

    function test_falseReturnWinnerTokenFallsBackToStream() public {
        MockERC20 token = new MockERC20("Builder", "BUILD", 10_000_000 ether);
        PoolKey memory pool = pairKey(address(token), IHooks(address(0)));
        manager.initialize(pool, ONE);
        token.approve(address(liquidity), type(uint256).max);
        liquidity.modifyLiquidity(pool, ModifyLiquidityParams(-60000, 60000, 1_000_000 ether, 0), "");
        uint256 id = enter(alice, address(token));
        uint256 rate = machine.Q96() / 2;
        vm.prank(alice);
        machine.configureBuy(id, pool, rate);
        token.setFailTransfers(true);
        closeRound();
        settle(id);
        assertEq(token.balanceOf(alice), 0);
        (,,, uint256 total,) = machine.streams(id);
        assertEq(total, 4 ether);
        assertAccounting();
    }
}
