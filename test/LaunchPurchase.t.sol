// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HackToken} from "src/HackToken.sol";
import {HackathonMachine} from "src/HackathonMachine.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

contract LaunchPurchaseIMD is ERC20 {
    constructor() ERC20("IdentityMD", "IMD") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

/// @notice Regression for purchases from a 900M HACK one-sided pool at the manifest opening price.
contract LaunchPurchaseTest is Test {
    uint256 constant SIGNER_KEY = 0xA77E57;
    uint160 constant FLAGS = 0x20cc;
    uint160 constant LAUNCH_SQRT_PRICE = 125270724187523965593206900;
    bytes32 constant QUESTION = keccak256("fixed question document");

    HackathonMachine machine;
    LaunchPurchaseIMD imd;
    HackToken hack;
    PoolManager manager;
    PoolModifyLiquidityTest liquidity;
    PoolKey key;
    address owner = makeAddr("payer-owner");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.chainId(1);
        vm.warp(345600 + 3000 * 7 days + 1 days);
        // HACK at a low address so it is currency0: the ordering the manifest's sqrtPriceX96 encodes.
        address hackAt = address(uint160(0x1000));
        deployCodeTo("HackToken.sol:HackToken", "", hackAt); // mints the supply to this test contract
        hack = HackToken(hackAt);
        imd = new LaunchPurchaseIMD();
        require(address(imd) > hackAt, "ordering");
        manager = new PoolManager(address(this));
        liquidity = new PoolModifyLiquidityTest(manager);
        address hookAddress = address(uint160(0x100000) | FLAGS);
        deployCodeTo(
            "HackathonMachine.sol:HackathonMachine",
            abi.encode(IPoolManager(address(manager)), owner, address(this), hackAt, address(imd), vm.addr(SIGNER_KEY)),
            hookAddress
        );
        machine = HackathonMachine(hookAddress);
        key = PoolKey(Currency.wrap(hackAt), Currency.wrap(address(imd)), 12500, 60, IHooks(hookAddress));
        imd.approve(address(machine), type(uint256).max);
        hack.approve(address(liquidity), type(uint256).max);
        imd.approve(address(liquidity), type(uint256).max);
        vm.prank(owner);
        machine.setQuestionHash(QUESTION);

        // Open at the manifest price and seed the launcher's 900M HACK one-sided just above it.
        manager.initialize(key, LAUNCH_SQRT_PRICE);
        int24 current = TickMath.getTickAtSqrtPrice(LAUNCH_SQRT_PRICE);
        int24 lower = current % 60 == 0 ? current : (current - (current % 60 + 60) % 60) + 60;
        int24 upper = 887220;
        uint160 sa = TickMath.getSqrtPriceAtTick(lower);
        uint160 sb = TickMath.getSqrtPriceAtTick(upper);
        uint256 L = FullMath.mulDiv(FullMath.mulDiv(900_000_000 ether, sa, sb - sa), sb, 1 << 96);
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(L), 0), "");
        assertEq(imd.balanceOf(address(manager)), 0);
    }

    function test_winnerTokenPurchaseExecutesForOrdinaryPot() public {
        uint256 id =
            machine.register("Working builder", "https://github.com/builder/repo", "imd:project", alice, address(hack));
        // Entrant accepts essentially any price: floor of 1e-28 HACK per IMD unit.
        vm.prank(alice);
        machine.configureBuy(id, key, 1);
        machine.fundRound(990 ether); // pot 1,000 IMD: 10 reward, 99 purchase allocation
        vm.warp(machine.roundClose(machine.currentRound()) + 1 hours);

        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256("request"),
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, machine.attestationDigest(a));
        vm.prank(keeper);
        machine.submitResult(a, abi.encodePacked(r, s, v));

        // The pool can fill a 97.02 IMD buy (it holds 900M HACK), the entrant accepted any price,
        // so the purchase must execute instead of falling back because of a spot-relative band.
        assertGt(hack.balanceOf(alice), 0, "winner received no HACK: purchase skipped by the fixed 1% band");
        (,,, uint256 total,) = machine.streams(id);
        assertEq(total, 693 ether, "allocation was streamed instead of bought");
    }
}
