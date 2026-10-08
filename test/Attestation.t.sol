// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract AttestationTest is MachineFixture {
    function test_forgedTamperedWrongDomainAndExpiredFail() public {
        uint256 id = enter(alice, address(0));
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        a.figure = 9;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        machine.submitResult(a, sig);
        a.figure = 0;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(999, machine.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        machine.submitResult(a, abi.encodePacked(r, s, v));
        a.expiresAt = uint64(block.timestamp - 1);
        a.issuedAt = uint64(block.timestamp - 2);
        sig = signature(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        machine.submitResult(a, sig);
        a = attestation(id);
        sig = signature(a);
        vm.chainId(2);
        a.chainId = 2;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        machine.submitResult(a, sig);
        assertFalse(machine.consumed(a.requestId));
        assertEq(machine.lastWonRound(alice), 0);
    }

    function test_signedButWrongQuestionTypePanelChainTimeOrEntryFail() public {
        uint256 id = enter(alice, address(0));
        closeRound();
        for (uint256 scenario; scenario < 13; ++scenario) {
            OracleAttestation.Attestation memory a = attestation(id);
            if (scenario == 0) a.questionHash = keccak256("other");
            if (scenario == 1) a.answerType = 3;
            if (scenario == 2) a.panelSize = 6;
            if (scenario == 3) a.quorum = 4;
            if (scenario == 4) a.agreed = 4;
            if (scenario == 5) a.agreed = 8;
            if (scenario == 6) a.chainId = 2;
            if (scenario == 7) a.issuedAt = uint64(machine.roundClose(uint64(id >> 32)) - 1);
            if (scenario == 8) a.issuedAt = uint64(block.timestamp + 301);
            if (scenario == 9) a.answer = abi.encode(bytes32(id + 1));
            if (scenario == 10) a.answer = abi.encode(bytes32(id + (1 << 32)));
            if (scenario == 11) a.quorum = 8;
            if (scenario == 12) a.answer = hex"01";
            bytes memory sig = signature(a);
            vm.expectRevert();
            machine.submitResult(a, sig);
        }
        assertAccounting();
    }

    function test_unsetQuestionFailsAndCanOnlyBePinnedOnce() public {
        // The fixture pins it; use a second correctly flagged hook to test the unset state.
        address at = address(uint160(0x200000) | FLAGS);
        deployCodeTo(
            "HackathonMachine.sol:HackathonMachine",
            abi.encode(manager, owner, address(this), address(hack), address(imd), vm.addr(SIGNER_KEY)),
            at
        );
        HackathonMachine other = HackathonMachine(at);
        uint256 id = enter(alice, address(0));
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.expectRevert(HackathonMachine.InvalidResult.selector);
        other.submitResult(a, sig);
        vm.prank(owner);
        other.setQuestionHash(QUESTION);
        vm.prank(owner);
        vm.expectRevert(HackathonMachine.InvalidInput.selector);
        other.setQuestionHash(QUESTION);
    }

    function testFuzz_queuedSignerHasNoEffectBeforeSevenDays(uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, 0, 7 days - 1));
        address old = machine.oracleSigner();
        address replacement = vm.addr(123456);
        uint256 queued = block.timestamp;
        vm.prank(owner);
        machine.queueSigner(replacement);
        vm.warp(queued + elapsed);
        assertEq(machine.oracleSigner(), old);
        vm.expectRevert(HackathonMachine.TooEarly.selector);
        vm.prank(owner);
        machine.executeSigner();
        assertEq(machine.oracleSigner(), old);
        vm.warp(queued + 7 days);
        vm.prank(owner);
        machine.executeSigner();
        assertEq(machine.oracleSigner(), replacement);
        vm.expectRevert(HackathonMachine.NoPendingChange.selector);
        vm.prank(owner);
        machine.executeSigner();
    }

    function test_signerCancellationRequeueAndSignatures() public {
        uint256 id = enter(alice, address(0));
        vm.prank(owner);
        machine.queueSigner(vm.addr(123456));
        closeRound();
        // The original signer still authorizes results while the change is pending.
        settle(id);
        vm.prank(owner);
        machine.cancelSigner();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(HackathonMachine.NoPendingChange.selector);
        vm.prank(owner);
        machine.executeSigner();
        vm.prank(owner);
        machine.queueSigner(vm.addr(123456));
        vm.warp(block.timestamp + 6 days);
        vm.prank(owner);
        machine.queueSigner(vm.addr(654321));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(HackathonMachine.TooEarly.selector);
        vm.prank(owner);
        machine.executeSigner();
    }

    function test_domainVersionChangesOnlyAfterSevenDaysAndCanCancel() public {
        uint256 id = enter(alice, address(0));
        OracleAttestation.Attestation memory a = attestation(id);
        bytes32 digest = machine.attestationDigest(a);
        vm.prank(owner);
        machine.queueDomainVersion("3");
        vm.warp(block.timestamp + 7 days - 1);
        assertEq(machine.domainVersion(), "2");
        assertEq(machine.attestationDigest(a), digest);
        vm.expectRevert(HackathonMachine.TooEarly.selector);
        vm.prank(owner);
        machine.executeDomainVersion();
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        machine.executeDomainVersion();
        assertEq(machine.domainVersion(), "3");
        assertNotEq(machine.attestationDigest(a), digest);
        (,, string memory version,,,,) = machine.eip712Domain();
        assertEq(version, "3");
        vm.prank(owner);
        machine.queueDomainVersion("4");
        vm.prank(owner);
        machine.cancelDomainVersion();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(HackathonMachine.NoPendingChange.selector);
        vm.prank(owner);
        machine.executeDomainVersion();
    }

    function test_oldKeyAndOldDomainCannotSettleAfterRotation() public {
        vm.startPrank(owner);
        machine.queueSigner(vm.addr(123456));
        machine.queueDomainVersion("3");
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        machine.executeSigner();
        uint256 id = enter(alice, address(0));
        closeRound();
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory oldKeySig = signature(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123456, machine.attestationDigest(a));
        bytes memory oldVersionSig = abi.encodePacked(r, s, v);
        vm.prank(owner);
        machine.executeDomainVersion();
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        machine.submitResult(a, oldKeySig);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        machine.submitResult(a, oldVersionSig);
        (v, r, s) = vm.sign(123456, machine.attestationDigest(a));
        machine.submitResult(a, abi.encodePacked(r, s, v));
        assertTrue(machine.consumed(a.requestId));
    }
}
