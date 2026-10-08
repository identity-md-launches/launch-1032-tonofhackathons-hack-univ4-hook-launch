// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "src/HackathonMachine.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Failure atomicity, independent consumers, and boundary conditions missing from the original suite.
contract AdversarialMachineTest is MachineFixture {
    function test_maximumMetadataIsMeasuredInBytesAndEntryPullsOnlyFromCaller() public {
        string memory name = unicode"éééééééééééééééééééééééééééééééé";
        assertEq(bytes(name).length, 64);
        imd.transfer(bob, 10 ether);
        vm.prank(bob);
        imd.approve(address(machine), 10 ether);
        uint256 payerBefore = imd.balanceOf(address(this));
        vm.prank(bob);
        uint256 id = machine.register(name, string(new bytes(200)), string(new bytes(64)), alice, address(hack));
        (address payout, address token, string memory savedName, string memory repo, string memory ref) =
            machine.entries(id);
        assertEq(payout, alice);
        assertEq(token, address(hack));
        assertEq(savedName, name);
        assertEq(bytes(repo).length, 200);
        assertEq(bytes(ref).length, 64);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.allowance(bob, address(machine)), 0);
        assertEq(imd.balanceOf(address(this)), payerBefore);
        assertEq(imd.balanceOf(alice), 0);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.register(string.concat(name, unicode"é"), "repo", "", bob, address(0));
        assertAccounting();
    }

    function test_invalidEntriesAndZeroFundingLeaveNoGhostState() public {
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.register("", "repo", "", alice, address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.register("name", "", "", alice, address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        enter(alice, bob); // An EOA cannot be a prize token.
        vm.expectRevert(HackathonMachine.Ineligible.selector);
        enter(address(machine), address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.fundRound(0);
        assertEq(machine.entryCount(machine.currentRound()), 0);
        assertFalse(machine.registered(machine.currentRound(), alice));
        assertEq(machine.sponsorship(machine.currentRound(), address(this)), 0);
        assertAccounting();
    }

    function test_failedEntryAndSponsorTransfersRollBackRoundAdvance() public {
        uint64 round = machine.currentRound();
        machine.fundRound(70 ether);
        closeRound();
        imd.setFailTransfers(true);
        bytes memory errorData = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd));
        vm.expectRevert(errorData);
        enter(alice, address(0));
        vm.expectRevert(errorData);
        machine.fundRound(11 ether);
        assertEq(machine.accountingRound(), round);
        assertEq(machine.openPot(), 70 ether);
        assertEq(machine.closingPot(), 0);
        assertEq(machine.entryCount(round + 1), 0);
        assertFalse(machine.registered(round + 1, alice));
        (address payout,,,,) = machine.entries((uint256(round + 1) << 32) | 1);
        assertEq(payout, address(0));
        assertEq(machine.sponsorship(round + 1, address(this)), 0);
        imd.setFailTransfers(false);
        uint256 id = enter(alice, address(0));
        assertEq(id, (uint256(round + 1) << 32) | 1);
        assertEq(machine.closingPot(), 70 ether);
        assertAccounting();
    }

    function test_failedKeeperPaymentDoesNotConsumeRequestOrSettleRound() public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(990 ether);
        closeRound();
        machine.advanceRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        imd.setFailTransfers(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        vm.prank(keeper);
        machine.submitResult(a, sig);
        assertFalse(machine.consumed(a.requestId));
        assertFalse(machine.settled(uint64(id >> 32)));
        assertEq(machine.lastWonRound(alice), 0);
        assertEq(machine.closingPot(), 1000 ether);
        assertEq(machine.openPot(), 0);
        assertEq(machine.streamLiability(), 0);
        (address payout,,,,) = machine.streams(id);
        assertEq(payout, address(0));
        assertEq(imd.balanceOf(keeper), 0);
        assertAccounting();
        imd.setFailTransfers(false);
        vm.prank(keeper);
        machine.submitResult(a, sig);
        assertTrue(machine.consumed(a.requestId));
        assertEq(imd.balanceOf(keeper), 10 ether);
        assertAccounting();
    }

    function test_failedFeeRedemptionPreservesClaimsAndCanBeRetried() public {
        seed();
        trade(true, true, 100 ether, 0);
        uint256 claimId = uint256(uint160(address(imd)));
        imd.setFailTransfers(true);
        vm.expectRevert(); // PoolManager wraps the failed ERC20 transfer.
        machine.redeemFeeClaims();
        assertEq(machine.feeClaims(), 2 ether);
        assertEq(manager.balanceOf(address(machine), claimId), 2 ether);
        assertEq(machine.liquidBalance(), 0);
        assertEq(machine.totalPot(), 2 ether);
        imd.setFailTransfers(false);
        vm.prank(bob);
        machine.redeemFeeClaims();
        machine.redeemFeeClaims();
        assertEq(imd.balanceOf(bob), 0);
        assertEq(machine.feeClaims(), 0);
        assertAccounting();
    }

    function test_everyOwnerOperationRefusesAnUnrelatedCaller() public {
        bytes[] memory calls = new bytes[](11);
        calls[0] = abi.encodeCall(machine.setQuestionHash, (keccak256("replacement")));
        calls[1] = abi.encodeCall(machine.setEntryFee, (20 ether));
        calls[2] = abi.encodeCall(machine.setWinnerBps, (8000));
        calls[3] = abi.encodeCall(machine.setPanelFloors, (5, 4));
        calls[4] = abi.encodeCall(machine.pauseEntries, (true));
        calls[5] = abi.encodeCall(machine.queueSigner, (bob));
        calls[6] = abi.encodeCall(machine.cancelSigner, ());
        calls[7] = abi.encodeCall(machine.queueDomainVersion, ("3"));
        calls[8] = abi.encodeCall(machine.cancelDomainVersion, ());
        calls[9] = abi.encodeCall(machine.queueDeny, (bob));
        calls[10] = abi.encodeCall(machine.removeDeny, (bob));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory result) = address(machine).call(calls[i]);
            assertFalse(ok, "unauthorized owner action succeeded");
            assertEq(result, abi.encodeWithSelector(HackathonMachine.Unauthorized.selector));
        }
        assertEq(machine.questionHash(), QUESTION);
        assertEq(machine.entryFee(), 10 ether);
        assertEq(machine.winnerBps(), 7000);
        assertEq(machine.minPanelSize(), 7);
        assertEq(machine.minAgreement(), 5);
        assertFalse(machine.entriesPaused());
        assertEq(machine.signerReadyAt(), 0);
        assertEq(machine.versionReadyAt(), 0);
        assertEq(machine.denyAt(bob), 0);
    }

    function test_adminRejectsInvalidOracleAndDenyConfiguration() public {
        vm.startPrank(owner);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.queueSigner(address(0));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.queueDomainVersion("");
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.queueDomainVersion(string(new bytes(33)));
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setPanelFloors(301, 5);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.setPanelFloors(5, 6);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.queueDeny(address(0));
        vm.expectRevert(HackathonMachine.NoPendingChange.selector);
        machine.removeDeny(alice);
        machine.queueDeny(alice);
        uint64 ready = machine.denyAt(alice);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        machine.queueDeny(alice);
        assertEq(machine.denyAt(alice), ready);
        vm.stopPrank();
    }

    function test_signatureCannotCrossConsumersEvenWithIdenticalEntriesAndQuestion() public {
        address at = address(uint160(0x400000) | FLAGS);
        deployCodeTo(
            "HackathonMachine.sol:HackathonMachine",
            abi.encode(manager, owner, address(this), address(hack), address(imd), vm.addr(SIGNER_KEY)),
            at
        );
        HackathonMachine other = HackathonMachine(at);
        vm.prank(owner);
        other.setQuestionHash(QUESTION);
        imd.approve(at, 10 ether);
        uint256 id = enter(alice, address(0));
        assertEq(
            other.register("Working builder", "https://github.com/builder/repo", "imd:project", alice, address(0)), id
        );
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        other.submitResult(a, sig);
        assertFalse(other.consumed(a.requestId));
        assertFalse(other.settled(uint64(id >> 32)));
        assertEq(other.totalPot(), 10 ether);
        machine.submitResult(a, sig); // The same attestation is otherwise valid.
        assertTrue(machine.consumed(a.requestId));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everySignedFieldIsAuthenticated(uint8 field) public {
        uint256 id = enter(alice, address(0));
        enter(bob, address(0));
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        uint8 choice = uint8(bound(field, 0, 14));
        if (choice == 0) a.requestId = keccak256("changed request");
        if (choice == 1) a.chainId = 2;
        if (choice == 2) a.questionHash = keccak256("changed question");
        if (choice == 3) a.answerType = 3;
        if (choice == 4) a.answer = abi.encode(bytes32(id + 1));
        if (choice == 5) a.figure = 1;
        if (choice == 6) a.fromBlock = 99;
        if (choice == 7) a.toBlock = 102;
        if (choice == 8) a.blockHash = keccak256("changed block");
        if (choice == 9) a.panelJobId = keccak256("changed panel");
        if (choice == 10) a.panelSize = 8;
        if (choice == 11) a.quorum = 6;
        if (choice == 12) a.agreed = 6;
        if (choice == 13) a.issuedAt -= 1;
        if (choice == 14) a.expiresAt -= 1;
        vm.expectRevert(); // Structural guards may reject before signature recovery.
        machine.submitResult(a, sig);
        assertFalse(machine.consumed(a.requestId));
        assertFalse(machine.settled(uint64(id >> 32)));
        assertEq(machine.totalPot(), 20 ether);
        assertEq(machine.streamLiability(), 0);
        a = attestation(id);
        machine.submitResult(a, sig);
        assertTrue(machine.consumed(a.requestId));
        assertAccounting();
    }

    function test_expiryBoundaryAndFutureTimestampTolerance() public {
        uint256 id = enter(alice, address(0));
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        a.issuedAt = uint64(vm.getBlockTimestamp() - 1);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        bytes memory sig = signature(a);
        uint256 snapshot = vm.snapshotState();
        machine.submitResult(a, sig);
        assertTrue(machine.consumed(a.requestId));
        assertTrue(vm.revertToState(snapshot));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        machine.submitResult(a, sig);
        a = attestation(id);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        sig = signature(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        machine.submitResult(a, sig);
        a.issuedAt -= 1;
        sig = signature(a);
        machine.submitResult(a, sig);
        assertTrue(machine.consumed(a.requestId));
    }

    function test_signedInvalidBlockWindowAndOversizePanelAreRejectedAtomically() public {
        uint256 id = enter(alice, address(0));
        closeRound();
        for (uint256 i; i < 4; ++i) {
            OracleAttestation.Attestation memory a = attestation(id);
            if (i == 0) a.fromBlock = a.toBlock + 1;
            if (i == 1) a.panelSize = 301;
            if (i == 2) a.expiresAt = a.issuedAt - 1;
            if (i == 3) a.answer = abi.encode(bytes32(id), bytes32(uint256(1)));
            bytes memory sig = signature(a);
            vm.expectRevert(HackathonMachine.InvalidResult.selector);
            machine.submitResult(a, sig);
            assertFalse(machine.consumed(a.requestId));
        }
        settle(id);
        assertAccounting();
    }

    function test_keeperRewardEdgesConserveEvenWhenTheMinimumConsumesThePot() public {
        uint256[6] memory pots = [uint256(1 ether), 5 ether - 1, 5 ether, 5 ether + 1, 500 ether - 1, 500 ether];
        uint256[6] memory rewards =
            [uint256(0.01 ether), (uint256(5 ether) - 1) / 100, 5 ether, 5 ether, 5 ether, 5 ether];
        for (uint256 i; i < pots.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(owner);
            machine.setEntryFee(1 ether);
            uint256 id = enter(alice, address(0));
            if (pots[i] > 1 ether) machine.fundRound(pots[i] - 1 ether);
            closeRound();
            settle(id);
            assertEq(imd.balanceOf(keeper), rewards[i]);
            assertEq(machine.totalPot() + machine.streamLiability(), pots[i] - rewards[i]);
            (, uint64 start,,,) = machine.streams(id);
            vm.warp(start + 28 days);
            uint256 entitlement = machine.streamLiability();
            assertEq(machine.claim(id), entitlement);
            assertAccounting();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_claimCadenceCannotCreateOrLosePrize(uint96 funding, uint32 first, uint32 second) public {
        uint256 id = enter(alice, address(0));
        machine.fundRound(bound(funding, 1, 1_000_000 ether));
        closeRound();
        settle(id);
        (, uint64 start,, uint256 total,) = machine.streams(id);
        uint256 t1 = bound(first, 0, 28 days);
        uint256 t2 = bound(second, t1, 28 days);
        vm.warp(start + t1);
        vm.prank(bob);
        uint256 paid = machine.claim(id);
        assertEq(machine.claim(id), 0);
        assertLe(paid * 28 days, total * t1);
        assertLt(total * t1 - paid * 28 days, 28 days);
        vm.warp(start + t2);
        paid += machine.claim(id);
        vm.warp(start + 28 days);
        paid += machine.claim(id);
        assertEq(paid, total);
        assertEq(imd.balanceOf(alice), total);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(machine.streamLiability(), 0);
        assertEq(machine.claim(id), 0);
        assertAccounting();
    }

    function test_denyRevokesOnlyOldStreamsAndCannotReviveThemAfterRemoval() public {
        uint256 oldId = enter(alice, address(0));
        closeRound();
        settle(oldId);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        machine.claim(oldId);
        uint256 alreadyPaid = imd.balanceOf(alice);
        uint256 unpaid = machine.streamLiability();
        vm.prank(owner);
        machine.queueDeny(alice);
        vm.warp(machine.denyAt(alice));
        vm.prank(owner);
        machine.removeDeny(alice);
        uint256 potBefore = machine.totalPot();
        assertEq(machine.claim(oldId), 0);
        assertEq(machine.totalPot(), potBefore + unpaid);
        machine.recycleDeniedStream(oldId);
        assertEq(machine.totalPot(), potBefore + unpaid);
        vm.warp(machine.roundClose(uint64(oldId >> 32) + 4));
        uint256 newId = enter(alice, address(0));
        closeRound();
        settle(newId);
        vm.prank(owner);
        machine.pauseEntries(true);
        (, uint64 start,, uint256 total,) = machine.streams(newId);
        vm.warp(start + 28 days);
        assertEq(machine.claim(newId), total);
        assertEq(machine.claim(oldId), 0);
        assertEq(imd.balanceOf(alice), alreadyPaid + total);
        assertAccounting();
    }
}
