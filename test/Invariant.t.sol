// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MachineFixture} from "./MachineFixture.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HackToken} from "../src/HackToken.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract MachineHandler is Test {
    HackathonMachine public machine;
    MockERC20 public imd;
    PoolSwapTest public swapper;
    PoolKey internal key;
    address public owner;
    address public keeper;
    address public activeSigner;
    uint256 internal constant KEY1 = 0xA77E57;
    uint256 internal constant KEY2 = 0xA77E58;
    uint256 public deposited;
    uint256 public collectedFees;
    uint256 public keeperPaid;
    uint256 public winnersPaid;
    uint256 public poolsPaid;
    bool public invalidAttestationAccepted;
    uint256[] public winningIds;
    mapping(uint64 => uint256) public settlementCount;

    constructor(
        HackathonMachine machine_,
        MockERC20 imd_,
        HackToken hack_,
        PoolSwapTest swapper_,
        PoolKey memory key_,
        address keeper_
    ) {
        machine = machine_;
        imd = imd_;
        swapper = swapper_;
        key = key_;
        owner = machine.owner();
        keeper = keeper_;
        activeSigner = machine.oracleSigner();
        imd.approve(address(machine), type(uint256).max);
        imd.approve(address(swapper), type(uint256).max);
        hack_.approve(address(swapper), type(uint256).max);
    }

    function fund(uint96 amount) external {
        amount = uint96(bound(amount, 1, 1000 ether));
        imd.mint(address(this), amount);
        deposited += amount;
        machine.fundRound(amount);
    }

    function register(uint8 choice, bool buyToken) external {
        address payout = address(uint160(0x10000000) + uint160(choice));
        uint64 round = machine.currentRound();
        uint64 last = machine.lastWonRound(payout);
        if (machine.registered(round, payout) || (last != 0 && round <= last + 4)) return;
        uint256 fee = machine.entryFee();
        imd.mint(address(this), fee);
        deposited += fee;
        uint256 id = machine.register(
            "Invariant builder",
            "https://github.com/test/project",
            "imd",
            payout,
            buyToken ? machine.launchToken() : address(0)
        );
        if (buyToken) {
            uint256 rate = machine.Q96() * 8 / 10;
            vm.prank(payout);
            machine.configureBuy(id, key, rate);
        }
    }

    function trade(uint96 amount, bool buy) external {
        amount = uint96(bound(amount, 1 ether, 10 ether));
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        uint256 feesBefore = machine.feeClaims();
        swapper.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(uint256(amount)),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        collectedFees += machine.feeClaims() - feesBefore;
    }

    function advance(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 9 days));
        machine.advanceRound();
    }

    function redeem() external {
        machine.redeemFeeClaims();
    }

    function settle(uint32 choice) external {
        uint64 round = machine.currentRound() - 1;
        uint32 count = machine.entryCount(round);
        if (count == 0) return;
        uint256 id = (uint256(round) << 32) | (uint256(choice) % count + 1);
        (address payout,,,,) = machine.entries(id);
        uint64 last = machine.lastWonRound(payout);
        if (!machine.settled(round) && last != 0 && round <= last + 4) return;
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode(id, round));
        a.chainId = block.chainid;
        a.questionHash = machine.questionHash();
        a.answerType = 2;
        a.answer = abi.encode(bytes32(id));
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        uint256 keyToUse = machine.oracleSigner() == vm.addr(KEY1) ? KEY1 : KEY2;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyToUse, machine.attestationDigest(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        if (machine.settled(round)) {
            vm.expectRevert(HackathonMachine.RoundAlreadySettled.selector);
            machine.submitResult(a, sig);
            return;
        }
        uint256 beforeAssets = machine.liquidBalance() + machine.feeClaims();
        uint256 beforeKeeper = imd.balanceOf(keeper);
        vm.prank(keeper);
        machine.submitResult(a, sig);
        uint256 reward = imd.balanceOf(keeper) - beforeKeeper;
        keeperPaid += reward;
        poolsPaid += beforeAssets - machine.liquidBalance() - machine.feeClaims() - reward;
        ++settlementCount[round];
        winningIds.push(id);
    }

    function claim(uint32 choice) external {
        if (winningIds.length == 0) return;
        uint256 id = winningIds[uint256(choice) % winningIds.length];
        (address payout,,,,) = machine.streams(id);
        uint256 beforeBalance = imd.balanceOf(payout);
        machine.claim(id);
        winnersPaid += imd.balanceOf(payout) - beforeBalance;
    }

    function queueSigner() external {
        address replacement = activeSigner == vm.addr(KEY1) ? vm.addr(KEY2) : vm.addr(KEY1);
        vm.prank(owner);
        machine.queueSigner(replacement);
        assertEq(machine.oracleSigner(), activeSigner);
    }

    function rejectInvalidAttestation(uint32 choice, bool stale) external {
        uint64 round = machine.currentRound() - 1;
        uint32 count = machine.entryCount(round);
        if (count == 0 || machine.settled(round)) return;
        uint256 id = (uint256(round) << 32) | (uint256(choice) % count + 1);
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("invalid", id, block.timestamp));
        a.chainId = block.chainid;
        a.questionHash = machine.questionHash();
        a.answerType = 2;
        a.answer = abi.encode(bytes32(id));
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = stale ? uint64(machine.roundClose(round) - 1) : uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        uint256 signingKey = stale ? (machine.oracleSigner() == vm.addr(KEY1) ? KEY1 : KEY2) : 0xF0126ED;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, machine.attestationDigest(a));
        try machine.submitResult(a, abi.encodePacked(r, s, v)) {
            invalidAttestationAccepted = true;
        } catch {}
    }

    function executeSigner() external {
        uint64 ready = machine.signerReadyAt();
        if (ready == 0) return;
        if (block.timestamp < ready) {
            vm.expectRevert(HackathonMachine.TooEarly.selector);
            machine.executeSigner();
            assertEq(machine.oracleSigner(), activeSigner);
        } else {
            activeSigner = machine.pendingSigner();
            machine.executeSigner();
        }
    }

    function checkSettlements() external view {
        for (uint256 i; i < winningIds.length; ++i) {
            uint256 id = winningIds[i];
            uint64 round = uint64(id >> 32);
            assertEq(settlementCount[round], 1);
            assertTrue(machine.settled(round));
            (address payout,,,,) = machine.entries(id);
            (address recipient,,,,) = machine.streams(id);
            assertEq(recipient, payout);
        }
    }
}

