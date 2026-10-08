// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";

/// @notice Fixed IMD fee hook and perpetual weekly builder prizes. No withdrawal or upgrade path.
contract HackathonMachine is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    error Unauthorized();
    error InvalidInput();
    error WrongPool();
    error EntriesPaused();
    error Ineligible();
    error TooEarly();
    error NoPendingChange();
    error InvalidResult();
    error RoundAlreadySettled();
    error PartialSpecifiedSwap();
    error Slippage();
    error InsufficientExecutionGas();
    error ManagerUnlocked();
    error EntryFeeExceedsMaximum();

    uint256 public constant MONDAY_EPOCH = 345600; // 1970-01-05 00:00:00 UTC
    uint256 public constant WEEK = 7 days;
    uint256 public constant STREAM_DURATION = 28 days;
    uint256 public constant ORACLE_DELAY = 7 days;
    uint256 public constant DENY_DELAY = 48 hours;
    uint256 public constant FEE_BPS = 200;
    uint256 public constant Q96 = 1 << 96;
    uint256 private constant BUY_GAS = 500_000;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    IPoolManager public immutable poolManager;
    IERC20 public immutable imd;
    address public immutable owner;
    address public immutable payingWallet;
    address public immutable factory;
    address public immutable launchToken;
    PoolId public launchPoolId;
    bool public initialized;

    uint256 public entryFee = 10 ether;
    uint16 public winnerBps = 7000;
    uint16 public minPanelSize = 7;
    uint16 public minAgreement = 5;
    bool public entriesPaused;
    bytes32 public questionHash;

    string public domainVersion = "2";
    address public pendingSigner;
    uint64 public signerReadyAt;
    string public pendingDomainVersion;
    uint64 public versionReadyAt;

    struct Entry {
        address payout;
        address token;
        string name;
        string repoUrl;
        string imdRef;
    }

    struct Stream {
        address payout;
        uint64 start;
        uint64 denyGeneration;
        uint256 total;
        uint256 claimed;
    }

    struct BuyConfig {
        PoolKey key;
        // Absolute minimum output token units per IMD minor unit, scaled by 2**96.
        uint256 minRateX96;
    }

    mapping(uint256 => Entry) public entries;
    mapping(uint64 => uint32) public entryCount;
    mapping(uint64 => mapping(address => bool)) public registered;
    mapping(uint64 => mapping(address => uint256)) public sponsorship;
    mapping(address => uint64) public lastWonRound;
    mapping(uint64 => bool) public settled;
    mapping(uint256 => Stream) public streams;
    mapping(uint256 => BuyConfig) private buyConfigs;
    mapping(address => uint64) public denyAt;
    mapping(address => uint64) public denyGeneration;

    // Only the open week and its predecessor can hold pots. Expired pots roll in O(1).
    uint64 public accountingRound;
    uint256 public openPot;
    uint256 public closingPot;
    uint256 public streamLiability;
    uint256 public liquidBalance;
    uint256 public feeClaims;
    bytes32 private expectedUnlock;

    event PoolBound(PoolId indexed poolId);
    event Registered(uint64 indexed round, uint256 indexed entryId, address indexed payout, address payer);
    event EntryUpdated(uint256 indexed entryId);
    event Sponsored(uint64 indexed round, address indexed sponsor, uint256 amount);
    event FeeCollected(uint64 indexed round, uint256 amount);
    event ClaimsRedeemed(uint256 amount);
    event RoundAdvanced(uint64 indexed currentRound, uint256 closingPot);
    event ResultSettled(
        uint64 indexed round,
        uint256 indexed entryId,
        bytes32 indexed requestId,
        address submitter,
        uint256 reward,
        uint256 streamed,
        uint256 bought,
        uint256 carried
    );
    event Claimed(uint256 indexed entryId, address indexed payout, uint256 amount);
    event StreamRecycled(uint256 indexed entryId, uint256 amount);
    event BuyConfigured(uint256 indexed entryId, PoolId indexed poolId, uint256 minRateX96);
    event TokenBought(uint256 indexed entryId, uint256 imdSpent, uint256 tokensReceived);
    event BuySkipped(uint256 indexed entryId);
    event QuestionPinned(bytes32 indexed questionHash);
    event EntryFeeSet(uint256 amount);
    event WinnerShareSet(uint16 bps);
    event PanelFloorsSet(uint16 panelSize, uint16 agreement);
    event EntriesPauseSet(bool paused);
    event SignerQueued(address indexed signer, uint64 readyAt);
    event SignerCancelled();
    event DomainVersionQueued(string version, uint64 readyAt);
    event DomainVersionCancelled();
    event DomainVersionSet(string version);
    event DenyQueued(address indexed payout, uint64 effectiveAt);
    event DenyRemoved(address indexed payout);

    constructor(IPoolManager manager_, address owner_, address factory_, address token_, address imd_, address signer_)
        OracleAttestationConsumer(signer_)
    {
        if (
            address(manager_) == address(0) || owner_ == address(0) || factory_ == address(0) || token_ == address(0)
                || imd_ == address(0) || token_ == imd_
        ) revert InvalidInput();
        poolManager = manager_;
        owner = owner_;
        payingWallet = owner_; // This launch names no separate owner: $owner resolves to the paying wallet.
        factory = factory_;
        launchToken = token_;
        imd = IERC20(imd_);
        accountingRound = currentRound();
        _validateHookAddress();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function _validateHookAddress() internal view virtual {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        nonReentrant
        returns (bytes4)
    {
        if (
            initialized || sender != factory || address(key.hooks) != address(this) || !_isPair(key, launchToken)
                || key.fee != 12500 || key.tickSpacing != 60
        ) revert WrongPool();
        initialized = true;
        launchPoolId = key.toId();
        emit PoolBound(launchPoolId);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 fee;
        if (_imdSpecified(key, params)) {
            fee = _specifiedFee(params.amountSpecified);
            _collectFee(fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_asInt128(fee), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, int128)
    {
        _checkPool(key);
        int128 imdDelta = Currency.unwrap(key.currency0) == address(imd) ? delta.amount0() : delta.amount1();
        if (_imdSpecified(key, params)) {
            // A specified-side fee cannot be corrected using afterSwap's unspecified delta.
            // Refuse partial fills atomically rather than charging on unexecuted volume.
            int256 expected = params.amountSpecified + int256(_specifiedFee(params.amountSpecified));
            if (int256(imdDelta) != expected) revert PartialSpecifiedSwap();
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 amount = imdDelta < 0 ? uint256(-int256(imdDelta)) : uint256(int256(imdDelta));
        uint256 fee = amount * FEE_BPS / 10_000;
        _collectFee(fee);
        return (IHooks.afterSwap.selector, _asInt128(fee));
    }

    function _specifiedFee(int256 specified) private pure returns (uint256) {
        if (specified == 0 || specified == type(int256).min) revert InvalidInput();
        uint256 amount = uint256(specified < 0 ? -specified : specified);
        if (amount > uint256(uint128(type(int128).max))) revert InvalidInput();
        // Buy exact input: 2% of the user's budget. Sell exact output: gross up the desired net.
        return specified < 0 ? amount * FEE_BPS / 10_000 : (amount * FEE_BPS + 9799) / 9800;
    }

    function _imdSpecified(PoolKey calldata key, SwapParams calldata params) private view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (Currency.unwrap(key.currency0) == address(imd));
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(launchPoolId)) revert WrongPool();
    }

    function _collectFee(uint256 amount) private {
        if (amount == 0) return;
        _syncRounds();
        openPot += amount;
        feeClaims += amount;
        poolManager.mint(address(this), uint256(uint160(address(imd))), amount);
        emit FeeCollected(accountingRound, amount);
    }

    function currentRound() public view returns (uint64) {
        return block.timestamp < MONDAY_EPOCH ? 0 : uint64((block.timestamp - MONDAY_EPOCH) / WEEK);
    }

    function roundClose(uint64 round) public pure returns (uint256) {
        return MONDAY_EPOCH + (uint256(round) + 1) * WEEK;
    }

    function totalPot() external view returns (uint256) {
        return openPot + closingPot;
    }

    function potForRound(uint64 round) external view returns (uint256) {
        uint64 nowRound = currentRound();
        if (nowRound == accountingRound) {
            if (round == nowRound) return openPot;
            if (round + 1 == nowRound) return closingPot;
        } else if (round + 1 == nowRound) {
            return openPot + closingPot;
        }
        return 0;
    }

    function advanceRound() external nonReentrant {
        _syncRounds();
    }

    function _syncRounds() private {
        uint64 nowRound = currentRound();
        if (nowRound != accountingRound) {
            closingPot += openPot;
            openPot = 0;
            accountingRound = nowRound;
            emit RoundAdvanced(nowRound, closingPot);
        }
    }

    function register(
        string calldata name,
        string calldata repoUrl,
        string calldata imdRef,
        address payout,
        address token
    ) external nonReentrant returns (uint256 id) {
        return _register(name, repoUrl, imdRef, payout, token, type(uint256).max);
    }

    /// @notice Registers only if the live fee is within the caller's stated budget.
    function registerWithMaxFee(
        string calldata name,
        string calldata repoUrl,
        string calldata imdRef,
        address payout,
        address token,
        uint256 maxEntryFee
    ) external nonReentrant returns (uint256 id) {
        return _register(name, repoUrl, imdRef, payout, token, maxEntryFee);
    }

    function _register(
        string calldata name,
        string calldata repoUrl,
        string calldata imdRef,
        address payout,
        address token,
        uint256 maxEntryFee
    ) private returns (uint256 id) {
        if (entriesPaused) revert EntriesPaused();
        uint256 fee = entryFee;
        if (fee > maxEntryFee) revert EntryFeeExceedsMaximum();
        _validateEntry(name, repoUrl, imdRef, token);
        _syncRounds();
        uint64 round = accountingRound;
        if (!_eligible(payout, round) || registered[round][payout]) revert Ineligible();
        registered[round][payout] = true;
        id = (uint256(round) << 32) | ++entryCount[round];
        entries[id] = Entry(payout, token, name, repoUrl, imdRef);
        openPot += fee;
        liquidBalance += fee;
        imd.safeTransferFrom(msg.sender, address(this), fee);
        emit Registered(round, id, payout, msg.sender);
    }

    /// @notice The payout controls its entry until close, even if someone else paid to register it.
    /// @dev Updating clears the purchase configuration; the payout must opt in again explicitly.
    function updateEntry(
        uint256 id,
        string calldata name,
        string calldata repoUrl,
        string calldata imdRef,
        address token
    ) external nonReentrant {
        address payout = entries[id].payout;
        if (msg.sender != payout) revert Unauthorized();
        if (id >> 32 != currentRound()) revert InvalidInput();
        _validateEntry(name, repoUrl, imdRef, token);
        entries[id] = Entry(payout, token, name, repoUrl, imdRef);
        delete buyConfigs[id];
        emit EntryUpdated(id);
    }

    function _validateEntry(string calldata name, string calldata repoUrl, string calldata imdRef, address token)
        private
        view
    {
        if (
            bytes(name).length == 0 || bytes(name).length > 64 || bytes(repoUrl).length == 0
                || bytes(repoUrl).length > 200 || bytes(imdRef).length > 64 || token == address(imd)
                || (token != address(0) && token.code.length == 0)
        ) revert InvalidInput();
    }

    function fundRound(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidInput();
        _syncRounds();
        sponsorship[accountingRound][msg.sender] += amount;
        openPot += amount;
        liquidBalance += amount;
        imd.safeTransferFrom(msg.sender, address(this), amount);
        emit Sponsored(accountingRound, msg.sender, amount);
    }

    function _eligible(address payout, uint64 round) private view returns (bool) {
        uint64 last = lastWonRound[payout];
        return payout != address(0) && payout != payingWallet && payout != address(this) && !isDenied(payout)
            && (last == 0 || uint256(round) > uint256(last) + 4);
    }

    /// @notice Entrants may opt in to a pool and an absolute minimum exchange rate before the close.
    /// @dev No submitter or administrator can select a different pool, recipient, or minimum rate.
    function configureBuy(uint256 id, PoolKey calldata key, uint256 minRateX96) external nonReentrant {
        Entry storage e = entries[id];
        if (e.payout != msg.sender) revert Unauthorized();
        if (
            id >> 32 != currentRound() || e.token == address(0) || !_isPair(key, e.token) || minRateX96 == 0
                || key.fee > 100_000 || key.tickSpacing <= 0
        ) revert InvalidInput();
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price == 0) revert WrongPool();
        buyConfigs[id] = BuyConfig(key, minRateX96);
        emit BuyConfigured(id, key.toId(), minRateX96);
    }

    function buyConfig(uint256 id) external view returns (BuyConfig memory) {
        return buyConfigs[id];
    }

    function submitResult(OracleAttestation.Attestation calldata a, bytes calldata signature) external nonReentrant {
        // A caller must not manufacture purchase failure by nesting settlement in its own unlock.
        if (TransientStateLibrary.isUnlocked(poolManager)) revert ManagerUnlocked();
        _syncRounds();
        if (accountingRound == 0) revert InvalidResult();
        uint64 round = accountingRound - 1;
        if (settled[round]) revert RoundAlreadySettled();
        if (
            questionHash == bytes32(0) || a.questionHash != questionHash || a.chainId != block.chainid
                || a.panelSize < minPanelSize || a.panelSize > 300 || a.quorum < minAgreement || a.quorum > a.panelSize
                || a.agreed < a.quorum || a.agreed > a.panelSize || a.issuedAt < roundClose(round)
                || a.issuedAt >= roundClose(round + 1) || a.expiresAt < a.issuedAt || a.answer.length != 32
                || a.fromBlock > a.toBlock
        ) revert InvalidResult();
        _verifyAttestation(a, signature);
        uint256 id = uint256(decodeBytes32(a));
        Entry storage e = entries[id];
        if (id >> 32 != round || !_eligible(e.payout, round)) revert Ineligible();
        _consume(a.requestId);
        settled[round] = true;
        lastWonRound[e.payout] = round;
        uint256 pot = closingPot;
        closingPot = 0;
        uint256 reward = pot / 100;
        if (pot >= 5 ether && reward < 5 ether) reward = 5 ether;
        uint256 remaining = pot - reward;
        uint256 streamed = remaining * winnerBps / 10_000;
        uint256 buyAmount = remaining / 10;
        uint256 carried = remaining - streamed - buyAmount;
        openPot += carried;

        _redeemClaims();
        _pay(msg.sender, reward);
        uint256 bought;
        if (buyAmount != 0 && buyConfigs[id].minRateX96 != 0) {
            // Bound untrusted token/hook work, leaving gas to stream on failure.
            if (gasleft() < BUY_GAS + 250_000) revert InsufficientExecutionGas();
            try this.buyWinnerToken{gas: BUY_GAS}(id, buyAmount) {
                bought = buyAmount;
            } catch {
                emit BuySkipped(id);
            }
        }
        streamed += buyAmount - bought;
        streams[id] = Stream(e.payout, uint64(block.timestamp), denyGeneration[e.payout], streamed, 0);
        streamLiability += streamed;
        emit ResultSettled(round, id, a.requestId, msg.sender, reward, streamed, bought, carried);
    }

    /// @dev External self-call supplies an atomic revert boundary for an optional token purchase.
    function buyWinnerToken(uint256 id, uint256 amount) external {
        if (msg.sender != address(this) || !_reentrancyGuardEntered()) revert Unauthorized();
        _unlock(abi.encode(uint8(2), id, amount));
    }

    function redeemFeeClaims() external nonReentrant {
        _redeemClaims();
    }

    function _redeemClaims() private {
        if (feeClaims != 0) _unlock(abi.encode(uint8(1), uint256(0), feeClaims));
    }

    function _unlock(bytes memory data) private {
        if (expectedUnlock != bytes32(0)) revert Unauthorized();
        expectedUnlock = keccak256(data);
        bytes memory result = poolManager.unlock(data);
        if (expectedUnlock != bytes32(0) || result.length != 32 || !abi.decode(result, (bool))) revert InvalidInput();
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!_reentrancyGuardEntered() || expectedUnlock == bytes32(0) || keccak256(data) != expectedUnlock) {
            revert Unauthorized();
        }
        delete expectedUnlock;
        (uint8 operation, uint256 id, uint256 amount) = abi.decode(data, (uint8, uint256, uint256));
        if (operation == 1) {
            feeClaims -= amount;
            liquidBalance += amount;
            poolManager.burn(address(this), uint256(uint160(address(imd))), amount);
            poolManager.take(Currency.wrap(address(imd)), address(this), amount);
            emit ClaimsRedeemed(amount);
        } else if (operation == 2) {
            _buy(id, amount);
        } else {
            revert InvalidInput();
        }
        return abi.encode(true);
    }

    function _buy(uint256 id, uint256 amount) private {
        BuyConfig storage config = buyConfigs[id];
        PoolKey memory key = config.key;
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        // The entrant's absolute output floor bounds execution, including the whole budget's price impact.
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 minimum = FullMath.mulDivRoundingUp(amount, config.minRateX96, Q96);
        // v4 skips a hook's own callbacks. Apply the same exact-input buy fee explicitly
        // when a prize purchases HACK through this hook's pool; retain it as liquid pot.
        uint256 ownFee = address(key.hooks) == address(this) ? amount * FEE_BPS / 10_000 : 0;
        uint256 spend = amount - ownFee;
        BalanceDelta delta =
            poolManager.swap(key, SwapParams(zeroForOne, -int256(uint256(uint128(_asInt128(spend)))), limit), "");
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(input) != -int256(spend) || output <= 0 || uint256(uint128(output)) < minimum) revert Slippage();
        liquidBalance -= spend;
        if (ownFee != 0) {
            openPot += ownFee;
            emit FeeCollected(accountingRound, ownFee);
        }
        poolManager.sync(Currency.wrap(address(imd)));
        imd.safeTransfer(address(poolManager), spend);
        if (poolManager.settle() != spend) revert InvalidInput();
        Entry storage e = entries[id];
        poolManager.take(Currency.wrap(e.token), e.payout, uint256(uint128(output)));
        emit TokenBought(id, spend, uint256(uint128(output)));
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        Stream storage s = streams[id];
        if (s.payout == address(0)) revert InvalidInput();
        if (_streamDenied(s)) {
            _recycle(id, s);
            return 0;
        }
        uint256 elapsed = block.timestamp - s.start;
        uint256 vested = elapsed >= STREAM_DURATION ? s.total : FullMath.mulDiv(s.total, elapsed, STREAM_DURATION);
        amount = vested - s.claimed;
        s.claimed = vested;
        streamLiability -= amount;
        _pay(s.payout, amount);
        emit Claimed(id, s.payout, amount);
    }

    function recycleDeniedStream(uint256 id) external nonReentrant {
        Stream storage s = streams[id];
        if (s.payout == address(0) || !_streamDenied(s)) revert Ineligible();
        _recycle(id, s);
    }

    function _streamDenied(Stream storage s) private view returns (bool) {
        return isDenied(s.payout) || s.denyGeneration != denyGeneration[s.payout];
    }

    function _recycle(uint256 id, Stream storage s) private {
        _syncRounds();
        uint256 unpaid = s.total - s.claimed;
        s.total = s.claimed;
        streamLiability -= unpaid;
        openPot += unpaid;
        emit StreamRecycled(id, unpaid);
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        liquidBalance -= amount;
        imd.safeTransfer(to, amount);
    }

    function _asInt128(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert InvalidInput();
        return int128(uint128(amount));
    }

    function _isPair(PoolKey memory key, address token) private view returns (bool) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        return c0 < c1 && ((c0 == address(imd) && c1 == token) || (c1 == address(imd) && c0 == token));
    }

    function setQuestionHash(bytes32 hash) external onlyOwner {
        if (hash == bytes32(0) || questionHash != bytes32(0)) revert InvalidInput();
        questionHash = hash;
        emit QuestionPinned(hash);
    }

    function setEntryFee(uint256 amount) external onlyOwner {
        if (amount < 1 ether || amount > 100 ether) revert InvalidInput();
        entryFee = amount;
        emit EntryFeeSet(amount);
    }

    function setWinnerBps(uint16 bps) external onlyOwner {
        if (bps < 5000 || bps > 9000) revert InvalidInput();
        winnerBps = bps;
        emit WinnerShareSet(bps);
    }

    function setPanelFloors(uint16 panel, uint16 agreement) external onlyOwner {
        if (panel < 5 || panel > 300 || agreement < 4 || agreement > panel) revert InvalidInput();
        minPanelSize = panel;
        minAgreement = agreement;
        emit PanelFloorsSet(panel, agreement);
    }

    function pauseEntries(bool paused) external onlyOwner {
        entriesPaused = paused;
        emit EntriesPauseSet(paused);
    }

    function queueSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert InvalidInput();
        pendingSigner = signer;
        signerReadyAt = uint64(block.timestamp + ORACLE_DELAY);
        emit SignerQueued(signer, signerReadyAt);
    }

    function cancelSigner() external onlyOwner {
        delete pendingSigner;
        delete signerReadyAt;
        emit SignerCancelled();
    }

    function executeSigner() external onlyOwner {
        if (signerReadyAt == 0) revert NoPendingChange();
        if (block.timestamp < signerReadyAt) revert TooEarly();
        address signer = pendingSigner;
        delete pendingSigner;
        delete signerReadyAt;
        _setOracleSigner(signer);
    }

    function queueDomainVersion(string calldata version) external onlyOwner {
        if (bytes(version).length == 0 || bytes(version).length > 32) revert InvalidInput();
        pendingDomainVersion = version;
        versionReadyAt = uint64(block.timestamp + ORACLE_DELAY);
        emit DomainVersionQueued(version, versionReadyAt);
    }

    function cancelDomainVersion() external onlyOwner {
        delete pendingDomainVersion;
        delete versionReadyAt;
        emit DomainVersionCancelled();
    }

    function executeDomainVersion() external onlyOwner {
        if (versionReadyAt == 0) revert NoPendingChange();
        if (block.timestamp < versionReadyAt) revert TooEarly();
        domainVersion = pendingDomainVersion;
        delete pendingDomainVersion;
        delete versionReadyAt;
        emit DomainVersionSet(domainVersion);
        emit EIP712DomainChanged();
    }

    function _hashTypedDataV4(bytes32 structHash) internal view override returns (bytes32) {
        bytes32 separator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("IdentityMD Oracle")),
                keccak256(bytes(domainVersion)),
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", separator, structHash));
    }

    function eip712Domain()
        public
        view
        override
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", "IdentityMD Oracle", domainVersion, block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    function isDenied(address payout) public view returns (bool) {
        return denyAt[payout] != 0 && block.timestamp >= denyAt[payout];
    }

    function queueDeny(address payout) external onlyOwner {
        if (payout == address(0) || denyAt[payout] != 0) revert InvalidInput();
        denyAt[payout] = uint64(block.timestamp + DENY_DELAY);
        emit DenyQueued(payout, denyAt[payout]);
    }

    /// @notice Cancels a pending addition or removes an active deny; active denials permanently revoke old streams.
    function removeDeny(address payout) external onlyOwner {
        if (denyAt[payout] == 0) revert NoPendingChange();
        if (isDenied(payout)) ++denyGeneration[payout];
        delete denyAt[payout];
        emit DenyRemoved(payout);
    }
}
