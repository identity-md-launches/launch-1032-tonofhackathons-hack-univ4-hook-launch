// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HackathonMachine} from "../src/HackathonMachine.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HackToken} from "../src/HackToken.sol";

// Test-only hook address override: the protocol's fixed consumer address has unrelated v4 flags.
contract ConformanceMachine is HackathonMachine {
    constructor(IPoolManager manager, address owner_, address token, address asset, address signer)
        HackathonMachine(manager, owner_, owner_, token, asset, signer)
    {}
    function _validateHookAddress() internal view override {}

    function verifyVector(OracleAttestation.Attestation calldata a, bytes calldata sig) external view {
        _verifyAttestation(a, sig);
    }
}

contract OracleConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    ConformanceMachine consumer;
    MockERC20 imd;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        PoolManager manager = new PoolManager(address(this));
        HackToken token = new HackToken();
        imd = new MockERC20("IdentityMD", "IMD", 1000 ether);
        deployCodeTo(
            "OracleConformance.t.sol:ConformanceMachine",
            abi.encode(manager, address(this), address(token), address(imd), SIGNER),
            VECTOR_CONSUMER
        );
        consumer = ConformanceMachine(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function test_acceptsExactProtocolSignature() public view {
        consumer.verifyVector(vector(), VECTOR_SIGNATURE);
    }

    function test_submitSelectorUsesAllFifteenCanonicalFields() public pure {
        assertEq(
            HackathonMachine.submitResult.selector,
            bytes4(
                keccak256(
                    bytes(
                        "submitResult((bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                    )
                )
            )
        );
    }

    function test_freshVectorKeySignatureSettlesBytes32Entry() public {
        OracleAttestation.Attestation memory a = vector();
        consumer.setQuestionHash(a.questionHash);
        imd.approve(address(consumer), 10 ether);
        uint256 id =
            consumer.register("Builder", "https://github.com/entry/repo", "imd:ref", makeAddr("winner"), address(0));
        vm.warp(consumer.roundClose(consumer.currentRound()) + 1 hours);
        a.chainId = VECTOR_CHAIN;
        a.answerType = 2;
        a.answer = abi.encode(bytes32(id));
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        consumer.submitResult(a, abi.encodePacked(r, s, v));
        assertTrue(consumer.consumed(a.requestId));
    }
}
