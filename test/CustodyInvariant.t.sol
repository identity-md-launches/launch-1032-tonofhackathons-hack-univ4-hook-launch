// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "src/HackathonMachine.sol";
import {HackToken} from "src/HackToken.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Multi-actor accounting model. Pool spending is measured from IMD Transfer logs,
/// not inferred as the unexplained remainder of the machine's asset balance.
contract CustodyHandler is Test {
    uint256 internal constant SIGNER_KEY = 0xA77E57;
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    HackathonMachine public machine;
    MockERC20 public imd;
    HackToken public hack;
    PoolSwapTest public swapper;
    PoolKey internal key;
    address[8] public builders;
    address[3] public sponsors;
    address[2] public keepers;
    uint256 public funded;
    uint256 public donated;
    uint256 public swapFees;
    uint256 public keeperPaid;
    uint256 public winnersPaid;
    uint256 public poolsPaid;
    uint256 public settlements;
    uint256 public versionNumber = 2;
    uint256 public pendingVersion;
    uint256 public versionReady;
    uint256[] public winners;
    mapping(uint256 => address) public entrant;
    mapping(uint256 => uint256) public awarded;
    mapping(uint64 => uint256) public settlementCount;
    mapping(address => uint256) public received;
    mapping(uint64 => mapping(address => uint256)) public sponsored;

    constructor(
        HackathonMachine machine_,
        MockERC20 imd_,
        HackToken hack_,
        PoolSwapTest swapper_,
        PoolKey memory key_
    ) {
        machine = machine_;
        imd = imd_;
        hack = hack_;
        swapper = swapper_;
        key = key_;
        for (uint256 i; i < builders.length; ++i) {
            builders[i] = makeAddr(string.concat("custody builder ", vm.toString(i)));
        }
        for (uint256 i; i < sponsors.length; ++i) {
            sponsors[i] = makeAddr(string.concat("custody sponsor ", vm.toString(i)));
            imd.mint(sponsors[i], 10_000_000 ether);
            vm.prank(sponsors[i]);
            imd.approve(address(machine), type(uint256).max);
        }
        for (uint256 i; i < keepers.length; ++i) {
            keepers[i] = makeAddr(string.concat("custody keeper ", vm.toString(i)));
        }
        imd.mint(address(this), 10_000_000 ether);
        imd.approve(address(swapper), type(uint256).max);
    }

    function fund(uint8 who, uint96 value) public {
        address payer = sponsors[who % sponsors.length];
        uint256 amount = bound(value, 1, 1000 ether);
        uint64 round = machine.currentRound();
        vm.recordLogs();
        vm.prank(payer);
        machine.fundRound(amount);
        _auditOutflows(address(0), false, false);
        funded += amount;
        sponsored[round][payer] += amount;
        assertEq(machine.sponsorship(round, payer), sponsored[round][payer]);
    }

    function registerEntry(uint8 who, bool buy) public {
        address payout = builders[who % builders.length];
        address payer = sponsors[who % sponsors.length];
        uint64 round = machine.currentRound();
        uint64 last = machine.lastWonRound(payout);
        if (machine.entriesPaused()) {
            vm.expectRevert(HackathonMachine.EntriesPaused.selector);
        } else if (machine.registered(round, payout) || machine.isDenied(payout) || (last != 0 && round <= last + 4)) {
            vm.expectRevert(HackathonMachine.Ineligible.selector);
        } else {
            uint256 fee = machine.entryFee();
            uint32 countBefore = machine.entryCount(round);
            vm.recordLogs();
            vm.prank(payer);
            uint256 id = machine.register(
                "Builder", "https://github.com/build/repo", "imd:build", payout, buy ? address(hack) : address(0)
            );
            _auditOutflows(address(0), false, false);
            assertEq(id, (uint256(round) << 32) | (uint256(countBefore) + 1));
            assertEq(entrant[id], address(0));
            entrant[id] = payout;
            funded += fee;
            if (buy) {
                vm.prank(payout);
                machine.configureBuy(id, key, (uint256(1) << 96) / 2);
            }
            return;
        }
        vm.prank(payer);
        machine.register(
            "Builder", "https://github.com/build/repo", "imd:build", payout, buy ? address(hack) : address(0)
        );
    }

    function donate(uint96 value) public {
        uint256 amount = bound(value, 1, 100 ether);
        uint256 potBefore = machine.totalPot();
        uint256 liabilityBefore = machine.streamLiability();
        assertTrue(imd.transfer(address(machine), amount));
        donated += amount;
        assertEq(machine.totalPot(), potBefore);
        assertEq(machine.streamLiability(), liabilityBefore);
    }

    function trade(uint96 value) public {
        uint256 amount = bound(value, 50, 10 ether);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint256 claimsBefore = machine.feeClaims();
        swapper.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(machine.feeClaims() - claimsBefore, amount / 50);
        swapFees += amount / 50;
    }

    function redeem() public {
        uint256 potBefore = machine.totalPot();
        uint256 liabilityBefore = machine.streamLiability();
        vm.recordLogs();
        machine.redeemFeeClaims();
        _auditOutflows(address(0), false, false);
        assertEq(machine.totalPot(), potBefore);
        assertEq(machine.streamLiability(), liabilityBefore);
    }

    function advance(uint32 secondsForward) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 1, 9 days));
        machine.advanceRound();
    }

    function settle(uint32 choice, uint8 keeperChoice) public {
        uint64 round = machine.currentRound() - 1;
        uint32 count = machine.entryCount(round);
        if (count == 0) return;
        uint256 id = (uint256(round) << 32) | (uint256(choice) % count + 1);
        address payout = entrant[id];
        address submitter = keepers[keeperChoice % keepers.length];
        OracleAttestation.Attestation memory a = _attestation(id);
        bytes memory sig = _sign(a, SIGNER_KEY);
        if (machine.settled(round)) {
            vm.expectRevert(HackathonMachine.RoundAlreadySettled.selector);
            machine.submitResult(a, sig);
            return;
        }
        uint64 last = machine.lastWonRound(payout);
        if (machine.isDenied(payout) || (last != 0 && round <= last + 4)) {
            vm.expectRevert(HackathonMachine.Ineligible.selector);
            machine.submitResult(a, sig);
            return;
        }
        uint256 tokensBefore = hack.balanceOf(payout);
        uint256 poolsBefore = poolsPaid;
        uint256 potBefore = machine.closingPot();
        vm.recordLogs();
        vm.prank(submitter);
        machine.submitResult(a, sig);
        _auditOutflows(submitter, false, true);
        if (poolsPaid > poolsBefore) {
            // A pool payment must have purchased the committed token for this winner.
            assertGt(hack.balanceOf(payout), tokensBefore);
            assertLe(poolsPaid - poolsBefore, potBefore / 10);
        }
        assertEq(settlementCount[round], 0, "round settled a second time");
        ++settlementCount[round];
        ++settlements;
        winners.push(id);
        (address recipient,,, uint256 total,) = machine.streams(id);
        assertEq(recipient, payout);
        awarded[id] = total;
        assertTrue(machine.consumed(a.requestId));
    }

    function claim(uint32 choice) public {
        if (winners.length == 0) return;
        uint256 id = winners[uint256(choice) % winners.length];
        address payout = entrant[id];
        uint256 beforeBalance = imd.balanceOf(payout);
        vm.recordLogs();
        uint256 amount = machine.claim(id);
        _auditOutflows(payout, true, false);
        assertEq(imd.balanceOf(payout) - beforeBalance, amount);
    }

    function deny(uint8 who) public {
        address payout = builders[who % builders.length];
        bool queued = machine.denyAt(payout) != 0;
        vm.prank(machine.owner());
        if (!queued) machine.queueDeny(payout);
        else machine.removeDeny(payout); // Exercises both pending cancellation and active removal.
    }

    function recycle(uint32 choice) public {
        if (winners.length == 0) return;
        uint256 id = winners[uint256(choice) % winners.length];
        (address payout,, uint64 generation, uint256 total, uint256 claimed) = machine.streams(id);
        if (!machine.isDenied(payout) && generation == machine.denyGeneration(payout)) {
            vm.expectRevert(HackathonMachine.Ineligible.selector);
            machine.recycleDeniedStream(id);
            return;
        }
        uint256 potBefore = machine.totalPot();
        uint256 liabilityBefore = machine.streamLiability();
        vm.recordLogs();
        machine.recycleDeniedStream(id);
        _auditOutflows(address(0), false, false);
        assertEq(machine.totalPot() - potBefore, total - claimed);
        assertEq(liabilityBefore - machine.streamLiability(), total - claimed);
    }

    function configure(uint8 operation, uint16 value, bool paused) public {
        vm.startPrank(machine.owner());
        if (operation % 3 == 0) machine.pauseEntries(paused);
        if (operation % 3 == 1) machine.setEntryFee(bound(value, 1, 100) * 1 ether);
        if (operation % 3 == 2) machine.setWinnerBps(uint16(bound(value, 5000, 9000)));
        vm.stopPrank();
    }

    function rotateVersion(uint8 operation) public {
        if (operation % 3 == 0) {
            pendingVersion = versionNumber + 1;
            versionReady = vm.getBlockTimestamp() + 7 days;
            vm.prank(machine.owner());
            machine.queueDomainVersion(vm.toString(pendingVersion));
        } else if (operation % 3 == 1) {
            vm.prank(machine.owner());
            machine.cancelDomainVersion();
            pendingVersion = 0;
            versionReady = 0;
        } else {
            if (versionReady == 0) {
                vm.expectRevert(HackathonMachine.NoPendingChange.selector);
            } else if (vm.getBlockTimestamp() < versionReady) {
                vm.expectRevert(HackathonMachine.TooEarly.selector);
            } else {
                versionNumber = pendingVersion;
                pendingVersion = 0;
                versionReady = 0;
            }
            machine.executeDomainVersion();
        }
    }

    function rejectResult(uint32 choice, bool stale) public {
        uint64 round = machine.currentRound() - 1;
        uint32 count = machine.entryCount(round);
        if (count == 0 || machine.settled(round)) return;
        uint256 id = (uint256(round) << 32) | (uint256(choice) % count + 1);
        OracleAttestation.Attestation memory a = _attestation(id);
        a.requestId = keccak256(abi.encode("rejected", id));
        if (stale) a.issuedAt = uint64(machine.roundClose(round) - 1);
        bytes memory sig = _sign(a, stale ? SIGNER_KEY : SIGNER_KEY + 1);
        uint256 potBefore = machine.totalPot();
        vm.expectRevert();
        machine.submitResult(a, sig);
        assertFalse(machine.consumed(a.requestId));
        assertFalse(machine.settled(round));
        assertEq(machine.totalPot(), potBefore);
    }

    function _auditOutflows(address recipient, bool winnerPayment, bool allowPool) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory item = logs[i];
            if (item.emitter != address(imd) || item.topics.length != 3 || item.topics[0] != TRANSFER) continue;
            if (address(uint160(uint256(item.topics[1]))) != address(machine)) continue;
            address to = address(uint160(uint256(item.topics[2])));
            uint256 amount = abi.decode(item.data, (uint256));
            if (allowPool && to == address(machine.poolManager())) {
                poolsPaid += amount;
            } else {
                assertTrue(recipient != address(0), "an operation unexpectedly paid IMD");
                assertEq(to, recipient, "IMD paid to an unauthorized recipient");
                received[to] += amount;
                if (winnerPayment) winnersPaid += amount;
                else keeperPaid += amount;
            }
        }
    }

    function _attestation(uint256 id) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("custody result", id));
        a.chainId = 1;
        a.questionHash = machine.questionHash();
        a.answerType = 2;
        a.answer = abi.encode(bytes32(id));
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.fromBlock = 100;
        a.toBlock = 101;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 signerKey) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, machine.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function checkStreamsAndRecipients() external view {
        uint256 unpaid;
        for (uint256 i; i < winners.length; ++i) {
            uint256 id = winners[i];
            (address payout,,, uint256 total, uint256 claimed) = machine.streams(id);
            assertEq(payout, entrant[id]);
            assertLe(claimed, total);
            assertLe(total, awarded[id]);
            unpaid += total - claimed;
            assertEq(settlementCount[uint64(id >> 32)], 1);
            assertTrue(machine.settled(uint64(id >> 32)));
        }
        assertEq(unpaid, machine.streamLiability());
        for (uint256 i; i < builders.length; ++i) {
            assertEq(imd.balanceOf(builders[i]), received[builders[i]]);
        }
        for (uint256 i; i < keepers.length; ++i) {
            assertEq(imd.balanceOf(keepers[i]), received[keepers[i]]);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract CustodyInvariantTest is MachineFixture {
    CustodyHandler internal custody;

    function setUp() public override {
        super.setUp();
        seed();
        custody = new CustodyHandler(machine, imd, hack, swapper, key);
        // Every campaign starts with live streams, a real prize buy and a payment.
        // This makes the liability and permitted-outflow properties non-vacuous.
        custody.fund(0, 990 ether);
        custody.registerEntry(0, false);
        custody.advance(7 days);
        custody.settle(0, 0);
        custody.registerEntry(1, true);
        custody.advance(7 days);
        custody.settle(0, 1);
        custody.claim(0);
        custody.registerEntry(2, false);
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = custody.fund.selector;
        selectors[1] = custody.registerEntry.selector;
        selectors[2] = custody.donate.selector;
        selectors[3] = custody.trade.selector;
        selectors[4] = custody.redeem.selector;
        selectors[5] = custody.advance.selector;
        selectors[6] = custody.settle.selector;
        selectors[7] = custody.claim.selector;
        selectors[8] = custody.deny.selector;
        selectors[9] = custody.recycle.selector;
        selectors[10] = custody.configure.selector;
        selectors[11] = custody.rotateVersion.selector;
        selectors[12] = custody.rejectResult.selector;
        targetContract(address(custody));
        targetSelector(FuzzSelector(address(custody), selectors));
    }

    function invariant_receivedFundsEqualAllRemainingObligationsAndActualPermittedOutflows() public view {
        assertEq(
            custody.funded() + custody.swapFees(),
            machine.totalPot() + machine.streamLiability() + custody.keeperPaid() + custody.winnersPaid()
                + custody.poolsPaid()
        );
        assertEq(imd.balanceOf(owner), 0);
    }

    function invariant_internalAccountingExcludesUnsolicitedDonationsAndMatchesRealAssets() public view {
        assertEq(machine.liquidBalance() + machine.feeClaims(), machine.totalPot() + machine.streamLiability());
        assertEq(imd.balanceOf(address(machine)), machine.liquidBalance() + custody.donated());
        assertEq(manager.balanceOf(address(machine), uint256(uint160(address(imd)))), machine.feeClaims());
    }

    function invariant_eachSettlementAndStreamRetainsItsOriginalRecipientAndLiability() public view {
        custody.checkStreamsAndRecipients();
        assertGe(custody.settlements(), 2);
        assertGt(custody.poolsPaid(), 0);
        assertGt(custody.winnersPaid(), 0);
    }

    function invariant_domainVersionChangesOnlyOnAnExecutedMatureQueue() public view {
        assertEq(machine.domainVersion(), vm.toString(custody.versionNumber()));
        assertEq(machine.versionReadyAt(), custody.versionReady());
        if (custody.pendingVersion() == 0) assertEq(machine.pendingDomainVersion(), "");
        else assertEq(machine.pendingDomainVersion(), vm.toString(custody.pendingVersion()));
    }

    function test_handlerExercisesDenyPauseDonationsAndVersionExecution() public {
        custody.donate(100 ether);
        custody.trade(100 ether);
        custody.redeem();
        custody.deny(0);
        custody.advance(2 days);
        custody.deny(0); // Removal of an active denial must not restore the old stream.
        custody.configure(0, 0, true);
        custody.registerEntry(3, false); // Expected EntriesPaused, not a swallowed revert.
        custody.recycle(0);
        custody.rotateVersion(0);
        custody.rotateVersion(2); // Expected TooEarly.
        custody.advance(7 days);
        custody.rotateVersion(2);
        custody.claim(1); // Claims remain available while paused.
        invariant_receivedFundsEqualAllRemainingObligationsAndActualPermittedOutflows();
        invariant_internalAccountingExcludesUnsolicitedDonationsAndMatchesRealAssets();
        invariant_eachSettlementAndStreamRetainsItsOriginalRecipientAndLiability();
        invariant_domainVersionChangesOnlyOnAnExecutedMatureQueue();
    }
}
