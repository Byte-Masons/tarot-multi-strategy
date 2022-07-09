// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./abstract/ReaperBaseStrategyv2.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IPoolToken.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

/**
 * @dev Deposits want in Tarot lending pools for the highest APRs.
 */
contract ReaperStrategyLendingOptimizer is ReaperBaseStrategyv2 {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    struct PoolAllocation {
        address poolAddress;
        uint256 allocation;
    }

    struct RouterPool {
        RouterType routerType;
        uint256 index;
    }

    enum RouterType {
        CLASSIC,
        REQUIEM
    }

    /**
     * Reaper Roles
     */
    bytes32 public constant KEEPER = keccak256("KEEPER");

    // 3rd-party contract addresses
    address public constant SPOOKY_ROUTER = address(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address public constant TAROT_ROUTER = address(0x283e62CFe14b352dB8e30A9575481DCbf589Ad98);
    address public constant TAROT_REQUIEM_ROUTER = address(0x3F7E61C5dd29F9380b270551e438B65c29183a7c);

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps.
     * {want} - Address of the token being lent
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant want = address(0x049d68029688eAbF473097a2fC38ef61633A3C7A);

    /**
     * @dev Tarot variables
     * {usedPools} - A set of pool addresses which are the authorized lending pools that can be used
     * {maxPools} - Sets the maximum amount of pools that can be added
     * {depositPool} - Address of the pool that regular deposits will go to
     * {sharePriceSnapshot} - Saves the pricePerFullShare to be compared between harvests to calculate profit
     * {minProfitToChargeFees} - The minimum amount of profit for harvest to charge fees
     * {withdrawSlippageTolerance} - Allows some very small slippage on withdraws to avoid reverts
     * {minWantToDepositOrWithdraw} - A minimum amount to deposit or withdraw from a pool (to save gas on very small amounts)
     * {maxWantRemainingToRemovePool} - Sets the allowed amount for a pool to have and still be removable (which will loose those funds)
     * {MAX_SLIPPAGE_TOLERANCE} - Sets a cap on the withdraw slippage tolerance 
     */
    EnumerableSetUpgradeable.AddressSet private usedPools;
    uint256 public maxPools;
    address public depositPool;
    uint256 public sharePriceSnapshot;
    uint256 public minProfitToChargeFees;
    uint256 public withdrawSlippageTolerance;
    uint256 public minWantToDepositOrWithdraw;
    uint256 public maxWantRemainingToRemovePool;
    bool public shouldHarvestOnDeposit;
    bool public shouldHarvestOnWithdraw;
    uint256 public constant MAX_SLIPPAGE_TOLERANCE = 100;

    /**
     * @dev Initializes the strategy. Sets parameters and saves routes.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        uint256 _initialPoolIndex,
        RouterType _routerType
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        sharePriceSnapshot = IVault(_vault).getPricePerFullShare();
        maxPools = 40;
        withdrawSlippageTolerance = 10;
        minProfitToChargeFees = 1e16;
        minWantToDepositOrWithdraw = 10;
        maxWantRemainingToRemovePool = 100;
        addUsedPool(_initialPoolIndex, _routerType);
        depositPool = usedPools.at(0); // Guarantees depositPool is always a Tarot pool
        shouldHarvestOnDeposit = true;
        shouldHarvestOnWithdraw = true;
    }

    /**
     * @dev Function that puts the funds to work.
     *      It gets called whenever someone deposits in the strategy's vault contract.
     */
    function _deposit() internal override {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance != 0) {
            IERC20Upgradeable(want).safeTransfer(depositPool, wantBalance);
            IBorrowable(depositPool).mint(address(this));
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     */
    function _withdraw(uint256 _amount) internal override {
        uint256 initialWithdrawAmount = _amount;
        uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBal < _amount) {
            uint256 withdrawn = _withdrawUnderlying(_amount - wantBal);
            if (withdrawn + wantBal < _amount) {
                _amount = withdrawn + wantBal;
            }
        }

        if (_amount < initialWithdrawAmount) {
            uint256 lowestAcceptableWithdrawAmount = (initialWithdrawAmount *
                (PERCENT_DIVISOR - withdrawSlippageTolerance)) / PERCENT_DIVISOR;
            require(_amount >= lowestAcceptableWithdrawAmount);
        }

        IERC20Upgradeable(want).safeTransfer(vault, _amount);
    }

    /**
     * @dev Withdraws a given amount by looping through all lending pools until enough want has been withdrawn
     */
    function _withdrawUnderlying(uint256 _amountToWithdraw) internal returns (uint256) {
        uint256 remainingUnderlyingNeeded = _amountToWithdraw;
        uint256 withdrawn = 0;

        uint256 nrOfPools = usedPools.length();
        for (uint256 index = 0; index < nrOfPools; index++) {
            address currentPool = usedPools.at(index);
            uint256 suppliedToPool = wantSuppliedToPool(currentPool);
            if (suppliedToPool < minWantToDepositOrWithdraw) {
                continue;
            }
            uint256 exchangeRate = IBorrowable(currentPool).exchangeRate();
            uint256 poolAvailableWant = IERC20Upgradeable(want).balanceOf(currentPool);
            uint256 ableToPullInUnderlying = MathUpgradeable.min(suppliedToPool, poolAvailableWant);
            uint256 underlyingToWithdraw = MathUpgradeable.min(remainingUnderlyingNeeded, ableToPullInUnderlying);

            if (underlyingToWithdraw < minWantToDepositOrWithdraw) {
                continue;
            }

            uint256 bTokenToWithdraw = (underlyingToWithdraw * 1 ether) / exchangeRate;

            IBorrowable(currentPool).transfer(currentPool, bTokenToWithdraw);
            withdrawn += IBorrowable(currentPool).redeem(address(this));

            if (withdrawn >= _amountToWithdraw - minWantToDepositOrWithdraw) {
                break;
            }

            remainingUnderlyingNeeded = _amountToWithdraw - withdrawn;
        }
        return withdrawn;
    }

    /**
     * @dev Takes a list of pool allocations and deposits into the lending pools accordingly
     */
    function rebalance(PoolAllocation[] calldata _allocations) external {
        _onlyKeeper();
        _reclaimWant(); // Withdraw old deposits to deposit the new allocation
        uint256 nrOfAllocations = _allocations.length;
        for (uint256 index = 0; index < nrOfAllocations; index++) {
            address pool = _allocations[index].poolAddress;
            require(usedPools.contains(pool), "Pool is not authorized");

            // Save the top APR pool to deposit in to
            if (index == 0) {
                depositPool = pool;
            }

            uint256 wantAvailable = IERC20Upgradeable(want).balanceOf(address(this));
            if (wantAvailable == 0) {
                return;
            }
            uint256 allocation = _allocations[index].allocation;
            uint256 depositAmount = MathUpgradeable.min(wantAvailable, allocation);
            IERC20Upgradeable(want).safeTransfer(pool, depositAmount);
            IBorrowable(pool).mint(address(this));
        }
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > minWantToDepositOrWithdraw) {
            IERC20Upgradeable(want).safeTransfer(depositPool, wantBalance);
            IBorrowable(depositPool).mint(address(this));
        }
    }

    /**
     * @dev Harvest is not strictly necessary since only fees are claimed
     *      but it is kept here for compatibility
     *      1. Claims fees for the harvest caller and treasury.
     */
    function _harvestCore() internal override {
        _chargeFees();
    }

    /**
     * @dev Core harvest function.
     *      Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal {
        updateExchangeRates();
        uint256 profit = profitSinceHarvest();
        if (profit >= minProfitToChargeFees) {
            uint256 fee = (profit * totalFee) / PERCENT_DIVISOR;
            IERC20Upgradeable wftm = IERC20Upgradeable(WFTM);

            if (fee != 0) {
                uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
                if (wantBal < fee) {
                    uint256 withdrawn = _withdrawUnderlying(fee - wantBal);
                    if (withdrawn + wantBal < fee) {
                        fee = withdrawn + wantBal;
                    }
                }
                _swap(want, WFTM, fee);
                uint256 wftmBalance = IERC20Upgradeable(WFTM).balanceOf(address(this));
                uint256 callFeeToUser = (wftmBalance * callFee) / PERCENT_DIVISOR;
                uint256 treasuryFeeToVault = (wftmBalance * treasuryFee) / PERCENT_DIVISOR;
                uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
                treasuryFeeToVault -= feeToStrategist;

                wftm.safeTransfer(msg.sender, callFeeToUser);
                wftm.safeTransfer(treasury, treasuryFeeToVault);
                wftm.safeTransfer(strategistRemitter, feeToStrategist);
                sharePriceSnapshot = IVault(vault).getPricePerFullShare();
            }
        }
    }

    /**
     * @dev Helper function to swap tokens given {_from}, {_to} and {_amount}
     */
    function _swap(
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        if (_from == _to || _amount == 0) {
            return;
        }

        address[] memory path = new address[](2);
        path[0] = _from;
        path[1] = _to;
        IERC20Upgradeable(_from).safeIncreaseAllowance(SPOOKY_ROUTER, _amount);
        IUniswapV2Router02(SPOOKY_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    /**
     * @dev Updates the borrowable exchangerate to update the interest earned
     */
    function updateExchangeRates() public {
        uint256 nrOfPools = usedPools.length();
        for (uint256 index = 0; index < nrOfPools; index++) {
            address pool = usedPools.at(index);
            uint256 bTokenBalance = IBorrowable(pool).balanceOf(address(this));
            // Checking the borrowable balance here for gas efficiency, even though it is not strictly correct
            if (bTokenBalance >= minWantToDepositOrWithdraw) {
                // Only update where some want is deposited
                IBorrowable(pool).exchangeRate();
            }
        }
    }

    /**
     * @dev Function to calculate the total {want} held by the strat.
     *      It takes into account both the funds in hand, plus the funds in the lending pools.
     */
    function balanceOf() public view override returns (uint256) {
        return balanceOfWant() + balanceOfPools();
    }

    /**
     * @dev Returns the amount of want available in the strategy
     */
    function balanceOfWant() public view returns (uint256) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    /**
     * @dev Returns the amount of want supplied to all lending pools
     */
    function balanceOfPools() public view returns (uint256 poolBalance) {
        uint256 nrOfPools = usedPools.length();
        for (uint256 index = 0; index < nrOfPools; index++) {
            poolBalance += wantSuppliedToPool(usedPools.at(index));
        }
    }

    /**
     * @dev Returns the address for all the currently used pools
     */
    function getUsedPools() external view returns (address[] memory) {
        uint256 nrOfPools = usedPools.length();
        address[] memory pools = new address[](nrOfPools);

        for (uint256 index = 0; index < nrOfPools; index++) {
            address poolAddress = usedPools.at(index);
            pools[index] = poolAddress;
        }
        return pools;
    }

    /**
     * @dev Returns the balance supplied to each pool
     */
    function getSuppliedToPools() external view returns (uint256[] memory) {
        uint256 nrOfPools = usedPools.length();
        uint256[] memory supplied = new uint256[](nrOfPools);

        for (uint256 index = 0; index < nrOfPools; index++) {
            address poolAddress = usedPools.at(index);
            uint256 suppliedToPool = wantSuppliedToPool(poolAddress);
            supplied[index] = suppliedToPool;
        }
        return supplied;
    }

    /**
     * @dev Returns the total withdrawable balance from all pools
     */
    function getAvailableBalance() external view returns (uint256 availableBalance) {
        uint256 nrOfPools = usedPools.length();
        for (uint256 index = 0; index < nrOfPools; index++) {
            address poolAddress = usedPools.at(index);
            uint256 suppliedToPool = wantSuppliedToPool(poolAddress);
            uint256 poolAvailableWant = IERC20Upgradeable(want).balanceOf(poolAddress);

            availableBalance += MathUpgradeable.min(suppliedToPool, poolAvailableWant);
        }
    }

    /**
     * @dev Returns the amount of want supplied to each specific pool
     */
    function getPoolBalances() external view returns (PoolAllocation[] memory) {
        uint256 nrOfPools = usedPools.length();
        PoolAllocation[] memory poolBalances = new PoolAllocation[](nrOfPools);

        for (uint256 index = 0; index < nrOfPools; index++) {
            address poolAddress = usedPools.at(index);
            uint256 wantInPool = wantSuppliedToPool(poolAddress);
            PoolAllocation memory poolBalance = PoolAllocation(poolAddress, wantInPool);
            poolBalances[index] = (poolBalance);
        }
        return poolBalances;
    }

    /**
     * @dev Returns the amount of want supplied to a lending pool.
     */
    function wantSuppliedToPool(address _pool) public view returns (uint256 wantBal) {
        uint256 bTokenBalance = IBorrowable(_pool).balanceOf(address(this));
        uint256 currentExchangeRate = IBorrowable(_pool).exchangeRateLast();
        wantBal = (bTokenBalance * currentExchangeRate) / 1 ether;
    }

    /**
     * @dev Returns the approx amount of profit in want since latest harvest
     */
    function profitSinceHarvest() public view returns (uint256 profit) {
        uint256 ppfs = IVault(vault).getPricePerFullShare();
        if (ppfs <= sharePriceSnapshot) {
            return 0;
        }
        uint256 sharePriceChange = ppfs - sharePriceSnapshot;
        profit = (balanceOf() * sharePriceChange) / 1 ether;
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        uint256 profitInWant = profitSinceHarvest();
        if (profitInWant != 0) {
            address[] memory path = new address[](2);
            path[0] = want;
            path[1] = WFTM;
            profit += IUniswapV2Router02(SPOOKY_ROUTER).getAmountsOut(profitInWant, path)[1];
        }

        profit += IERC20Upgradeable(WFTM).balanceOf(address(this));
        
        uint256 fee = (profit * totalFee) / PERCENT_DIVISOR;
        callFeeToUser = (fee * callFee) / PERCENT_DIVISOR;
        profit -= fee;
    }

    /**
     * @dev Function to retire the strategy. Claims all rewards and withdraws
     *      all principal from external contracts, and sends everything back to
     *      the vault. Can only be called by strategist or owner.
     *
     * Note: this is not an emergency withdraw function. For that, see panic().
     */
    function _retireStrat() internal override {
        uint256 suppliedBalance = balanceOfPools();
        if (suppliedBalance > maxWantRemainingToRemovePool) {
            _reclaimWant();
            suppliedBalance = balanceOfPools();
            require(suppliedBalance <= maxWantRemainingToRemovePool, "Want still supplied to pools");
        }
        uint256 wantBalance = balanceOfWant();
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * Withdraws all funds
     */
    function _reclaimWant() internal override {
        _withdrawUnderlying(type(uint256).max);
    }

    /**
     * Withdraws all funds
     */
    function reclaimWant() public {
        _onlyKeeper();
        _reclaimWant();
    }

    /**
     * @dev Adds multiple pools at once
     */
    function addUsedPools(RouterPool[] calldata _poolsToAdd) external {
        _onlyKeeper();
        uint256 nrOfPools = _poolsToAdd.length;
        for (uint256 index = 0; index < nrOfPools; index++) {
            RouterPool memory pool = _poolsToAdd[index];
            addUsedPool(pool.index, pool.routerType);
        }
    }

    /**
     * @dev Adds a new pool using the Tarot factory index (to ensure only Tarot pools can be added)
     */
    function addUsedPool(uint256 _poolIndex, RouterType _routerType) public {
        _onlyKeeper();

        address router;

        if (_routerType == RouterType.CLASSIC) {
            router = TAROT_ROUTER;
        } else if (_routerType == RouterType.REQUIEM) {
            router = TAROT_REQUIEM_ROUTER;
        }

        address factory = IRouter(router).factory();
        address lpAddress = IFactory(factory).allLendingPools(_poolIndex);
        address lp0 = IUniswapV2Pair(lpAddress).token0();
        address lp1 = IUniswapV2Pair(lpAddress).token1();
        bool containsWant = lp0 == want || lp1 == want;
        require(containsWant, "Pool does not contain want");
        require(usedPools.length() < maxPools, "Reached max nr of pools");
        (, , , address borrowable0, address borrowable1) = IFactory(factory).getLendingPool(lpAddress);
        address poolAddress = lp0 == want ? borrowable0 : borrowable1;
        require(usedPools.add(poolAddress), "Pool already added");
    }

    /**
     * @dev Attempts to remove all want supplied to a pool, returns the amount left
     */
    function withdrawFromPool(address _pool) external returns (uint256) {
        _onlyKeeper();
        require(usedPools.contains(_pool), "Pool not used");
        uint256 currentExchangeRate = IBorrowable(_pool).exchangeRate();
        uint256 wantSupplied = wantSuppliedToPool(_pool);
        if (wantSupplied != 0) {
            uint256 wantAvailable = IERC20Upgradeable(want).balanceOf(_pool);

            uint256 ableToPullInUnderlying = MathUpgradeable.min(wantSupplied, wantAvailable);
            uint256 ableToPullInbToken = (ableToPullInUnderlying * 1 ether) / currentExchangeRate;
            if (ableToPullInbToken != 0) {
                IBorrowable(_pool).transfer(_pool, ableToPullInbToken);
                IBorrowable(_pool).redeem(address(this));
            }
            wantSupplied = wantSuppliedToPool(_pool);
        }
        return wantSupplied;
    }

    /**
     * @dev Removes a list of pools.
     */
    function removeUsedPools(address[] calldata _poolsToRemove) external {
        _onlyKeeper();
        uint256 nrOfPools = _poolsToRemove.length;
        for (uint256 index = 0; index < nrOfPools; index++) {
            removeUsedPool(_poolsToRemove[index]);
        }
    }

    /**
     * @dev Removes a pool that will no longer be used.
     */
    function removeUsedPool(address _pool) public {
        _onlyKeeper();
        require(usedPools.length() > 1, "Must have at least 1 pool");
        require(wantSuppliedToPool(_pool) < maxWantRemainingToRemovePool, "Want is still supplied");
        require(usedPools.remove(_pool), "Pool not used");
        if (_pool == depositPool) {
            depositPool = usedPools.at(0);
        }
    }

    /**
     * @dev Only allow access to keeper and above
     */
    function _onlyKeeper() internal view {
        require(
            hasRole(KEEPER, msg.sender) || hasRole(STRATEGIST, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
    }

    /**
     * @dev Sets the maximum slippage authorized when withdrawing
     */
    function setWithdrawSlippageTolerance(uint256 _withdrawSlippageTolerance) external {
        _onlyStrategistOrOwner();
        require(_withdrawSlippageTolerance <= MAX_SLIPPAGE_TOLERANCE, "Slippage tolerance is too high");
        withdrawSlippageTolerance = _withdrawSlippageTolerance;
    }

    /**
     * @dev Sets the minimum amount of profit (in want) to charge fees
     */
    function setMinProfitToChargeFees(uint256 _minProfitToChargeFees) external {
        _onlyStrategistOrOwner();
        minProfitToChargeFees = _minProfitToChargeFees;
    }

    /**
     * @dev Sets the minimum amount of want to deposit or withdraw out of a pool
     */
    function setMinWantToDepositOrWithdraw(uint256 _minWantToDepositOrWithdraw) external {
        _onlyStrategistOrOwner();
        minWantToDepositOrWithdraw = _minWantToDepositOrWithdraw;
    }

    /**
     * @dev Sets the maximum amount of want remaining in a pool to still be able to remove it
     */
    function setMaxWantRemainingToRemovePool(uint256 _maxWantRemainingToRemovePool) external {
        _onlyStrategistOrOwner();
        require(_maxWantRemainingToRemovePool <= 10e6, "Above max cap");
        maxWantRemainingToRemovePool = _maxWantRemainingToRemovePool;
    }
    
    /**
     * @dev Sets the maximum amount of pools that can be used at any time
     */
    function setMaxPools(uint256 _maxPools) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxPools != 0 && _maxPools <= 100, "Invalid nr of pools");
        maxPools = _maxPools;
    }

    /**
     * @dev Sets if harvests should be done when depositing
     */
    function setShouldHarvestOnDeposit(bool _shouldHarvestOnDeposit) external {
        _onlyStrategistOrOwner();
        shouldHarvestOnDeposit = _shouldHarvestOnDeposit;
    }

    /**
     * @dev Sets if harvests should be done when withdrawing
     */
    function setShouldHarvestOnWithdraw(bool _shouldHarvestOnWithdraw) external {
        _onlyStrategistOrOwner();
        shouldHarvestOnWithdraw = _shouldHarvestOnWithdraw;
    }
}
