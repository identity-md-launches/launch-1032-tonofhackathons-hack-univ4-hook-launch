# Local adversarial review

Scope: the fixed token, combined hook/prize machine, oracle verification, manifest and operations. The supplied Ethereum and v4 security references were read as data and compared with the implemented flows. This is the implementing contributor's review, not an independent security audit.

| Attack or failure | Implementation and evidence |
| --- | --- |
| Initialization squatting / attaching a different pool | Constructor binds token, manager and factory; beforeInitialize authenticates PoolManager and factory and accepts only the configured pair, fee and spacing. Subsequent swaps require the bound PoolId. Tests refuse unrelated callers and pool keys. |
| NoOp / user-approval theft | Before-swap delta is only a bounded 2% IMD fee, never the whole trade. Hook data is ignored. Transfers from wallets are only from msg.sender in register/fundRound. Own swaps settle this contract's IMD without approvals. |
| Insolvent fresh manager | Mint IMD ERC6909 claims at fee collection; no transfer before router settlement. A real manager with token-only liquidity executes its first buy. All four directions/modes settle deltas and redeem claims successfully. |
| Price-bound overcharge | Exact-input sales use actual gross IMD output. Specified-IMD modes require full AMM fill; atomic reversion cancels fee minting otherwise. |
| Fee bypass on the hook's own HACK purchases | v4 skips callbacks when sender equals the hook. The optional buy path explicitly retains 2% of its HACK-purchase input as liquid current-pot funds. Successful purchase tests and conservation invariants include this retention. |
| Forged oracle / wrong consumer / chain / schema | Canonical 15-field type hash and EIP-712 domain; independent protocol vector digest and signature both pass. Forged, changed, wrong-chain, old-key, old-version, expired and inadequate-panel results fail. |
| Replay and stale round | Both request IDs and rounds are consumed, latest closed round only, issuance after its close and before the next deadline. Reusing a request in a later round fails. |
| Hidden instant signer change | Separate public queues, 7-day maturity, cancellation and delay reset. Unit fuzzing and stateful invariants ensure queueing has no effect before valid execution. |
| Stealing future entry fees / stream reserves | Separate open and closed pots and stream liabilities. Invariants reconcile every source and authorized exit to tracked assets. New-round entry fees are excluded from previous-round settlement. Direct donations are excluded. |
| Winner cooldown bypass by early registration | Eligibility is checked both at registration and settlement. Pre-registering while the previous result is pending does not bypass the four-round cooldown. |
| Deny removal restoring old streams | Denial generation persists on removal of an active deny. All unpaid amounts of old streams can be recycled after removal; a pending cancellation has no effect. |
| Reentrancy from asset, token or hook | Shared guard on entry/fund/claim/result, fee callbacks and explicit redemption; unlock callback additionally checks manager, entered guard and exact pending calldata hash. Only-self buy subcall is the optional rollback boundary. False-return token and reentrant IMD tests preserve accounting. |
| Buy routing or unlimited spending | Pre-close payout authorization, immutable entry token/payout, paired-currency validation, exact spending budget, committed absolute output floor and an execution price limit. Manager sync/transfer/settle return is checked. |
| Malicious token/hook stranding a result | Optional purchase subcall has a bounded gas allowance and reverts atomically into stream fallback. No owner rescue path or allowance is introduced. |
| Free withdrawal / pause trapping prizes | Owner cannot withdraw, change recipients or mint; results and claims work while new entries are paused. Anyone can trigger payment only to the recorded payout. |
| Unbounded expired-round processing | Two pot buckets roll forward in constant time, even after 1,000 skipped weeks. No iterate-all-entries or iterate-all-streams path exists in production. |
| Supply / code substitution | Token has only fixed ERC20 behavior. Compiler/configuration pinned; no runtime delegatecall, callcode or selfdestruct, no library links, both launch runtimes below EIP-170. |

Residual assumptions and responsibilities:

- Owner's question document and timelocked signer selection are trusted. The signer/panel selects a real winner; a signature proves attestation, not factual correctness. Denial is a delayed censorship power.
- This deployment uses the specified standard 18-decimal IMD. Nonstandard winning tokens are opt-in and may be worthless or behave dishonestly; successful ERC20 return values cannot prove their economic value. Purchase failure falls back, but entrants must choose a sensible minimum rate and judges must assess their pools.
- v4 spot price is used only for an additional execution movement limit. The independent absolute price floor is committed by the payout before the close. Neither is claimed to be an externally verified fair-value oracle or a complete MEV defense.
- Key/version rotation preserves this attestation schema. An incompatible future struct or permanently failing token/manager cannot be upgraded away.
- A denied stream returns its unpaid balance when somebody triggers claim/recycling; time passing alone cannot execute a transaction. Schedule maintenance, attestations and submissions also require external operators.
- The no-withdrawal policy leaves accidental token/native transfers and unsolicited claim transfers unrecoverable. Keeper competition can front-run the reward; that does not change the chosen winner or prize destination.
- Slither, Mythril, formal verification, a mainnet fork and an independent audit were not run. Production pool liquidity, factory allocation, real IMD behavior and callback gas must be rehearsed by the network before launch. The local tests exercise a real manager with local ERC20s, not a claim of mainnet execution.