contract MachineInvariantTest is MachineFixture {
    MachineHandler internal handler;

    function setUp() public override {
        super.setUp();
        seed();
        handler = new MachineHandler(machine, imd, hack, swapper, key, keeper);
        imd.mint(address(handler), 1_000_000 ether);
        hack.transfer(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.register.selector;
        selectors[2] = handler.trade.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.redeem.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.queueSigner.selector;
        selectors[8] = handler.executeSigner.selector;
        selectors[9] = handler.rejectInvalidAttestation.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_assetsEqualPotsAndUnpaidStreams() public view {
        assertAccounting();
    }

    function invariant_onlyWinnersPoolsKeepersAndCarryReceivePot() public view {
        assertEq(
            handler.deposited() + handler.collectedFees(),
            machine.totalPot() + machine.streamLiability() + handler.keeperPaid() + handler.winnersPaid()
                + handler.poolsPaid()
        );
        assertEq(imd.balanceOf(owner), 0);
        assertEq(imd.balanceOf(keeper), handler.keeperPaid());
    }

    function invariant_eachRoundSettlesAtMostOnceAndToItsWinner() public view {
        handler.checkSettlements();
    }

    function invariant_queuedSignerHasNoEffectUntilExecutionAfterDelay() public view {
        assertEq(machine.oracleSigner(), handler.activeSigner());
    }

    function invariant_forgedOrStaleAttestationsNeverSettle() public view {
        assertFalse(handler.invalidAttestationAccepted());
    }
}
