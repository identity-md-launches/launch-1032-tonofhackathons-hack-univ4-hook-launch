# TONOFHACKATHONS ($HACK)

A perpetual weekly hackathon funded by an additional 2% IMD fee on the HACK/IMD Uniswap v4 launch pool. `HackathonMachine` is both the hook and the prize machine. The launch deploys exactly two project contracts: `HackToken` and `HackathonMachine`. There is no staking, proxy, withdrawal function, separate vault, router deployment, or externally linked library.

## Build and verify

```sh
forge build
forge test
forge fmt --check
python3 tools/validate.py
```

Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, via IR, `bytecode_hash = "none"`. All Solidity dependencies are vendored as ordinary files under `lib/`; no network, submodules, environment variables, FFI, or filesystem cheatcode permissions are needed by the tests. Dependency versions and provenance are in `docs/dependencies.json`. The compiler itself is supplied by Foundry/the verifier, not vendored.

Tests use a real local PoolManager, local tokens and explicit test signing keys. They cover four swap modes, token-only seed liquidity on an otherwise empty manager, partial fills, round accounting, streams, buybacks and failure fallback, reentrancy, signature failures, replay, deny timing and oracle rotation. The protocol's independent digest/signature vector is preserved in `test/OracleConformance.t.sol`; self-generated signatures are not the sole conformance check. Stateful invariants check conservation, authorized payout destinations, one settlement per round and signer timelocks across randomized call sequences. No RPC or mainnet fork was used.

## Launch parameters

`launch.json` is the deployment manifest. IMD performs deployment; there is deliberately no broadcast script.

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chainId 1 |
| Token | TONOFHACKATHONS / HACK, 18 decimals, fixed 1,000,000,000 supply |
| Pair | IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Pool fee / tick spacing | 12500 (1.25%) / 60 |
| Initial sqrtPriceX96 | `125270724187523965593206900` |
| Initial attester | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Permissions | beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta |
| Address flags | `0x20cc` (8396), masked by `0x3fff` |
| Initial domain | IdentityMD Oracle / 2 / current chainId / this hook |

The constructor takes `(poolManager, owner, factory, token, imd, signer)` in that order. The manifest uses `$poolManager`, `$owner`, `$factory`, `$token`, followed by the supplied lowercase IMD and attester addresses. No manager address is hardcoded. IMD must mine the hook address for its declared permissions and deploy and initialize atomically. Initialization accepts only the factory and the exact HACK/IMD fee/spacing, and binds the hook to that pool permanently.

**Deployment ordering requirement:** the mandated initial price expresses IMD per HACK only when the deployed HACK address sorts below IMD (`HACK < 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`). The factory operator must choose/mine a token deployment address satisfying this ordering and verify the predicted key and price before launch. Do not initialize this manifest with IMD as currency0: its price would be inverted and the opening cap would be wrong. The hook supports either ordering for fee accounting; it does not enforce the opening valuation.

The token has no constructor arguments and mints its entire supply to the factory. It has only standard ERC20 transfer/approval behavior and no post-construction mint, owner, pause, tax, upgrade, or burn interface. The **factory**, not the token or hook, handles launcher/network allocation. `docs/launch-request.json` records the requested `economics.poolBps: 9000` for the launcher share; its remainder defaults to the paying wallet. This belongs to the launch request's `onchain` object, not to a new field in the hook manifest. The deployment operator must retain these economics in the admitted request. This brief specifies no separate administrator, so `$owner` is assumed to resolve to the paying wallet and is also the permanently excluded payout. Do not substitute a different administrative address while keeping that assumption.

