// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HackToken} from "../src/HackToken.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

abstract contract MachineFixture is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant SIGNER_KEY = 0xA77E57;
    uint160 internal constant FLAGS = 0x20cc;
    uint160 internal constant ONE = 79228162514264337593543950336;
    bytes32 internal constant QUESTION = keccak256("fixed question document");
    HackathonMachine internal machine;
    MockERC20 internal imd;
    HackToken internal hack;
    PoolManager internal manager;
    PoolSwapTest internal swapper;
    PoolModifyLiquidityTest internal liquidity;
    PoolKey internal key;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal keeper;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(345600 + 3000 * 7 days + 1 days);
        owner = makeAddr("payer-owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        imd = new MockERC20("IdentityMD", "IMD", 1_000_000_000 ether);
        hack = new HackToken();
        manager = new PoolManager(address(this));
        swapper = new PoolSwapTest(manager);
        liquidity = new PoolModifyLiquidityTest(manager);
        address hookAddress = address(uint160(0x100000) | FLAGS);
        deployCodeTo(
            "HackathonMachine.sol:HackathonMachine",
            abi.encode(
                IPoolManager(address(manager)), owner, address(this), address(hack), address(imd), vm.addr(SIGNER_KEY)
            ),
            hookAddress
        );
        machine = HackathonMachine(hookAddress);
        key = pairKey(address(hack), IHooks(hookAddress));
        imd.approve(address(machine), type(uint256).max);
        imd.approve(address(swapper), type(uint256).max);
        imd.approve(address(liquidity), type(uint256).max);
        hack.approve(address(swapper), type(uint256).max);
        hack.approve(address(liquidity), type(uint256).max);
        vm.prank(owner);
        machine.setQuestionHash(QUESTION);
    }

    function pairKey(address token, IHooks hook) internal view returns (PoolKey memory) {
        (address c0, address c1) = address(imd) < token ? (address(imd), token) : (token, address(imd));
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, hook);
    }

    function seed() internal {
        manager.initialize(key, ONE);
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1_000_000 ether, 0), "");
    }

    function trade(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (BalanceDelta) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return swapper.swap(
            key,
            SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function enter(address payout, address token) internal returns (uint256) {
        return machine.register("Working builder", "https://github.com/builder/repo", "imd:project", payout, token);
    }

    function closeRound() internal {
        vm.warp(machine.roundClose(machine.currentRound()) + 1 hours);
    }

    function attestation(uint256 id) internal view returns (OracleAttestation.Attestation memory a) {
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("request", id)),
            chainId: 1,
            questionHash: QUESTION,
            answerType: 2,
            answer: abi.encode(bytes32(id)),
            figure: 0,
            fromBlock: 100,
            toBlock: 101,
            blockHash: keccak256("block"),
            panelJobId: keccak256("panel"),
            panelSize: 7,
            quorum: 5,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 6 days)
        });
    }

    function signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, machine.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function settle(uint256 id) internal {
        OracleAttestation.Attestation memory a = attestation(id);
        bytes memory sig = signature(a);
        vm.prank(keeper);
        machine.submitResult(a, sig);
    }

    function assertAccounting() internal view {
        assertEq(machine.liquidBalance() + machine.feeClaims(), machine.totalPot() + machine.streamLiability());
        assertEq(imd.balanceOf(address(machine)), machine.liquidBalance());
        assertEq(manager.balanceOf(address(machine), uint256(uint160(address(imd)))), machine.feeClaims());
    }
}
