// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {SafeERC20Lib} from "vault-v2/libraries/SafeERC20Lib.sol";
import {IMorpho, Market, MarketParams, Position, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {
    BlueMarketConfig,
    MarketAccounting,
    MarketEconomicPolicy,
    SafeExit,
    SafeExitPayload
} from "./types/AdapterTypes.sol";
import {IBlueMidnightAdapter} from "./interfaces/IBlueMidnightAdapter.sol";
import {IMidnight, Market as MidnightMarket, Offer} from "midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS, MAX_CONTINUOUS_FEE, MAX_SETTLEMENT_FEE_360_DAYS} from "midnight/libraries/ConstantsLib.sol";
import {MAX_TICK} from "midnight/libraries/TickLib.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {RiskIdLib} from "./libraries/RiskIdLib.sol";

/// @title Blue Midnight adapter core
/// @notice The Stage 3, single-market productive sleeve for a Vault V2 adapter.
/// @dev Midnight callbacks and scalar conservative position accounting.
contract BlueMidnightAdapter is IBlueMidnightAdapter {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    error Unauthorized();
    error InvalidMarket();
    error LoanAssetMismatch();
    error DataNotTimelocked();
    error TimelockNotExpired();
    error DataAlreadyPending();
    error TimelockNotIncreasing();
    error TimelockNotDecreasing();
    error Abdicated();
    error InvalidValue();

    error InsufficientLiquidity();
    error UnsupportedData();
    error RiskOff();
    error InvalidCallback();
    error InvalidOffer();
    error MarketDisabled();
    error ExposureExceeded();
    error InsufficientCredit();
    error InvalidReceiver();
    error AccountingOverflow();
    error InvalidExitPayload();
    error ExitPriceTooLow();
    error ExitLossExceeded();
    error ExitMarketMismatch();
    error ExitOfferInvalid();
    error RepaymentUnavailable();

    event Submit(bytes4 indexed selector, bytes data, uint256 executableAt);
    event Accept(bytes4 indexed selector, bytes data);
    event Revoke(address indexed caller, bytes4 indexed selector, bytes data);
    event BlueMarketSet(bytes32 indexed marketId, MarketParams market);
    event QuoterSet(address indexed quoter, bool enabled);
    event PolicyEpochIncremented(uint64 indexed epoch, bytes32 reason);

    event Allocate(bytes32 indexed marketId, uint256 assets, uint256 shares);
    event Deallocate(bytes32 indexed marketId, uint256 assets, uint256 shares);
    event BuyFill(bytes32 indexed marketId, uint256 assets, uint256 units, uint256 bookValue);
    event SellFill(bytes32 indexed marketId, uint256 assets, uint256 units, int256 pnl);

    event MarketEconomicPolicySet(bytes32 indexed marketId, MarketEconomicPolicy policy, bool immediate);
    event RepaymentCollected(bytes32 indexed marketId, uint256 units, uint256 assets);
    event SafeExitExecuted(bytes32 indexed marketId, uint256 units, uint256 assets, uint256 loss);
    event MarketDisabledEvent(bytes32 indexed marketId);

    address public immutable factory;
    address public immutable parentVault;
    address public immutable asset;
    address public immutable midnight;
    address public immutable morphoBlue;
    address public immutable ratifier;
    bytes32 public immutable adapterId;

    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes4 selector => bool) public abdicated;
    mapping(bytes data => uint256) public executableAt;
    mapping(address account => bool) public isQuoter;

    BlueMarketConfig internal blue;
    bool public blueMarketConfigured;
    uint64 public policyEpoch;
    bool public riskOffActive;
    bytes4 internal constant DECREASE_TIMELOCK_SELECTOR = bytes4(keccak256("decreaseTimelock(bytes4,uint256)"));
    MidnightMarket internal pinnedMidnightMarket;
    bytes32 public immutable pinnedMidnightMarketId;
    bytes32 public immutable pinnedMidnightMarketHash;
    // Exactly one immutable Midnight market is configured, so accounting is scalar.
    MarketAccounting internal accountingState;
    bool public marketEnabled;
    MarketEconomicPolicy public marketEconomicPolicy;
    uint256 public maxExitLossAssets;
    uint24 public minExitBuyTick;
    bool internal safeExitInProgress;
    uint256 internal safeExitLastRemovedBook;

    constructor(
        address _parentVault,
        address _midnight,
        address _morphoBlue,
        address _ratifier,
        MidnightMarket memory _pinnedMidnightMarket
    ) {
        if (
            _parentVault == address(0) || _midnight == address(0) || _morphoBlue == address(0)
                || _pinnedMidnightMarket.midnight != _midnight || _pinnedMidnightMarket.loanToken == address(0)
                || _pinnedMidnightMarket.loanToken != IVaultV2(_parentVault).asset()
        ) revert InvalidValue();
        factory = msg.sender;
        parentVault = _parentVault;
        midnight = _midnight;
        morphoBlue = _morphoBlue;
        ratifier = _ratifier;
        pinnedMidnightMarket = _pinnedMidnightMarket;
        pinnedMidnightMarketId = IdLib.toId(_pinnedMidnightMarket);
        pinnedMidnightMarketHash = HashLib.hashMarket(_pinnedMidnightMarket);
        asset = IVaultV2(_parentVault).asset();
        adapterId = RiskIdLib.adapter(address(this));
        policyEpoch = 1;

        timelock[bytes4(keccak256("setBlueMarket((address,address,address,address,uint256))"))] = 2 days;

        timelock[bytes4(keccak256("setQuoter(address,bool)"))] = 2 days;

        timelock[bytes4(keccak256("setMarketEconomicPolicy((uint24,uint24,uint40,uint40,uint32,uint64,bool))"))] =
        2 days;
        timelock[bytes4(keccak256("setExitLossLimit(uint256)"))] = 2 days;
        SafeERC20Lib.safeApprove(asset, _morphoBlue, type(uint256).max);
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    modifier onlyParentVault() {
        if (msg.sender != parentVault) revert Unauthorized();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != IVaultV2(parentVault).curator()) revert Unauthorized();
        _;
    }

    modifier onlyCuratorOrSentinel() {
        if (msg.sender != IVaultV2(parentVault).curator() && !IVaultV2(parentVault).isSentinel(msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlySentinel() {
        if (!IVaultV2(parentVault).isSentinel(msg.sender)) revert Unauthorized();
        _;
    }

    function submit(bytes calldata data) external onlyCurator {
        if (executableAt[data] != 0) revert DataAlreadyPending();
        bytes4 selector = bytes4(data);
        uint256 delay = selector == DECREASE_TIMELOCK_SELECTOR ? timelock[bytes4(data[4:8])] : timelock[selector];
        executableAt[data] = block.timestamp + delay;
        emit Submit(selector, data, executableAt[data]);
    }

    function revoke(bytes calldata data) external onlyCuratorOrSentinel {
        if (executableAt[data] == 0) revert DataNotTimelocked();
        executableAt[data] = 0;
        emit Revoke(msg.sender, bytes4(data), data);
    }

    function _timelocked() internal {
        bytes4 selector = bytes4(msg.data);
        uint256 at = executableAt[msg.data];
        if (at == 0) revert DataNotTimelocked();
        if (block.timestamp < at) revert TimelockNotExpired();
        if (abdicated[selector]) revert Abdicated();
        executableAt[msg.data] = 0;
        emit Accept(selector, msg.data);
    }

    function increaseTimelock(bytes4 selector, uint256 duration) external onlyCurator {
        _timelocked();
        if (duration < timelock[selector]) revert TimelockNotIncreasing();
        timelock[selector] = duration;
    }

    function decreaseTimelock(bytes4 selector, uint256 duration) external onlyCurator {
        _timelocked();
        if (duration > timelock[selector]) revert TimelockNotDecreasing();
        timelock[selector] = duration;
    }

    function abdicate(bytes4 selector) external onlyCurator {
        _timelocked();
        abdicated[selector] = true;
    }

    function setBlueMarket(MarketParams calldata market) external onlyCurator {
        _timelocked();
        if (market.loanToken != asset) revert LoanAssetMismatch();
        if (blueMarketConfigured && blue.marketId != bytes32(0) && expectedSupplyAssets() != 0) revert InvalidValue();
        blue = BlueMarketConfig({market: market, marketId: Id.unwrap(market.id())});
        blueMarketConfigured = true;
        _bumpEpoch("blue-market");
        emit BlueMarketSet(blue.marketId, market);
    }

    function setQuoter(address quoter, bool enabled) external onlyCurator {
        _timelocked();
        if (quoter == address(0)) revert InvalidValue();
        isQuoter[quoter] = enabled;
        _bumpEpoch(enabled ? bytes32("quoter-add") : bytes32("quoter-remove"));
        emit QuoterSet(quoter, enabled);
    }

    function approveRoot(bytes32 root) external {
        if (!isQuoter[msg.sender] || root == bytes32(0)) revert Unauthorized();
        (bool success,) =
            ratifier.call(abi.encodeWithSignature("setRoot(address,bytes32,bool)", address(this), root, true));
        if (!success) revert InvalidCallback();
    }

    function revokeRoot(bytes32 root) external {
        if (!isQuoter[msg.sender] || root == bytes32(0)) revert Unauthorized();
        (bool success,) =
            ratifier.call(abi.encodeWithSignature("setRoot(address,bytes32,bool)", address(this), root, false));
        if (!success) revert InvalidCallback();
    }

    /// @notice Sets a per-Midnight-market economic policy after the curator timelock.
    /// @dev This is required for initial configuration and any loosening of economic limits.
    function setMarketEconomicPolicy(MarketEconomicPolicy calldata policy) external onlyCurator {
        _timelocked();
        _validateEconomicPolicy(policy);
        marketEconomicPolicy = policy;
        marketEnabled = policy.configured;
        _bumpEpoch("economic-policy-set");
        emit MarketEconomicPolicySet(pinnedMidnightMarketId, policy, false);
    }

    /// @notice Allows the curator or sentinel to immediately make a configured market strictly safer.
    function tightenMarketEconomicPolicy(MarketEconomicPolicy calldata policy) external onlyCuratorOrSentinel {
        MarketEconomicPolicy memory current = marketEconomicPolicy;
        if (!current.configured) revert InvalidValue();
        _validateEconomicPolicy(policy);
        if (
            policy.maxBuyTick > current.maxBuyTick || policy.minSellTick < current.minSellTick
                || policy.maxTenor > current.maxTenor || policy.maxExpiryHorizon > current.maxExpiryHorizon
                || policy.maxContinuousFeePerSecondWad > current.maxContinuousFeePerSecondWad
                || policy.maxSettlementFeeWad > current.maxSettlementFeeWad
        ) revert InvalidValue();
        if (
            policy.maxBuyTick == current.maxBuyTick && policy.minSellTick == current.minSellTick
                && policy.maxTenor == current.maxTenor && policy.maxExpiryHorizon == current.maxExpiryHorizon
                && policy.maxContinuousFeePerSecondWad == current.maxContinuousFeePerSecondWad
                && policy.maxSettlementFeeWad == current.maxSettlementFeeWad
        ) revert InvalidValue();
        marketEconomicPolicy = policy;
        _bumpEpoch("economic-policy-tighten");
        emit MarketEconomicPolicySet(pinnedMidnightMarketId, policy, true);
    }

    function revokeQuoter(address quoter) external onlySentinel {
        if (quoter == address(0)) revert InvalidValue();
        isQuoter[quoter] = false;
        _bumpEpoch("quoter-revoke");
        emit QuoterSet(quoter, false);
    }

    /// @dev Sentinel-only risk-off hook. It cannot expand any bound.
    function riskOff(bytes32 reason) external onlySentinel {
        riskOffActive = true;
        unchecked {
            ++policyEpoch;
        }
        emit PolicyEpochIncremented(policyEpoch, reason);
    }

    /// @notice Disable one market immediately while retaining recovery paths.
    function disableMarket() external onlySentinel {
        marketEnabled = false;
        _bumpEpoch("market-risk-off");
        emit MarketDisabledEvent(pinnedMidnightMarketId);
    }

    function setExitLossLimit(uint256 newLimit) external onlyCurator {
        _timelocked();
        if (newLimit < maxExitLossAssets) revert InvalidValue();
        maxExitLossAssets = newLimit;
        _bumpEpoch("exit-loss-limit");
    }

    function lowerExitLossLimit(uint256 newLimit) external onlySentinel {
        if (newLimit > maxExitLossAssets) revert InvalidValue();
        maxExitLossAssets = newLimit;
        _bumpEpoch("exit-loss-limit-lower");
    }

    function setMinExitBuyTick(uint24 newTick) external onlyCurator {
        _timelocked();
        if (newTick < minExitBuyTick || newTick > MAX_TICK) revert InvalidValue();
        minExitBuyTick = newTick;
        _bumpEpoch("exit-price-limit");
    }

    function tightenMinExitBuyTick(uint24 newTick) external onlyCuratorOrSentinel {
        if (newTick < minExitBuyTick || newTick > MAX_TICK) revert InvalidValue();
        minExitBuyTick = newTick;
        _bumpEpoch("exit-price-limit-tighten");
    }

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyParentVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (!blueMarketConfigured || data.length == 0) revert InvalidMarket();
        if (riskOffActive && assets != 0) revert RiskOff();
        MarketParams memory market = abi.decode(data, (MarketParams));
        if (Id.unwrap(market.id()) != blue.marketId) revert InvalidMarket();
        uint256 oldAssets = expectedSupplyAssets();
        uint256 mintedShares;
        if (assets != 0) {
            (, mintedShares) = IMorpho(morphoBlue).supply(market, assets, 0, address(this), hex"");
        }
        uint256 newAssets = expectedSupplyAssets();
        ids = _ids();
        change = int256(newAssets) - int256(oldAssets);
        emit Allocate(blue.marketId, assets, mintedShares);
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyParentVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (!blueMarketConfigured || data.length == 0) revert InvalidMarket();
        MarketParams memory market;
        SafeExitPayload memory payload;
        bool hasExitPayload;
        // A version byte is encoded as the first ABI word. Legacy market-only
        // data remains accepted for callers from the preceding stack layer.
        uint256 firstWord;
        assembly {
            firstWord := mload(add(data, 32))
        }
        if (data.length >= 32 && firstWord <= type(uint8).max) {
            if (firstWord != 1) revert InvalidExitPayload();
            (uint8 version, SafeExit[] memory exits, uint256 maxLossAssets) =
                abi.decode(data, (uint8, SafeExit[], uint256));
            payload = SafeExitPayload(version, exits, maxLossAssets);
            if (payload.version != 1) revert InvalidExitPayload();
            market = blue.market;
            hasExitPayload = true;
        } else {
            market = abi.decode(data, (MarketParams));
        }
        if (Id.unwrap(market.id()) != blue.marketId) revert InvalidMarket();
        uint256 oldAssets = expectedSupplyAssets();
        uint256 withdrawn;
        uint256 burnedShares;
        if (assets != 0) {
            try IMorpho(morphoBlue).withdraw(market, assets, 0, address(this), address(this)) returns (
                uint256 blueWithdrawn, uint256 blueBurnedShares
            ) {
                withdrawn = blueWithdrawn;
                burnedShares = blueBurnedShares;
            } catch {
                if (!hasExitPayload) revert InsufficientLiquidity();
                _executeSafeExits(payload, assets);
                (withdrawn, burnedShares) =
                    IMorpho(morphoBlue).withdraw(market, assets, 0, address(this), address(this));
            }
            if (withdrawn != assets) revert InsufficientLiquidity();
        }
        uint256 newAssets = expectedSupplyAssets();
        ids = _ids();
        change = int256(newAssets) - int256(oldAssets);
        emit Deallocate(blue.marketId, withdrawn, burnedShares);
    }

    /// @notice Permissionless collection of available Midnight repayments.
    /// @dev This path is intentionally available while risk-off is active.
    function collectRepayments(uint256 requestedUnits) external returns (uint256 totalAssets) {
        if (!marketKnown(pinnedMidnightMarketHash)) revert InvalidMarket();
        uint256 units = requestedUnits;
        uint256 available = IMidnight(midnight).withdrawable(pinnedMidnightMarketId);
        if (units == 0 || units > available) units = available;
        if (units == 0) return 0;
        _checkpoint(pinnedMidnightMarketHash, pinnedMidnightMarket, 0, 0);
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IMidnight(midnight).withdraw(pinnedMidnightMarket, units, address(this), address(this));
        uint256 received = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert RepaymentUnavailable();
        _reduceCreditAfterRecovery(pinnedMidnightMarketHash, units);
        (uint256 supplied,) = IMorpho(morphoBlue).supply(blue.market, received, 0, address(this), hex"");
        if (supplied != received) revert InvalidCallback();
        totalAssets += received;
        emit RepaymentCollected(pinnedMidnightMarketHash, units, received);
        totalAssets = received;
    }

    function realAssets() external view returns (uint256) {
        uint256 value = IERC20(asset).balanceOf(address(this)) + expectedSupplyAssets();
        value += _conservativeBookValue();
        return value;
    }

    function expectedSupplyAssets() public view returns (uint256) {
        if (!blueMarketConfigured) return 0;
        IMorpho morpho = IMorpho(morphoBlue);
        Position memory position = morpho.position(Id.wrap(blue.marketId), address(this));
        if (position.supplyShares == 0) return 0;
        Market memory market = morpho.market(Id.wrap(blue.marketId));
        return position.supplyShares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);
    }

    function blueMarket() external view returns (MarketParams memory market, bytes32 marketId) {
        return (blue.market, blue.marketId);
    }

    function blueAvailableLiquidity() public view returns (uint256) {
        if (!blueMarketConfigured) return 0;
        Market memory market = IMorpho(morphoBlue).market(Id.wrap(blue.marketId));
        uint256 cash = IERC20(asset).balanceOf(morphoBlue);
        uint256 available = market.totalSupplyAssets > market.totalBorrowAssets
            ? market.totalSupplyAssets - market.totalBorrowAssets
            : 0;
        return cash < available ? cash : available;
    }

    function buyerAssetsBound(bytes32 midnightMarketId) public view returns (uint256) {
        if (midnightMarketId != pinnedMidnightMarketHash || riskOffActive) return 0;
        uint256 bound = IVaultV2(parentVault).allocation(adapterId);
        uint256 adapterLiquidity = expectedSupplyAssets();
        if (bound > adapterLiquidity) bound = adapterLiquidity;
        uint256 liquidity = blueAvailableLiquidity();
        if (bound > liquidity) bound = liquidity;
        return bound;
    }

    /// @notice Return the scalar accounting record for the immutable market.
    function accounting() external view returns (MarketAccounting memory) {
        return accountingState;
    }

    function acceptsOffer(Offer calldata offer) external view returns (bool) {
        if (offer.maker != address(this) || offer.ratifier != ratifier || offer.callback != address(this)) {
            return false;
        }
        if (
            offer.market.midnight != midnight || offer.market.chainId != block.chainid
                || offer.market.loanToken != asset
        ) return false;
        bytes32 marketId = HashLib.hashMarket(offer.market);
        bytes32 protocolMarketId = IdLib.toId(offer.market);
        MarketEconomicPolicy memory policy = marketEconomicPolicy;
        if (
            marketId != pinnedMidnightMarketHash || !marketEnabled || !policy.configured
                || offer.start > block.timestamp
        ) {
            return false;
        }
        if (
            offer.market.maturity <= block.timestamp || offer.expiry < block.timestamp
                || offer.expiry >= offer.market.maturity
        ) {
            return false;
        }
        if (
            offer.market.maturity - block.timestamp > policy.maxTenor
                || offer.expiry - block.timestamp > policy.maxExpiryHorizon
        ) return false;
        if (offer.tick > MAX_TICK || offer.continuousFeeCap > MAX_CONTINUOUS_FEE) return false;
        if (offer.group != keccak256(abi.encode(address(this), policyEpoch))) return false;
        if (offer.continuousFeeCap > policy.maxContinuousFeePerSecondWad) return false;
        if (IMidnight(midnight).continuousFee(protocolMarketId) > offer.continuousFeeCap) return false;
        if (
            IMidnight(midnight).settlementFee(protocolMarketId, offer.market.maturity - block.timestamp)
                > policy.maxSettlementFeeWad
        ) {
            return false;
        }
        if (offer.buy) {
            return offer.maxAssets > 0 && offer.maxUnits == 0
                && offer.maxAssets <= buyerAssetsBound(pinnedMidnightMarketHash) && offer.tick <= policy.maxBuyTick
                && offer.receiverIfMakerIsSeller == address(0) && !offer.reduceOnly && offer.callbackData.length == 0;
        }
        return offer.maxAssets == 0 && offer.maxUnits > 0 && offer.tick >= policy.minSellTick
            && offer.receiverIfMakerIsSeller == address(this) && offer.reduceOnly && offer.callbackData.length == 0
            && offer.maxUnits <= accountingState.trackedCredit;
    }

    function _validateEconomicPolicy(MarketEconomicPolicy calldata policy) internal pure {
        if (
            !policy.configured || policy.maxBuyTick > MAX_TICK || policy.minSellTick > MAX_TICK || policy.maxTenor == 0
                || policy.maxExpiryHorizon == 0 || policy.maxExpiryHorizon > policy.maxTenor
                || policy.maxContinuousFeePerSecondWad > MAX_CONTINUOUS_FEE
                || policy.maxSettlementFeeWad > MAX_SETTLEMENT_FEE_360_DAYS
        ) revert InvalidValue();
    }

    function onBuy(
        bytes32 id,
        MidnightMarket memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes memory data
    ) external returns (bytes32) {
        if (msg.sender != midnight || buyer != address(this)) revert Unauthorized();
        bytes32 marketId = HashLib.hashMarket(market);
        if (
            id != IdLib.toId(market) || marketId != pinnedMidnightMarketHash || !marketEnabled
                || market.midnight != midnight || market.loanToken != asset
        ) {
            revert InvalidOffer();
        }
        _checkpoint(marketId, market, 0, 0);
        if (riskOffActive || buyerAssets > buyerAssetsBound(marketId)) revert ExposureExceeded();
        // The adapter has exactly one configured Blue route. Empty data is pinned so the offer cannot carry an
        // alternate routing payload that might diverge from the policy predicate.
        if (data.length != 0) revert InvalidCallback();
        if (!blueMarketConfigured) revert InvalidMarket();
        if (buyerAssets != 0) {
            (uint256 withdrawn,) =
                IMorpho(morphoBlue).withdraw(blue.market, buyerAssets, 0, address(this), address(this));
            if (withdrawn != buyerAssets) revert InsufficientLiquidity();
            SafeERC20Lib.safeApprove(asset, midnight, 0);
            SafeERC20Lib.safeApprove(asset, midnight, buyerAssets);
        }
        MarketAccounting storage a = accountingState;
        a.bookValue = _toUint128(uint256(a.bookValue) + buyerAssets);
        a.netMaturityClaim = _toUint128(uint256(a.netMaturityClaim) + buyerAssets + pendingFeeIncrease);
        a.trackedCredit = _toUint128(uint256(a.trackedCredit) + units);
        a.active = true;
        emit BuyFill(marketId, buyerAssets, units, a.bookValue);
        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32 id,
        MidnightMarket memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes memory data
    ) external returns (bytes32) {
        if (msg.sender != midnight || seller != address(this) || receiver != address(this)) {
            revert InvalidReceiver();
        }
        bytes32 marketId = HashLib.hashMarket(market);
        if (
            id != IdLib.toId(market) || marketId != pinnedMidnightMarketHash || (!marketEnabled && !safeExitInProgress)
                || market.loanToken != asset
        ) {
            revert InvalidOffer();
        }
        if (data.length != 0 || units == 0) revert InvalidCallback();
        uint256 postSaleClaim = _checkpoint(marketId, market, pendingFeeDecrease, units);
        MarketAccounting storage a = accountingState;
        if (units > a.trackedCredit || a.trackedCredit == 0) revert InsufficientCredit();
        uint256 oldBook = a.bookValue;
        uint256 reduction = oldBook * units / a.trackedCredit;
        a.bookValue = _toUint128(uint256(a.bookValue) - reduction);
        if (safeExitInProgress) safeExitLastRemovedBook = reduction;
        a.netMaturityClaim =
            _toUint128(uint256(a.netMaturityClaim) - uint256(a.netMaturityClaim) * units / a.trackedCredit);
        a.trackedCredit = _toUint128(uint256(a.trackedCredit) - units);
        // Midnight has already reduced seller credit and pending fee. The proportional reduction above applies
        // the sale once; only a stricter post-sale protocol claim may reduce the remaining claim further.
        if (postSaleClaim < a.netMaturityClaim) a.netMaturityClaim = _toUint128(postSaleClaim);
        int256 pnl = int256(sellerAssets) - int256(reduction);
        if (sellerAssets != 0) {
            (uint256 supplied,) = IMorpho(morphoBlue).supply(blue.market, sellerAssets, 0, address(this), hex"");
            if (supplied != sellerAssets) revert InvalidCallback();
        }
        if (a.trackedCredit == 0) {
            a.active = false;
            if (!marketEnabled) {}
        }
        emit SellFill(marketId, sellerAssets, units, pnl);
        return CALLBACK_SUCCESS;
    }

    function _executeSafeExits(SafeExitPayload memory payload, uint256) internal {
        if (payload.version != 1 || payload.exits.length == 0 || payload.maxLossAssets > maxExitLossAssets) {
            revert InvalidExitPayload();
        }
        uint256 realizedLoss;
        for (uint256 i; i < payload.exits.length; ++i) {
            SafeExit memory exit = payload.exits[i];
            Offer memory offer = exit.offer;
            bytes32 id = HashLib.hashMarket(offer.market);
            if (
                !offer.buy || offer.maker == address(this) || offer.callback != address(0)
                    || offer.receiverIfMakerIsSeller != address(0) || offer.callbackData.length != 0
                    || offer.ratifier == address(0) || offer.maxAssets == 0 || offer.maxUnits != 0
                    || offer.tick < minExitBuyTick || offer.market.midnight != midnight
                    || offer.market.loanToken != asset || offer.market.chainId != block.chainid
                    || offer.start > block.timestamp || offer.expiry < block.timestamp || !marketKnown(id)
                    || exit.units == 0 || exit.units > accountingState.trackedCredit
            ) revert ExitOfferInvalid();
            // For a maker-buy offer the taker is the seller. The only receiver
            // accepted by this adapter is itself; the callback is also fixed
            // so a quoter cannot inject a payer or receiver through calldata.
            safeExitLastRemovedBook = 0;
            safeExitInProgress = true;
            (, uint256 sellerAssets) = IMidnight(midnight)
                .take(offer, exit.ratifierData, exit.units, address(this), address(this), address(this), hex"");
            safeExitInProgress = false;
            uint256 saleLoss = safeExitLastRemovedBook > sellerAssets ? safeExitLastRemovedBook - sellerAssets : 0;
            realizedLoss += saleLoss;
            emit SafeExitExecuted(id, exit.units, sellerAssets, saleLoss);
        }
        if (realizedLoss > payload.maxLossAssets || realizedLoss > maxExitLossAssets) revert ExitLossExceeded();
    }

    function marketKnown(bytes32 marketId) public view returns (bool) {
        return marketId == pinnedMidnightMarketHash && (marketEnabled || accountingState.trackedCredit != 0);
    }

    function _reduceCreditAfterRecovery(bytes32 id, uint256 units) internal {
        if (id != pinnedMidnightMarketHash) revert InvalidMarket();
        MarketAccounting storage a = accountingState;
        if (units > a.trackedCredit || a.trackedCredit == 0) revert InsufficientCredit();
        uint256 oldCredit = a.trackedCredit;
        a.bookValue = _toUint128(uint256(a.bookValue) * (oldCredit - units) / oldCredit);
        a.netMaturityClaim = _toUint128(uint256(a.netMaturityClaim) * (oldCredit - units) / oldCredit);
        a.trackedCredit = _toUint128(oldCredit - units);
        if (a.trackedCredit == 0) {
            a.active = false;
            if (!marketEnabled) {}
        }
    }

    function _checkpoint(bytes32, MidnightMarket memory market, uint256 feeDecrease, uint256 soldUnits)
        internal
        returns (uint256 postSaleClaim)
    {
        MarketAccounting storage a = accountingState;
        if (a.active && a.trackedCredit != 0) {
            (uint128 credit, uint128 pendingFee,) =
                IMidnight(midnight).updatePositionView(market, IdLib.toId(market), address(this));
            uint256 preSaleCredit = uint256(credit) + soldUnits;
            if (preSaleCredit < a.trackedCredit) {
                uint256 oldCredit = a.trackedCredit;
                a.bookValue = _toUint128(uint256(a.bookValue) * preSaleCredit / oldCredit);
                a.netMaturityClaim = _toUint128(uint256(a.netMaturityClaim) * preSaleCredit / oldCredit);
                a.trackedCredit = _toUint128(preSaleCredit);
            }
            postSaleClaim = uint256(credit) + pendingFee;
            if (soldUnits == 0 && postSaleClaim < a.netMaturityClaim) a.netMaturityClaim = _toUint128(postSaleClaim);
        }
        uint256 checkpoint = a.lastCheckpoint == 0 ? block.timestamp : a.lastCheckpoint;
        if (block.timestamp > checkpoint && a.netMaturityClaim > a.bookValue && market.maturity > checkpoint) {
            uint256 elapsed = (block.timestamp < market.maturity ? block.timestamp : market.maturity) - checkpoint;
            uint256 duration = market.maturity - checkpoint;
            a.bookValue = _toUint128(uint256(a.bookValue) + (a.netMaturityClaim - a.bookValue) * elapsed / duration);
        }
        if (soldUnits == 0) {
            if (feeDecrease >= a.netMaturityClaim) a.netMaturityClaim = 0;
            else a.netMaturityClaim = _toUint128(uint256(a.netMaturityClaim) - feeDecrease);
        }
        a.lastCheckpoint = uint40(block.timestamp < market.maturity ? block.timestamp : market.maturity);
    }

    function _conservativeBookValue() internal view returns (uint256) {
        MarketAccounting memory a = accountingState;
        if (!a.active || a.trackedCredit == 0) return a.bookValue;
        MidnightMarket memory market = pinnedMidnightMarket;
        (uint128 credit, uint128 pendingFee,) =
            IMidnight(midnight).updatePositionView(market, IdLib.toId(market), address(this));
        uint256 claim = uint256(credit) + uint256(pendingFee);
        uint256 synchronizedClaim = claim < a.netMaturityClaim ? claim : a.netMaturityClaim;
        uint256 accrued = a.bookValue;
        if (block.timestamp > a.lastCheckpoint && market.maturity > a.lastCheckpoint && synchronizedClaim > accrued) {
            uint256 end = block.timestamp < market.maturity ? block.timestamp : market.maturity;
            accrued += (synchronizedClaim - accrued) * (end - a.lastCheckpoint) / (market.maturity - a.lastCheckpoint);
        }
        return accrued < synchronizedClaim ? accrued : synchronizedClaim;
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert AccountingOverflow();
        return uint128(value);
    }

    function _ids() internal view returns (bytes32[] memory result) {
        result = new bytes32[](4);
        result[0] = adapterId;
        result[1] = RiskIdLib.blue(blue.marketId);
        result[2] = RiskIdLib.midnight(midnight);
        result[3] = RiskIdLib.midnightMarket(pinnedMidnightMarketHash);
    }

    function _bumpEpoch(bytes32 reason) internal {
        unchecked {
            ++policyEpoch;
        }
        emit PolicyEpochIncremented(policyEpoch, reason);
    }
}
