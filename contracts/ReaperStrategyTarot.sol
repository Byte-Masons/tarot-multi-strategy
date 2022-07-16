// SPDX-License-Identifier: MIT

import "./abstract/ReaperBaseStrategyv4.sol";
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

pragma solidity 0.8.11;

/**
 * @dev This strategy will deposit and leverage a token on Geist to maximize yield
 */
contract ReaperStrategyTarot is ReaperBaseStrategyv4 {
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

    // 3rd-party contract addresses
    address public constant SPOOKY_ROUTER = address(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address public constant TAROT_ROUTER = address(0x283e62CFe14b352dB8e30A9575481DCbf589Ad98);
    address public constant TAROT_REQUIEM_ROUTER = address(0x3F7E61C5dd29F9380b270551e438B65c29183a7c);

    /**
     * @dev Tokens Used:
     * {USDC} - Token for charging fees
     */
    address public constant USDC = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);

    /**
     * @dev UniV2 routes:
     * {wantToUsdcPath} - Path for charging fees from profit
     */
    address[] public wantToUsdcPath;

    /**
     * @dev Tarot variables
     * {usedPools} - A set of pool addresses which are the authorized lending pools that can be used
     * {maxPools} - Sets the maximum amount of pools that can be added
     * {depositPool} - Address of the pool that regular deposits will go to
     * {sharePriceSnapshot} - Saves the pricePerFullShare to be compared between harvests to calculate profit
     * {minProfitToChargeFees} - The minimum amount of profit for harvest to charge fees
     * {minWantToDepositOrWithdraw} - A minimum amount to deposit or withdraw from a pool (to save gas on very small amounts)
     * {maxWantRemainingToRemovePool} - Sets the allowed amount for a pool to have and still be removable (which will loose those funds)
     * {MAX_SLIPPAGE_TOLERANCE} - Sets a cap on the withdraw slippage tolerance 
     */
    EnumerableSetUpgradeable.AddressSet private usedPools;
    uint256 public maxPools;
    address public depositPool;
    uint256 public sharePriceSnapshot;
    uint256 public minProfitToChargeFees;
    uint256 public minWantToDepositOrWithdraw;
    uint256 public maxWantRemainingToRemovePool;
    bool public shouldHarvestOnDeposit;
    bool public shouldHarvestOnWithdraw;
    uint256 public constant MAX_SLIPPAGE_TOLERANCE = 100;
    uint256 public minWantToSell;

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address[] memory _multisigRoles,
        address[] memory _wantToUsdcPath,
        uint256 _initialPoolIndex,
        RouterType _routerType
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _wantToUsdcPath[0], _feeRemitters, _strategists, _multisigRoles);
        sharePriceSnapshot = IVault(_vault).getPricePerFullShare();
        maxPools = 40;
        minProfitToChargeFees = 1e9;
        minWantToDepositOrWithdraw = 10;
        maxWantRemainingToRemovePool = 100;
        minWantToSell = 1e2;
        addUsedPool(_initialPoolIndex, _routerType);
        depositPool = usedPools.at(0); // Guarantees depositPool is always a Tarot pool
        shouldHarvestOnDeposit = true;
        shouldHarvestOnWithdraw = true;
        wantToUsdcPath = _wantToUsdcPath;
    }

    function _adjustPosition(uint256 _debt) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debt) {
            uint256 toReinvest = wantBalance - _debt;
            _deposit(toReinvest);
        }
    }

    function _liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 liquidatedAmount, uint256 loss)
    {
        uint256 wantBal = balanceOfWant();
        if (wantBal < _amountNeeded) {
            _withdraw(_amountNeeded - wantBal);
            liquidatedAmount = balanceOfWant();
        } else {
            liquidatedAmount = _amountNeeded;
        }

        if (_amountNeeded > liquidatedAmount) {
            loss = _amountNeeded - liquidatedAmount;
        }
    }

    function _liquidateAllPositions() internal override returns (uint256 amountFreed) {
        _reclaimWant();
        return balanceOfWant();
    }

    /**
     * @dev Function that puts the funds to work.
     *      It gets called whenever someone deposits in the strategy's vault contract.
     */
    function _deposit(uint256 _amount) internal {
        if (_amount != 0) {
            IERC20Upgradeable(want).safeTransfer(depositPool, _amount);
            IBorrowable(depositPool).mint(address(this));
        }
    }

    /**
     * @dev Withdraws a given amount by looping through all lending pools until enough want has been withdrawn
     */
    function _withdraw(uint256 _amountToWithdraw) internal returns (uint256) {
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
        _atLeastRole(KEEPER);
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
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * @notice Assumes the deposit will take care of the TVL rebalancing.
     * 1. Claims {SCREAM} from the comptroller.
     * 2. Swaps {SCREAM} to {WFTM}.
     * 3. Claims fees for the harvest caller and treasury.
     * 4. Swaps the {WFTM} token for {want}
     * 5. Deposits.
     */
    function _harvestCore(uint256 _debt)
        internal
        override
        returns (
            uint256 callerFee,
            int256 roi,
            uint256 repayment
        )
    {
        callerFee = _chargeFees();
        
        uint256 allocated = IVault(vault).strategies(address(this)).allocated;
        uint256 totalAssets = balanceOf();
        uint256 toFree = _debt;

        if (totalAssets > allocated) {
            uint256 profit = totalAssets - allocated;
            toFree += profit;
            roi = int256(profit);
        } else if (totalAssets < allocated) {
            roi = -int256(allocated - totalAssets);
        }

        (uint256 amountFreed, uint256 loss) = _liquidatePosition(toFree);
        repayment = MathUpgradeable.min(_debt, amountFreed);
        roi -= int256(loss);
    }

    /**
     * @dev Core harvest function.
     *      Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal returns (uint256 callerFee) {
        updateExchangeRates();
        uint256 profit = profitSinceHarvest();
        if (profit >= minProfitToChargeFees) {
            uint256 fee = (profit * totalFee) / PERCENT_DIVISOR;

            if (fee != 0) {
                uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
                if (wantBal < fee) {
                    uint256 withdrawn = _withdraw(fee - wantBal);
                    if (withdrawn + wantBal < fee) {
                        fee = withdrawn + wantBal;
                    }
                }
                _swapToUsdc(fee);
                IERC20Upgradeable usdc = IERC20Upgradeable(USDC);
                uint256 usdcBalance = usdc.balanceOf(address(this));
                callerFee = (usdcBalance * callFee) / PERCENT_DIVISOR;
                uint256 treasuryFeeToVault = (usdcBalance * treasuryFee) / PERCENT_DIVISOR;
                uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
                treasuryFeeToVault -= feeToStrategist;

                
                usdc.safeTransfer(msg.sender, callerFee);
                usdc.safeTransfer(treasury, treasuryFeeToVault);
                usdc.safeTransfer(strategistRemitter, feeToStrategist);
                sharePriceSnapshot = IVault(vault).getPricePerFullShare();
            }
        }
    }

    /**
     * @dev Helper function to swap want to USDC
     */
    function _swapToUsdc(
        uint256 _amount
    ) internal {
        if (_amount >= minWantToSell) {
            IERC20Upgradeable(want).safeIncreaseAllowance(SPOOKY_ROUTER, _amount);
            IUniswapV2Router02(SPOOKY_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _amount,
                0,
                wantToUsdcPath,
                address(this),
                block.timestamp
            );
        }
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
     * Withdraws all funds
     */
    function _reclaimWant() internal {
        _withdraw(type(uint256).max);
    }

    /**
     * Withdraws all funds
     */
    function reclaimWant() public {
        _atLeastRole(KEEPER);
        _reclaimWant();
    }

    /**
     * @dev Adds multiple pools at once
     */
    function addUsedPools(RouterPool[] calldata _poolsToAdd) external {
        _atLeastRole(KEEPER);
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
        _atLeastRole(KEEPER);

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
        _atLeastRole(KEEPER);
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
        _atLeastRole(KEEPER);
        uint256 nrOfPools = _poolsToRemove.length;
        for (uint256 index = 0; index < nrOfPools; index++) {
            removeUsedPool(_poolsToRemove[index]);
        }
    }

    /**
     * @dev Removes a pool that will no longer be used.
     */
    function removeUsedPool(address _pool) public {
        _atLeastRole(KEEPER);
        require(usedPools.length() > 1, "Must have at least 1 pool");
        require(wantSuppliedToPool(_pool) < maxWantRemainingToRemovePool, "Want is still supplied");
        require(usedPools.remove(_pool), "Pool not used");
        if (_pool == depositPool) {
            depositPool = usedPools.at(0);
        }
    }

    /**
     * @dev Sets the minimum amount of profit (in want) to charge fees
     */
    function setMinProfitToChargeFees(uint256 _minProfitToChargeFees) external {
        _atLeastRole(STRATEGIST);
        minProfitToChargeFees = _minProfitToChargeFees;
    }

    /**
     * @dev Sets the minimum amount of want to deposit or withdraw out of a pool
     */
    function setMinWantToDepositOrWithdraw(uint256 _minWantToDepositOrWithdraw) external {
        _atLeastRole(STRATEGIST);
        minWantToDepositOrWithdraw = _minWantToDepositOrWithdraw;
    }

    /**
     * @dev Sets the maximum amount of want remaining in a pool to still be able to remove it
     */
    function setMaxWantRemainingToRemovePool(uint256 _maxWantRemainingToRemovePool) external {
        _atLeastRole(STRATEGIST);
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
        _atLeastRole(STRATEGIST);
        shouldHarvestOnDeposit = _shouldHarvestOnDeposit;
    }

    /**
     * @dev Sets if harvests should be done when withdrawing
     */
    function setShouldHarvestOnWithdraw(bool _shouldHarvestOnWithdraw) external {
        _atLeastRole(STRATEGIST);
        shouldHarvestOnWithdraw = _shouldHarvestOnWithdraw;
    }

    /**
     * @dev Sets the minimum want that will be sold (too little causes revert from Uniswap)
     */
    function setMinWantToSell(uint256 _minWantToSell) external {
        _atLeastRole(STRATEGIST);
        minWantToSell = _minWantToSell;
    }
}