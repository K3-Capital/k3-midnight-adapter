// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {SafeERC20Lib} from "vault-v2/libraries/SafeERC20Lib.sol";
import {IMorpho, Market, MarketParams, Position, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {BlueMarketConfig, MarketAccounting, MarketEconomicPolicy} from "./types/AdapterTypes.sol";
import {IBlueMidnightAdapter} from "./interfaces/IBlueMidnightAdapter.sol";
import {IMidnight, Market as MidnightMarket, Offer} from "midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/libraries/ConstantsLib.sol";
import {MAX_TICK} from "midnight/libraries/TickLib.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {RiskIdLib} from "./libraries/RiskIdLib.sol";
import {AccountingLib} from "./libraries/AccountingLib.sol";
import {OfferPolicyLib} from "./libraries/OfferPolicyLib.sol";

/// @title Blue Midnight adapter core
/// @notice The Stage 3, single-market productive sleeve for a Vault V2 adapter.
/// @dev Midnight callbacks and scalar conservative position accounting.
contract BlueMidnightAdapter is IBlueMidnightAdapter {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    error Unauthorized();
    error InvalidMarket();
    error LoanAssetMismatch();

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
    error RepaymentUnavailable();

    event RootApproverRevoked(address indexed rootApprover);
    event RecoveryRootApproved(bytes32 indexed root, uint64 indexed epoch);
    event PolicyEpochIncremented(uint64 indexed epoch, bytes32 reason);

    event Allocate(bytes32 indexed marketId, uint256 assets, uint256 shares);
    event Deallocate(bytes32 indexed marketId, uint256 assets, uint256 shares);
    event BuyFill(bytes32 indexed marketId, uint256 assets, uint256 units, uint256 bookValue);
    event SellFill(bytes32 indexed marketId, uint256 assets, uint256 units, int256 pnl);

    event MaxBuyTickUpdated(uint24 value, uint64 indexed epoch);
    event MinSellTickUpdated(uint24 value, uint64 indexed epoch);
    event MaxExpiryHorizonUpdated(uint40 value, uint64 indexed epoch);
    event RepaymentCollected(bytes32 indexed marketId, uint256 units, uint256 assets);
    event NewExposurePaused(bytes32 indexed marketId);

    address public immutable parentVault;
    address public immutable asset;
    address public immutable midnight;
    address public immutable morphoBlue;
    address public immutable ratifier;
    bytes32 public immutable adapterId;

    BlueMarketConfig internal blue;
    uint64 public policyEpoch;
    bool public newExposurePaused;

    MidnightMarket internal _pinnedMidnightMarket;
    bytes32 public immutable pinnedMidnightMarketId;
    bytes32 public immutable pinnedMidnightMarketHash;
    // Exactly one immutable Midnight market is configured, so accounting is scalar.
    MarketAccounting internal accountingState;
    MarketEconomicPolicy internal economicPolicy;
    address public immutable rootApprover;

    constructor(
        address _parentVault,
        MarketParams memory _blueMarket,
        address _midnight,
        address _morphoBlue,
        address _ratifier,
        MidnightMarket memory _market,
        MarketEconomicPolicy memory _economicPolicy,
        address _rootApprover
    ) {
        if (
            _parentVault == address(0) || _midnight == address(0) || _morphoBlue == address(0)
                || _market.midnight != _midnight || _market.loanToken == address(0)
                || _market.loanToken != IVaultV2(_parentVault).asset()
                || _blueMarket.loanToken != IVaultV2(_parentVault).asset() || _blueMarket.irm == address(0)
                || _ratifier == address(0) || _rootApprover == address(0)
        ) revert InvalidValue();
        parentVault = _parentVault;
        midnight = _midnight;
        morphoBlue = _morphoBlue;
        ratifier = _ratifier;
        blue = BlueMarketConfig({market: _blueMarket, marketId: Id.unwrap(_blueMarket.id())});

        _pinnedMidnightMarket = _market;
        pinnedMidnightMarketId = IdLib.toId(_market);
        pinnedMidnightMarketHash = HashLib.hashMarket(_market);
        asset = IVaultV2(_parentVault).asset();
        adapterId = RiskIdLib.adapter(address(this));
        _validateEconomicPolicy(_economicPolicy);
        economicPolicy = _economicPolicy;
        rootApprover = _rootApprover;
        policyEpoch = 1;
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

    function isRootApprover(address account) public view returns (bool) {
        return account == rootApprover && !newExposurePaused;
    }

    function approveRoot(bytes32 root) external {
        if (!isRootApprover(msg.sender) || root == bytes32(0)) revert Unauthorized();
        (bool success,) =
            ratifier.call(abi.encodeWithSignature("setRoot(address,bytes32,bool)", address(this), root, true));
        if (!success) revert InvalidCallback();
    }

    /// @notice Approves a root for reduce-only recovery after emergency invalidation.
    /// @dev Sentinel approval cannot reopen buys: the exposure pause is latched and acceptsOffer
    /// still applies the reduce-only predicate before the ratifier can accept a leaf.
    function approveRecoveryRoot(bytes32 root) external onlyCuratorOrSentinel {
        if (root == bytes32(0) || !newExposurePaused) revert InvalidValue();
        (bool success,) =
            ratifier.call(abi.encodeWithSignature("setRoot(address,bytes32,bool)", address(this), root, true));
        if (!success) revert InvalidCallback();
        emit RecoveryRootApproved(root, policyEpoch);
    }

    function revokeRoot(bytes32 root) external {
        if (msg.sender != rootApprover || root == bytes32(0)) revert Unauthorized();
        (bool success,) =
            ratifier.call(abi.encodeWithSignature("setRoot(address,bytes32,bool)", address(this), root, false));
        if (!success) revert InvalidCallback();
    }

    /// @notice Allows the curator to change a configured market policy value.
    function setMaxBuyTick(uint24 value) external onlyCurator {
        if (value > MAX_TICK || value == economicPolicy.maxBuyTick) revert InvalidValue();
        economicPolicy.maxBuyTick = value;
        _bumpEpoch("max-buy-tick");
        emit MaxBuyTickUpdated(value, policyEpoch);
    }

    function setMinSellTick(uint24 value) external onlyCurator {
        if (value > MAX_TICK || value == economicPolicy.minSellTick) revert InvalidValue();
        economicPolicy.minSellTick = value;
        _bumpEpoch("min-sell-tick");
        emit MinSellTickUpdated(value, policyEpoch);
    }

    function setMaxExpiryHorizon(uint40 value) external onlyCurator {
        if (value == 0 || value == economicPolicy.maxExpiryHorizon) revert InvalidValue();
        economicPolicy.maxExpiryHorizon = value;
        _bumpEpoch("max-expiry-horizon");
        emit MaxExpiryHorizonUpdated(value, policyEpoch);
    }

    function pauseNewExposure(bytes32 reason) external onlySentinel {
        if (newExposurePaused) revert InvalidValue();
        newExposurePaused = true;
        _bumpEpoch(reason);
        emit NewExposurePaused(pinnedMidnightMarketId);
    }

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyParentVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (data.length == 0) revert InvalidMarket();
        if (newExposurePaused && assets != 0) revert RiskOff();
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
        if (data.length == 0) revert InvalidMarket();
        MarketParams memory market = abi.decode(data, (MarketParams));
        if (Id.unwrap(market.id()) != blue.marketId) revert InvalidMarket();
        uint256 withdrawn;
        uint256 burnedShares;
        if (assets != 0) {
            uint256 cash = IERC20(asset).balanceOf(address(this));
            if (cash < assets) {
                uint256 needed = assets - cash;
                (withdrawn, burnedShares) =
                    IMorpho(morphoBlue).withdraw(market, needed, 0, address(this), address(this));
                if (withdrawn != needed) revert InsufficientLiquidity();
            }
        }
        ids = _ids();
        // Vault pulls the full requested amount from the adapter, including adapter cash.
        change = -int256(assets);
        emit Deallocate(blue.marketId, withdrawn, burnedShares);
    }

    /// @notice Permissionless collection of available Midnight repayments.
    /// @dev This path is intentionally available while the exposure pause is active.
    function collectRepayment(uint256 requestedUnits) external returns (uint256 totalAssets) {
        if (HashLib.hashMarket(_pinnedMidnightMarket) != pinnedMidnightMarketHash) revert InvalidMarket();
        _checkpoint(pinnedMidnightMarketHash, _pinnedMidnightMarket, 0, 0);
        uint256 units = requestedUnits;
        uint256 available = IMidnight(midnight).withdrawable(pinnedMidnightMarketId);
        uint256 credit = accountingState.trackedCredit;
        if (available > credit) available = credit;
        if (units == 0 || units > available) units = available;
        if (units == 0) revert RepaymentUnavailable();
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IMidnight(midnight).withdraw(_pinnedMidnightMarket, units, address(this), address(this));
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
        return IERC20(asset).balanceOf(address(this)) + expectedSupplyAssets() + _conservativeBookValue();
    }

    /// @notice Immediate liquidity available to satisfy a Vault withdrawal.
    /// @dev Unlike realAssets, this excludes open Midnight face value and caps Blue assets by market cash.
    function immediateLiquidity() external view returns (uint256) {
        uint256 blueLiquidity = blueAvailableLiquidity();
        uint256 expected = expectedSupplyAssets();
        if (expected > blueLiquidity) expected = blueLiquidity;
        return IERC20(asset).balanceOf(address(this)) + expected;
    }

    function expectedSupplyAssets() public view returns (uint256) {
        IMorpho morpho = IMorpho(morphoBlue);
        Position memory position = morpho.position(Id.wrap(blue.marketId), address(this));
        if (position.supplyShares == 0) return 0;
        Market memory market = morpho.market(Id.wrap(blue.marketId));
        return position.supplyShares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);
    }

    function blueMarket() external view returns (MarketParams memory market, bytes32 marketId) {
        return (blue.market, blue.marketId);
    }

    function pinnedMidnightMarket() external view returns (MidnightMarket memory market) {
        return _pinnedMidnightMarket;
    }

    function marketEconomicPolicy() external view returns (MarketEconomicPolicy memory) {
        return economicPolicy;
    }

    function blueAvailableLiquidity() public view returns (uint256) {
        Market memory market = IMorpho(morphoBlue).market(Id.wrap(blue.marketId));
        uint256 cash = IERC20(asset).balanceOf(morphoBlue);
        uint256 available = market.totalSupplyAssets > market.totalBorrowAssets
            ? market.totalSupplyAssets - market.totalBorrowAssets
            : 0;
        return cash < available ? cash : available;
    }

    function buyerAssetsBound(bytes32 midnightMarketId) public view returns (uint256) {
        if (midnightMarketId != pinnedMidnightMarketHash || newExposurePaused) return 0;
        uint256 bound = IVaultV2(parentVault).allocation(adapterId);
        uint256 adapterLiquidity = expectedSupplyAssets();
        if (bound > adapterLiquidity) bound = adapterLiquidity;
        return bound;
    }

    /// @notice Return the scalar accounting record for the immutable market.
    function accounting() external view returns (MarketAccounting memory) {
        return accountingState;
    }

    function acceptsOffer(Offer calldata offer) public view returns (bool) {
        if (offer.maker != address(this) || offer.ratifier != ratifier || offer.callback != address(this)) {
            return false;
        }
        if (
            offer.market.chainId != block.chainid
                || !OfferPolicyLib.isExactMarket(offer, pinnedMidnightMarketHash, midnight, asset)
        ) return false;
        bytes32 marketId = HashLib.hashMarket(offer.market);
        MarketEconomicPolicy memory policy = economicPolicy;
        if (marketId != pinnedMidnightMarketHash || offer.start > block.timestamp) {
            return false;
        }
        if (
            offer.market.maturity <= block.timestamp || offer.expiry < block.timestamp
                || offer.expiry >= offer.market.maturity
        ) {
            return false;
        }
        if (offer.expiry - block.timestamp > policy.maxExpiryHorizon) return false;
        if (offer.tick > MAX_TICK || (newExposurePaused && offer.buy)) return false;
        if (offer.group != keccak256(abi.encode(address(this), policyEpoch))) return false;
        if (offer.buy) {
            return offer.maxAssets > 0 && offer.maxUnits == 0 && offer.tick <= policy.maxBuyTick
                && offer.receiverIfMakerIsSeller == address(0) && !offer.reduceOnly && offer.callbackData.length == 0;
        }
        return offer.maxAssets == 0 && offer.maxUnits > 0 && offer.tick >= policy.minSellTick
            && offer.receiverIfMakerIsSeller == address(this) && offer.reduceOnly && offer.callbackData.length == 0
            && offer.maxUnits <= accountingState.trackedCredit;
    }

    function _validateEconomicPolicy(MarketEconomicPolicy memory policy) internal pure {
        if (policy.maxBuyTick > MAX_TICK || policy.minSellTick > MAX_TICK || policy.maxExpiryHorizon == 0) {
            revert InvalidValue();
        }
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
            id != IdLib.toId(market) || marketId != pinnedMidnightMarketHash || market.midnight != midnight
                || market.loanToken != asset
        ) {
            revert InvalidOffer();
        }
        _checkpoint(marketId, market, 0, 0);
        if (newExposurePaused || buyerAssets > buyerAssetsBound(marketId)) revert ExposureExceeded();
        // The adapter has exactly one configured Blue route. Empty data is pinned so the offer cannot carry an
        // alternate routing payload that might diverge from the policy predicate.
        if (data.length != 0) revert InvalidCallback();

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
        if (id != IdLib.toId(market) || marketId != pinnedMidnightMarketHash || market.loanToken != asset) {
            revert InvalidOffer();
        }
        if (data.length != 0 || units == 0) revert InvalidCallback();
        uint256 postSaleClaim = _checkpoint(marketId, market, pendingFeeDecrease, units);
        MarketAccounting storage a = accountingState;
        if (units > a.trackedCredit || a.trackedCredit == 0) revert InsufficientCredit();
        uint256 oldBook = a.bookValue;
        uint256 reduction = AccountingLib.proportionalDown(oldBook, units, a.trackedCredit);
        a.bookValue = _toUint128(uint256(a.bookValue) - reduction);
        a.netMaturityClaim = _toUint128(
            uint256(a.netMaturityClaim) - AccountingLib.proportionalDown(a.netMaturityClaim, units, a.trackedCredit)
        );
        a.trackedCredit = _toUint128(uint256(a.trackedCredit) - units);
        // Midnight has already reduced seller credit and pending fee. The proportional reduction above applies
        // the sale once; only a stricter post-sale protocol claim may reduce the remaining claim further.
        if (postSaleClaim < a.netMaturityClaim) {
            a.netMaturityClaim = _toUint128(postSaleClaim);
            if (postSaleClaim < a.bookValue) a.bookValue = _toUint128(postSaleClaim);
        }
        int256 pnl = int256(sellerAssets) - int256(reduction);
        if (sellerAssets != 0) {
            (uint256 supplied,) = IMorpho(morphoBlue).supply(blue.market, sellerAssets, 0, address(this), hex"");
            if (supplied != sellerAssets) revert InvalidCallback();
        }
        if (a.trackedCredit == 0) {
            a.active = false;
        }
        emit SellFill(marketId, sellerAssets, units, pnl);
        return CALLBACK_SUCCESS;
    }

    function _reduceCreditAfterRecovery(bytes32 id, uint256 units) internal {
        if (id != pinnedMidnightMarketHash) revert InvalidMarket();
        MarketAccounting storage a = accountingState;
        if (units > a.trackedCredit || a.trackedCredit == 0) revert InsufficientCredit();
        uint256 oldCredit = a.trackedCredit;
        a.bookValue = _toUint128(AccountingLib.proportionalDown(a.bookValue, oldCredit - units, oldCredit));
        a.netMaturityClaim =
            _toUint128(AccountingLib.proportionalDown(a.netMaturityClaim, oldCredit - units, oldCredit));
        a.trackedCredit = _toUint128(oldCredit - units);
        if (a.trackedCredit == 0) {
            a.active = false;
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
            // A current-credit impairment is a known loss, not deferred income. Clamp book value
            // immediately so a later buy cannot recover value that the protocol no longer supports.
            if (postSaleClaim < a.bookValue) a.bookValue = _toUint128(postSaleClaim);
        }
        a.lastCheckpoint = uint40(block.timestamp < market.maturity ? block.timestamp : market.maturity);
    }

    function _conservativeBookValue() internal view returns (uint256) {
        MarketAccounting memory a = accountingState;
        if (!a.active || a.trackedCredit == 0) return a.bookValue;
        MidnightMarket memory market = _pinnedMidnightMarket;
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