The published [mainnet policies](https://api.imd.fun/launch/policies), fetched October 8, 2026, list `[12500]` for policy 34 (the IMD terms of v29 remain). `docs/policy-snapshot.json` records that read. Tick spacing 60 is the launch spacing selected here and accepted by v4; the published policy does not list a separate spacing whitelist. Factory LP fees remain separate: its 1% launcher portion never enters this prize machine. The 2% hook fee is additional.

## Fee accounting

The fee currency is always IMD, regardless of token sort order. No trader address is decoded from `hookData`, and the hook never pulls a trader's funds. Its only `transferFrom` calls pull entry fees and sponsorship from the actual `msg.sender`.

| Swap mode | Fee and handling |
| --- | --- |
| Buy, exact IMD input | Floor(2% of the user's IMD budget) charged before the swap; remainder enters the AMM |
| Buy, exact HACK output | Floor(2% of actual AMM IMD input), charged after the swap in addition to that input |
| Sell, exact HACK input | Floor(2% of actual gross IMD output), charged after the swap |
| Sell, exact IMD output | Fee = ceil(net IMD output × 200 / 9800); gross output is net plus fee |

For specified-IMD swaps, a price or liquidity limit that prevents a full fill reverts **the entire swap**, including the fee. Unspecified-IMD swaps, notably exact-input sells reaching a price bound, charge only actual executed IMD. Tiny fees round down to zero except the exact-output gross-up. Routers must account for the additional hook fee in quotes and limits. The hook neither overrides the LP fee nor substitutes an AMM trade with a custom NoOp fill.

Fees from other swappers are minted as IMD ERC6909 claims held by the hook in PoolManager. This avoids requiring preexisting manager IMD when the trader's router has not yet settled. Claims are counted as pot assets immediately. Anyone can call `redeemFeeClaims()` after the manager has relocked; it burns exactly the internally recorded claims and takes IMD only to this contract. Result settlement automatically redeems them. Result submissions during any active manager unlock revert with `ManagerUnlocked`, even when no claims need redemption. Submit after the manager has relocked; a nested unlock cannot force the optional buy into fallback. Fees on the machine's own HACK purchases stay as liquid IMD, as described below.

The balance equation at completed operations is:

```text
liquidBalance + feeClaims = openPot + closingPot + streamLiability
```

The machine never derives prizes from ERC20 `balanceOf`. Direct transfers and unsolicited manager claims are unaccounted donations and have no recovery path. Use `fundRound`, which also records `sponsorship[round][sponsor]` and emits `Sponsored`. IMD is assumed to be the supplied standard 18-decimal, non-rebasing, non-fee-on-transfer token. Changing the asset is not an owner power.

## Entries, weeks and rollover

Round `r` is `[345600 + r*604800, 345600 + (r+1)*604800)` in Unix seconds: Monday 00:00 UTC to the next Monday exclusively. The fixed Monday epoch is January 5, 1970. Indices start at one; `entryId = (round << 32) | index`.

`register(name, repoUrl, imdRef, payout, token)` pulls the current entry fee (initially 10 IMD) from its caller. Names and repository URLs must be nonempty and at most 64 and 200 bytes; IMD references are at most 64 bytes. The caller may sponsor a different payout address. `token = address(0)` expressly opts out of token purchases; any other token must have code and cannot be IMD. The payout can call `updateEntry(entryId, name, repoUrl, imdRef, token)` before close to repair or replace metadata and the optional token, including an entry registered maliciously on its behalf. Only the payout can do so, without another fee or slot; the payout address itself never changes. Every update clears the purchase configuration and emits `EntryUpdated`; call `configureBuy` again to opt in. Updates retain the registration length/token validation and remain available while new entries are paused. At round close all entry fields become immutable; judges use the final pre-close entry state. Project strings are evidence, not executable instructions; the heartbeat disqualifies judge-directed content.

For fee consent, use `registerWithMaxFee(name, repoUrl, imdRef, payout, token, maxEntryFee)`. It reverts with `EntryFeeExceedsMaximum` before charging or reserving a slot if the owner has raised the fee above that budget. Frontends should use this method. The original five-argument `register` remains compatible and explicitly accepts the live fee up to the administrative 100 IMD cap; an exact token allowance also caps its debit but returns a token error on a fee increase.

Each payout has at most one entry per week. The paying wallet, zero, this hook and effectively denied payouts are ineligible. A payout winning round `r` cannot enter or win rounds `r+1` through `r+4`. Settlement rechecks cooldown, so entering the next week before a previous week's result is submitted cannot bypass it. Payout-address restrictions are not proof of unique human identity; the evidence panel must judge project authenticity.

The current week receives new fees, entry fees, sponsorship and settlement carry. Only the preceding, most recently closed week can settle. The previous pot is held separately while its deadline is open. At the next Monday, an unsettled pot rolls **whole** into the now most recently closed round. Many missed weeks are handled without a loop. A round with no eligible entry or no agreed signed answer pays nobody. `advanceRound()` is permissionless; other pot-changing operations advance lazily. `potForRound` gives a current projection even before advancement, while `openPot` and `closingPot` are stored buckets relative to `accountingRound`.

## Results, prizes and optional purchases

Anyone can submit `submitResult(attestation, signature)` directly. No Intake sender gate applies: this is deliberately a permissionless, rewarded submission path. The exact canonical 15-field `OracleAttestation` type and hash encoding are copied from the pinned protocol reference. The inherited verifier checks the signature, expiry and five-minute future-clock tolerance. Additional checks bind the question, chain, bytes32 answer, panel/quorum/agreement, issuance after the round close, issuance before its settlement deadline, existing eligible entry, request uniqueness and round uniqueness.

**Oracle consistency trust assumption (chosen scope for this revision):** the panel/attester is trusted to produce the same winning entry for every request about the same closed round, using the frozen evidence and rubric. The Monday 01:00 schedule is a liveness service, with no on-chain priority or exclusive request authorization. Anyone may buy another request in this consumer domain with the same fixed-window questionHash, including before the scheduled run. The first valid submitted attestation settles; an earlier-issued or scheduled attestation cannot replace it. If panels issue conflicting winners, an entrant can repeatedly buy panels and race a favorable answer (and collect the keeper reward). Seven seats and five agreeing do not prove reproducibility or prevent this attack. This revision adopts the report's explicit trust-assumption option, not an on-chain prevention of re-rolls. `RevisionTest.test_anyValidAttestationSettlesFirstComeFirstServed` demonstrates the consequence of a conflicting attestation. Operators must monitor repeated-request consistency with IMD; there is no challenge, rollback, or owner winner-selection mechanism.

Default panel floors are seven members and five agreeing, with `agreed >= quorum >= minAgreement` and `agreed <= panelSize`. `answer` must be the ABI-encoded bytes32 entry ID. The signed figure is preserved in hashing but is not a spending authority. Unrelated questions, forged signatures, answers for other contracts/chains, stale rounds and duplicate requests do not settle.

The brief's 70/10/20 allocation already totals 100%, so the keeper reward is deducted **first**. Reward is 1% of the closed pot, raised to 5 IMD whenever the pot holds at least 5 IMD. Below 5 IMD it is simply 1%. The remainder defaults to 70% stream, 10% token purchase and 20% carry, with rounding dust in carry. For a 1,000 IMD pot: keeper 10, stream 693, purchase 99, carry 198. Without a successful purchase, the stream is 792. At a 5 IMD pot the keeper receives all 5. Streams start at settlement time, vest linearly over 28 days and have no expiry. Anyone can trigger `claim(entryId)`, but IMD always goes to the immutable winning payout.

A token entrant may call `configureBuy(entryId, poolKey, minRateX96)` **from its payout** before the round closes. The key must pair its registered token with IMD in this manager, be initialized and have a static fee of at most 10%. The minimum rate is output token minor units per IMD minor unit, multiplied by `2**96`; it must be positive. The payout should derive this absolute floor from its acceptable execution price, including LP/hook fees, and token decimals. It is frozen at round close; neither owner nor submitter can replace it. This prevents keepers from changing the committed price floor or routing; they still choose execution timing. A zero token or missing configuration uses stream fallback.

The purchase is exact input, bounded by the entrant's committed absolute minimum output. Its sqrt-price limit is the v4 minimum/maximum boundary; a fixed spot-relative band no longer blocks ordinary pots on shallow launch pools. The full budget must fill and output must reach `ceil(allocation * minRateX96 / 2**96)` or the entire purchase reverts. It uses `PoolManager.unlock`, sync/transfer/settle with the machine's **own IMD**, and takes acquired tokens directly to the winning payout. No token is burned or retained for an owner. Pool hooks cannot choose a recipient or spend beyond that budget. A failed swap, partial fill, inadequate output, missing liquidity, rejected transfer or exhausted 500,000-gas purchase budget reverts the purchase subcall and adds the whole allocation to the IMD stream. Sufficient outer gas is required to make the attempt and record fallback; configured purchases need at least 750,000 gas available at that point. Submitters should estimate the whole call and allow margin.

The floor is chosen by the entrant; it is not an independent fair-value oracle. An entrant can choose poor terms. A submitter can move spot before settlement and unwind after it, so the absolute minimum is the only price protection; there is no TWAP or round-close price oracle. With a loose floor, a thin third-party pool can permit extraction. A local 1:1 launch-pool reproduction with a 400,000 IMD preceding buy reduced the winner's 99 IMD allocation output from over 89 HACK to approximately 49.79 HACK while satisfying a 0.5 HACK/IMD floor. This observation demonstrates reduced output, not a claim of attacker profitability. Supporting arbitrary project tokens also cannot prove that their transfer semantics or economic value are honest. Judges should reject fake or manipulated projects/pools; only standard tokens are supported. A favorable purchase delivers the tokens to that same winning payout. If the HACK launch pool itself is selected, v4 skips this hook's callbacks for its own swaps, so the purchase explicitly retains the same 2% IMD input fee in the current pot. For a 99 IMD purchase allocation, 97.02 reaches the AMM and 1.98 stays as liquid pot funds. `TokenBought.imdSpent` records actual AMM payment; `ResultSettled.bought` records the successful purchase allocation, including that retained fee.

## Administration and denial

Owner is immutable. Its only powers are:

| Function | Restriction |
| --- | --- |
| `setQuestionHash` | One nonzero hash, once |
| `setEntryFee` | 1–100 IMD, in minor units |
| `setWinnerBps` | 5000–9000; token purchase stays 10%, carry becomes the remainder |
| `setPanelFloors` | Panel at least 5, agreement at least 4, agreement no greater than panel, panel at most 300 |
| `pauseEntries` | Registration only; results, funding, fees and claims remain usable |
| `queueSigner` / `cancelSigner` | Public 7-day pending signer change; requeue restarts delay |
| `queueDomainVersion` / `cancelDomainVersion` | Public 7-day version change, nonempty at most 32 bytes |
| `queueDeny` / `removeDeny` | Deny addition effective after 48 hours; cancellation/removal public |

Only the owner can call `executeSigner` or `executeDomainVersion` after its public seven-day delay. This prevents a third party from executing a matured rotation just before a keeper submits an already-issued result. The owner must coordinate with IMD and keepers: settle outstanding results first, then execute, or obtain replacement attestations under the new signer/version before the weekly deadline. Old signatures are not accepted after execution; owner execution can still invalidate them. Cancellation and requeue remain available. A queued value has no signature effect. The domain name, chain binding, consumer and attestation struct remain fixed; a version-string/key change can be accommodated, but a structurally incompatible future oracle protocol would need to continue offering this schema. Owner cannot select a winner, redirect a stream, transfer ownership, withdraw, upgrade, or alter the fee/pair. Settings other than delays apply when the relevant operation executes, including the share and panel floors at settlement.

Once a denial becomes effective, registration and settlement for that payout fail, and **all unpaid** amounts in its existing streams, including vested-but-unclaimed amounts, are reclaimable to the current pot. `claim` performs this recycling instead of payment, or anyone can call `recycleDeniedStream`. Removing an effective denial permanently increments its generation; it cannot revive old unpaid streams even if nobody called during the denial. A pending cancellation before 48 hours does not revoke streams. No unbounded list traversal is needed.

A denial that matures after round close but before submission still makes that payout ineligible. A panel's earlier eligibility assessment cannot override the live deny list; if no eligible result arrives before the next close, the entire pot rolls over. This delayed censorship power is retained as required.

Administrative trust remains: denying a payout can censor it after notice, increasing quorum can delay settlement, and the one-time question plus future attester selections must be honest. Timelocks make those oracle changes public, not trustless. Entries do not entitle the caller to a refund or a prize.

## After launch

1. Before deployment, IMD verifies the predicted HACK address sorts below IMD for this manifest price. IMD records the deployed hook/token, verifies code and constructor values, confirms the mainnet pool and requested allocation, and supplies the hook's actual deployment block. No wallet address or block number is guessed in this repository.
2. Render `docs/heartbeat.json` **once** using `tools/render_heartbeat.py --consumer <deployed-hook> --deployment-block <actual-block> --output <body-file>`. For a schedule-create input also supply `--schedule-output <schedule-file> --runs <number-to-prepay>`. The renderer uses only local files and arguments. It replaces `$hook`, `$deploymentBlock`, `$deploymentBlockPlusOne`, `$renderedHeartbeat` and `$prepaidRuns`. These are documentation template markers, not literal API values or additional factory placeholders.
3. The generated request pins exactly `{fromBlock: deploymentBlock, toBlock: deploymentBlock + 1}` as **numbers**, and the consumer is this hook on chain 1. Wait until both blocks exist and are sufficiently confirmed before scheduling. Never substitute a relative window, update the bounds each week, insert live entry lists into definitions, or edit the question. The definition selects the most recently closed contract round from request issuance time; the blocks are context only. These fixed inputs keep the questionHash stable.
4. Obtain the canonical questionHash for that exact rendered document from IMD (for example, the first oracle attestation, independently verifying its consumer and question document). The owner calls `setQuestionHash` once. Do **not** guess that it equals a hash of raw JSON: IMD canonicalizes its question document. Review the rendered text before this irreversible configuration. Unconfigured results revert clearly; funding, entries and trading can already operate. The one-shot pin is required by the brief: a wrong canonical hash, or a future canonicalization change, cannot be repaired by signer/version rotation. It can permanently strand existing and future pot contributions. Independently check the canonical attested hash and frozen document before pinning, and confirm with IMD that this canonical document remains supported. No hash-rotation or withdrawal power has been added.
5. An operator funds and creates the external `schedule.create` using the generated schedule input: **Mondays 01:00 UTC**, cron `0 1 * * 1`, `tz: UTC`, panel 7, quorum 5, bytes32 answer, at least two hosts among GitHub and the two IMD sources. The [IMD API documentation](https://www.imd.fun/docs#paid) describes schedules as a separate paid action wrapping a frozen `oracle.request` body. `docs/schedule.json` is that wrapper template. Schedule fees are paid externally and never drawn from prizes. Keep the schedule funded; top up or recover paused/exhausted schedules as needed. This repository makes no API purchase or scheduling call.
6. Keepers read each attested result and signature and submit it directly before the following Monday. They should verify the advertised domain version/signer and use enough gas for an optional purchase. Check for conflicting attestations across independently purchased requests; the schedule has no exclusive authority. Monitor expiry (six days from issuance), no-consensus/refused requests, reorgs, missed deadlines, signer/version queues and deny additions. If the oracle cannot agree, let the pot roll over rather than fabricating an entry ID. Claims need no keeper: winners or anyone else may trigger them.
7. Entrants choosing a token purchase configure their IMD pool and meaningful minimum rate before close. Winners pull vested IMD; anyone may redeem fee claims or recycle a denied stream.

Signer and domain rotation are the only protocol settings that can change. There is no pot-funded oracle requester, Intake allowance, native-currency handling or automatic callback limited to 200,000 gas. The heartbeat names `consumer`, and keepers submit the retrieved attestation using the two-argument `submitResult`; they do not send an Intake callback with an extra request ID.

## Review status

Local build, unit/fuzz/invariant tests, protocol conformance, manifest validation, forbidden-opcode inspection and size checks are included. `docs/security-review.md` records the adversarial review and deployment responsibilities; `.imd-responses.json` records each revision finding and its resolution. Tests are not an independent audit. An independent contributor review, production PoolManager/factory rehearsal and source verification remain the network deployer's responsibilities before release. No contracts were deployed, no transaction broadcast, no RPC called and no schedule purchased here.
