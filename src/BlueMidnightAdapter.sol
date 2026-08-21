// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {SafeERC20Lib} from "vault-v2/libraries/SafeERC20Lib.sol";
import {IMorpho, Market, MarketParams, Position, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {BlueMarketConfig} from "./types/AdapterTypes.sol";
import {IBlueMidnightAdapter} from "./interfaces/IBlueMidnightAdapter.sol";

/// @title Blue Midnight adapter core
/// @notice The Stage 3, single-market productive sleeve for a Vault V2 adapter.
/// @dev Midnight callbacks and position accounting are deliberately added in Stage 4.
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
    error ActiveMarketLimit();
    error ExposureLimit();
    error InsufficientLiquidity();
    error UnsupportedData();
    error RiskOff();

    event Submit(bytes4 indexed selector, bytes data, uint256 executableAt);
    event Accept(bytes4 indexed selector, bytes data);
    event Revoke(address indexed caller, bytes4 indexed selector, bytes data);
    event BlueMarketSet(bytes32 indexed marketId, MarketParams market);
    event QuoterSet(address indexed quoter, bool enabled);
    event PolicyEpochIncremented(uint64 indexed epoch, bytes32 reason);
    event ExposureCapsSet(uint256 globalCap, uint256 marketCap);
    event Allocate(bytes32 indexed marketId, uint256 assets, uint256 shares);
    event Deallocate(bytes32 indexed marketId, uint256 assets, uint256 shares);

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
    uint256 public maxActiveMarkets;
    uint256 public globalExposureCap;
    uint256 public targetExposureCap;
    uint64 public policyEpoch;
    bool public riskOffActive;
    bytes4 internal constant DECREASE_TIMELOCK_SELECTOR = bytes4(keccak256("decreaseTimelock(bytes4,uint256)"));
    bytes32[] internal activeMarketIds;
    mapping(bytes32 marketId => uint256 indexPlusOne) internal activeMarketIndex;

    constructor(address _parentVault, address _midnight, address _morphoBlue, address _ratifier) {
        if (_parentVault == address(0) || _midnight == address(0) || _morphoBlue == address(0)) revert InvalidValue();
        factory = msg.sender;
        parentVault = _parentVault;
        midnight = _midnight;
        morphoBlue = _morphoBlue;
        ratifier = _ratifier;
        asset = IVaultV2(_parentVault).asset();
        adapterId = keccak256(abi.encode("this", address(this)));
        policyEpoch = 1;
        maxActiveMarkets = 16;
        timelock[bytes4(keccak256("setBlueMarket((address,address,address,address,uint256))"))] = 2 days;
        timelock[bytes4(keccak256("setExposureCaps(uint256,uint256)"))] = 2 days;
        timelock[bytes4(keccak256("setQuoter(address,bool)"))] = 2 days;
        timelock[bytes4(keccak256("setMaxActiveMarkets(uint256)"))] = 2 days;
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

    function setExposureCaps(uint256 globalCap, uint256 marketCap) external onlyCurator {
        _timelocked();
        if (globalCap < globalExposureCap || marketCap < targetExposureCap) revert ExposureLimit();
        globalExposureCap = globalCap;
        targetExposureCap = marketCap;
        _bumpEpoch("caps-increase");
        emit ExposureCapsSet(globalCap, marketCap);
    }

    function setMaxActiveMarkets(uint256 newMax) external onlyCurator {
        _timelocked();
        if (newMax < maxActiveMarkets || newMax > 128) revert ActiveMarketLimit();
        maxActiveMarkets = newMax;
        _bumpEpoch("active-market-increase");
    }

    function lowerExposureCaps(uint256 globalCap, uint256 marketCap) external onlySentinel {
        if (globalCap > globalExposureCap || marketCap > targetExposureCap) revert ExposureLimit();
        globalExposureCap = globalCap;
        targetExposureCap = marketCap;
        _bumpEpoch("caps-lower");
    }

    function lowerMaxActiveMarkets(uint256 newMax) external onlySentinel {
        if (newMax > maxActiveMarkets || newMax > 128) revert ActiveMarketLimit();
        maxActiveMarkets = newMax;
        _bumpEpoch("active-market-lower");
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
        MarketParams memory market = abi.decode(data, (MarketParams));
        if (Id.unwrap(market.id()) != blue.marketId) revert InvalidMarket();
        uint256 oldAssets = expectedSupplyAssets();
        uint256 withdrawn;
        uint256 burnedShares;
        if (assets != 0) {
            (withdrawn, burnedShares) = IMorpho(morphoBlue).withdraw(market, assets, 0, address(this), address(this));
            if (withdrawn != assets) revert InsufficientLiquidity();
        }
        uint256 newAssets = expectedSupplyAssets();
        ids = _ids();
        change = int256(newAssets) - int256(oldAssets);
        emit Deallocate(blue.marketId, withdrawn, burnedShares);
    }

    function realAssets() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + expectedSupplyAssets();
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

    function buyerAssetsBound(bytes32) public view returns (uint256) {
        uint256 bound = expectedSupplyAssets();
        uint256 liquidity = blueAvailableLiquidity();
        if (bound > liquidity) bound = liquidity;
        uint256 exposure = _exposureCapacity();
        if (bound > exposure) bound = exposure;
        return bound;
    }

    function _exposureCapacity() internal view returns (uint256) {
        uint256 current = 0; // Stage 4 accounts Midnight positions; Stage 3 has no term exposure yet.
        if (riskOffActive || globalExposureCap == 0 || targetExposureCap == 0) return 0;
        uint256 capacity = globalExposureCap < targetExposureCap ? globalExposureCap : targetExposureCap;
        return capacity > current ? capacity - current : 0;
    }

    function _ids() internal view returns (bytes32[] memory result) {
        result = new bytes32[](3);
        result[0] = adapterId;
        result[1] = keccak256(abi.encode("morpho-blue", blue.marketId));
        result[2] = keccak256(abi.encode("midnight", midnight));
    }

    function activeMarketIdsLength() external view returns (uint256) {
        return activeMarketIds.length;
    }

    function activeMarketIdAt(uint256 index) external view returns (bytes32) {
        return activeMarketIds[index];
    }

    function isActiveMarket(bytes32 marketId) external view returns (bool) {
        return activeMarketIndex[marketId] != 0;
    }

    function registerActiveMarket(bytes32 marketId) external {
        if (msg.sender != midnight) revert Unauthorized();
        _addActiveMarket(marketId);
    }

    function unregisterActiveMarket(bytes32 marketId) external {
        if (msg.sender != midnight) revert Unauthorized();
        _removeActiveMarket(marketId);
    }

    function _addActiveMarket(bytes32 marketId) internal {
        if (activeMarketIndex[marketId] != 0) return;
        if (activeMarketIds.length >= maxActiveMarkets) revert ActiveMarketLimit();
        activeMarketIds.push(marketId);
        activeMarketIndex[marketId] = activeMarketIds.length;
    }

    function _removeActiveMarket(bytes32 marketId) internal {
        uint256 indexPlusOne = activeMarketIndex[marketId];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 last = activeMarketIds.length - 1;
        if (index != last) {
            bytes32 moved = activeMarketIds[last];
            activeMarketIds[index] = moved;
            activeMarketIndex[moved] = index + 1;
        }
        activeMarketIds.pop();
        delete activeMarketIndex[marketId];
    }

    function _bumpEpoch(bytes32 reason) internal {
        unchecked {
            ++policyEpoch;
        }
        emit PolicyEpochIncremented(policyEpoch, reason);
    }
}
