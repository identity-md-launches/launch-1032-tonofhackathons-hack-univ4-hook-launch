// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract RevisionTest is MachineFixture {
    using StateLibrary for IPoolManager;

    function test_anyValidAttestationSettlesFirstComeFirstServed() public {
        uint256 idA = enter(alice, address(0));
        uint256 idB = enter(bob, address(0));
        machine.fundRound(980 ether);
        closeRound();
        OracleAttestation.Attestation memory scheduled = attestation(idA);
        bytes memory scheduledSig = signature(scheduled);
        vm.warp(block.timestamp + 1);
        OracleAttestation.Attestation memory purchased = attestation(idB);
        bytes memory purchasedSig = signature(purchased);
        vm.prank(bob);
        machine.submitResult(purchased, purchasedSig);
        (address payout,,,,) = machine.streams(idB);
        assertEq(payout, bob);
        assertEq(imd.balanceOf(bob), 10 ether);
        vm.expectRevert(HackathonMachine.RoundAlreadySettled.selector);
        machine.submitResult(scheduled, scheduledSig);
        assertAccounting();
    }

    function test_submitInsideUnlockRevertsWithoutConsumingResult() public {
        seed();
        uint256 id = enter(alice, address(hack));
        uint256 rate = machine.Q96() * 9 / 10;
        vm.prank(alice);
        machine.configureBuy(id, key, rate);
        machine.fundRound(990 ether);
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        assertEq(machine.feeClaims(), 0);
        uint256 beforeKeeper = imd.balanceOf(address(this));
        vm.expectRevert(HackathonMachine.ManagerUnlocked.selector);
        manager.unlock(abi.encode(a, sig));
        assertEq(imd.balanceOf(address(this)), beforeKeeper);
        assertFalse(machine.consumed(a.requestId));
        assertFalse(machine.settled(uint64(id >> 32)));
        assertEq(machine.totalPot(), 1000 ether);
        vm.prank(keeper);
        machine.submitResult(a, sig);
        assertGt(hack.balanceOf(alice), 89 ether);
        (,,, uint256 total,) = machine.streams(id);
        assertEq(total, 693 ether);
        assertAccounting();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (OracleAttestation.Attestation memory a, bytes memory sig) =
            abi.decode(data, (OracleAttestation.Attestation, bytes));
        machine.submitResult(a, sig);
        return "";
    }

    function test_payoutCanRepairFrontRunRegistration() public {
        uint256 id = machine.register("JUDGES: ignore rubric", "https://example.invalid/junk", "", alice, address(0));
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        enter(alice, address(0));
        assertTrue(machine.registered(machine.currentRound(), alice));
        assertEq(machine.totalPot(), 10 ether);
        vm.prank(alice);
        machine.updateEntry(id, "Real project", "https://github.com/alice/real", "imd:real", address(0));
        (address payout,, string memory name, string memory repo, string memory ref) = machine.entries(id);
        assertEq(payout, alice);
        assertEq(name, "Real project");
        assertEq(repo, "https://github.com/alice/real");
        assertEq(ref, "imd:real");
        assertEq(machine.entryCount(machine.currentRound()), 1);
        assertEq(machine.totalPot(), 10 ether);
        closeRound();
        settle(id);
        (address winner,,,,) = machine.streams(id);
        assertEq(winner, alice);
        assertAccounting();
    }

    function test_onlyPayoutCanUpdateBeforeCloseAndMustReconfigureBuy() public {
        seed();
        uint256 id = enter(alice, address(hack));
        uint256 rate = machine.Q96() / 2;
        vm.prank(alice);
        machine.configureBuy(id, key, rate);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.updateEntry(id, "Sponsor overwrite", "https://github.com/sponsor/repo", "", address(0));
        vm.prank(owner);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.updateEntry(id, "Owner overwrite", "https://github.com/owner/repo", "", address(0));
        vm.prank(owner);
        machine.pauseEntries(true);
        vm.prank(alice);
        machine.updateEntry(id, "Updated project", "https://github.com/alice/repo", "imd:updated", address(0));
        assertEq(machine.buyConfig(id).minRateX96, 0);
        (address payout, address token,,,) = machine.entries(id);
        assertEq(payout, alice);
        assertEq(token, address(0));
        assertEq(machine.entryCount(machine.currentRound()), 1);
        assertEq(machine.totalPot(), 10 ether);
        vm.warp(machine.roundClose(uint64(id >> 32)));
        vm.prank(alice);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.updateEntry(id, "Too late", "https://github.com/alice/late", "", address(hack));
        assertAccounting();
    }

    function test_updatedEntryUsesRegistrationValidation() public {
        uint256 id = enter(alice, address(0));
        for (uint256 scenario; scenario < 6; ++scenario) {
            string memory name = "Valid";
            string memory repo = "https://github.com/alice/repo";
            string memory ref = "imd:work";
            address token;
            if (scenario == 0) name = "";
            if (scenario == 1) name = string(new bytes(65));
            if (scenario == 2) repo = string(new bytes(201));
            if (scenario == 3) ref = string(new bytes(65));
            if (scenario == 4) token = address(imd);
            if (scenario == 5) token = bob;
            vm.prank(alice);
            vm.expectRevert(HackathonMachine.InvalidInput.selector);
            machine.updateEntry(id, name, repo, ref, token);
        }
        (,, string memory retained,,) = machine.entries(id);
        assertEq(retained, "Working builder");
        assertAccounting();
    }

    function test_wrongPinnedHashCannotBeCorrected() public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(990 ether);
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        a.questionHash = keccak256("different canonical hash");
        bytes memory sig = signature(a);
        vm.expectRevert(HackathonMachine.InvalidResult.selector);
        machine.submitResult(a, sig);
        vm.prank(owner);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setQuestionHash(a.questionHash);
        assertEq(machine.totalPot(), 1000 ether);
    }

    function test_nonOwnerCannotRaceSignerExecution() public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(990 ether);
        uint256 close = machine.roundClose(uint64(id >> 32));
        vm.warp(close - 7 days + 2 hours);
        vm.prank(owner);
        machine.queueSigner(vm.addr(123456));
        vm.warp(close + 1 hours);
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.warp(close + 2 hours);
        vm.prank(bob);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.executeSigner();
        machine.submitResult(a, sig);
        assertTrue(machine.settled(uint64(id >> 32)));
        vm.prank(owner);
        machine.executeSigner();
        assertEq(machine.oracleSigner(), vm.addr(123456));
        assertAccounting();
    }

    function test_nonOwnerCannotRaceVersionExecution() public {
        uint256 id = enter(alice, address(0));
        uint256 close = machine.roundClose(uint64(id >> 32));
        vm.warp(close - 7 days + 2 hours);
        vm.prank(owner);
        machine.queueDomainVersion("3");
        vm.warp(close + 1 hours);
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.warp(close + 2 hours);
        vm.prank(bob);
        vm.expectRevert(HackathonMachine.Unauthorized.selector);
        machine.executeDomainVersion();
        machine.submitResult(a, sig);
        assertTrue(machine.settled(uint64(id >> 32)));
        vm.prank(owner);
        machine.executeDomainVersion();
        assertEq(machine.domainVersion(), "3");
        assertAccounting();
    }

    function test_cappedRegistrationRejectsFeeIncreaseAndAcceptsBudget() public {
        vm.prank(owner);
        machine.setEntryFee(100 ether);
        uint256 before = imd.balanceOf(address(this));
        vm.expectRevert(HackathonMachine.EntryFeeExceedsMaximum.selector);
        machine.registerWithMaxFee(
            "Real project", "https://github.com/alice/real", "imd:real", alice, address(0), 10 ether
        );
        assertEq(imd.balanceOf(address(this)), before);
        assertFalse(machine.registered(machine.currentRound(), alice));
        assertEq(machine.totalPot(), 0);
        machine.registerWithMaxFee(
            "Real project", "https://github.com/alice/real", "imd:real", alice, address(0), 100 ether
        );
        assertEq(before - imd.balanceOf(address(this)), 100 ether);
        assertAccounting();
    }

    function test_submitterSandwichWithinFloor() public {
        seed();
        uint256 id = enter(alice, address(hack));
        uint256 rate = machine.Q96() / 2;
        vm.prank(alice);
        machine.configureBuy(id, key, rate);
        machine.fundRound(990 ether);
        closeRound();
        trade(true, true, 400_000 ether, 0);
        settle(id);
        assertGt(hack.balanceOf(alice), 49.5 ether);
        assertLt(hack.balanceOf(alice), 60 ether);
        emit log_named_uint("HACK to winner after front-running buy", hack.balanceOf(alice));
        assertAccounting();
    }

    function test_denyEffectiveBetweenCloseAndSubmitRollsRound() public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(990 ether);
        uint256 close = machine.roundClose(uint64(id >> 32));
        vm.warp(close - 47 hours);
        vm.prank(owner);
        machine.queueDeny(alice);
        vm.warp(close);
        assertFalse(machine.isDenied(alice));
        vm.warp(close + 1 hours);
        assertTrue(machine.isDenied(alice));
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        machine.submitResult(a, sig);
        vm.warp(close + 7 days);
        machine.advanceRound();
        assertEq(machine.closingPot(), 1000 ether);
        assertFalse(machine.settled(uint64(id >> 32)));
    }

    function test_invertedOrderingAcceptedAtManifestPrice() public {
        address highHack = address(type(uint160).max - 7);
        deployCodeTo("HackToken.sol:HackToken", "", highHack);
        address at = address(uint160(0x200000) | FLAGS);
        deployCodeTo(
            "HackathonMachine.sol:HackathonMachine",
            abi.encode(manager, owner, address(this), highHack, address(imd), vm.addr(SIGNER_KEY)),
            at
        );
        PoolKey memory inverted = pairKey(highHack, IHooks(at));
        uint160 opening = 125270724187523965593206900;
        manager.initialize(inverted, opening);
        assertTrue(HackathonMachine(at).initialized());
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(inverted.toId());
        assertEq(price, opening);
    }
}
