These tests extend the existing suite without changing the accepted implementation or its configuration. They use the vendored dependencies and a local Uniswap v4 PoolManager; they require no network, RPC, FFI, environment mutation, or deployed accounts. Test signer keys and actor addresses exist only in the local EVM.

| File | Additional coverage |
| --- | --- |
| `AdversarialMachine.t.sol` | Every signed attestation field, signatures bound to a consumer, expiry boundaries, invalid metadata and configuration, owner access, failed transfer rollback, keeper reward thresholds, claim rounding, and permanent revocation of old streams after deny removal. |
| `PrizeBuyAdversarial.t.sol` | Successful purchases through another token's IMD pool, empty or removed liquidity, partial fills, impossible output floors, rollback of pool prices and balances, token callbacks, and immutable entrant-selected purchase terms. |
| `CustodyInvariant.t.sol` | Random interleavings of sponsorship, registration, fees, redemption, settlement, claims, donations, denials, recycling, pause and fee/share settings, rejected results, and domain-version timelocks. |
| `TokenProperties.t.sol` | Random transfers, approvals, delegated transfers and overdrafts; fixed supply and actor balances; allowance rollback, infinite approvals, self-transfers and zero transfers. |

The custody invariants assert these properties after every action:

- Recorded sponsorship and entry payments plus swap fees equal retained pots, unpaid streams, actual winner payments, actual submitter payments and actual pool payments.
- Liquid IMD plus PoolManager claims cover pots and streams exactly. Unsolicited donations remain separate from internal prize accounting.
- Each stream belongs to its recorded entrant, claims never exceed the award, unpaid stream totals match the global liability, and each settled round remains settled exactly once.
- Queueing, replacing or cancelling a domain-version change cannot alter the active version. Only execution of a queue at least seven days old changes it.

Outgoing IMD is observed through ERC20 transfer logs. Each payment must go to the current settlement's submitter, the claimed stream's winner, or the PoolManager during an authorized purchase. Pool expenditure is not calculated as a residual accounting difference. A pool payment also requires actual HACK delivery to the winning payout. Actor balances are checked against recorded payments.

Each custody campaign begins with two settled rounds, a successful token purchase and a partial claim, so the stream and payout assertions are exercised even before random actions begin. Invalid operations use expected reverts; unexpected reverts fail the campaign. The ordinary handler scenario explicitly exercises pause, donation, active deny removal, recycling, a rejected premature domain change and its later execution.

Run the complete project with `forge build --offline` and `forge test --offline`. To keep generated artifacts inside the assignment's writable paths, the local checks used:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test --offline
```

Inline settings run each new custody campaign 256 times at depth 80, each token campaign 256 times at depth 64, and each new stateless fuzz property 1,000 times. No submitted test depends on `test/scratch/`.

The existing manifest, stored policy snapshot, heartbeat placeholders, weekly schedule, runtime sizes and absence of external library links were also checked offline. The hook runtime is 20,753 bytes and the token runtime is 1,502 bytes. The factory's live allocation and actual oracle scheduling are outside this local test harness; deployment values remain the existing manifest placeholders. The original protocol-vector conformance and signer-rotation tests remain part of the full suite.
