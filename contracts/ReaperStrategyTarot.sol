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
     * {WFTM} - Required for liquidity routing when doing swaps.
     * {want} - Address of the token being lent
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

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
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address[] memory _multisigRoles,
        uint256 _initialPoolIndex,
        RouterType _routerType,
        address _want
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _want, _feeRemitters, _strategists, _multisigRoles);
       sharePriceSnapshot = IVault(_vault).getPricePerFullShare();
        maxPools = 40;
        withdrawSlippageTolerance = 10;
        minProfitToChargeFees = 1e16;
        minWantToDepositOrWithdraw = 10;
        maxWantRemainingToRemovePool = 100;
        // addUsedPool(_initialPoolIndex, _routerType);
        depositPool = usedPools.at(0); // Guarantees depositPool is always a Tarot pool
        shouldHarvestOnDeposit = true;
        shouldHarvestOnWithdraw = true;
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
        // uint256 wantBal = balanceOfWant();
        // if (wantBal < _amountNeeded) {
        //     _withdraw(_amountNeeded - wantBal);
        //     liquidatedAmount = balanceOfWant();
        // } else {
        //     liquidatedAmount = _amountNeeded;
        // }

        // if (_amountNeeded > liquidatedAmount) {
        //     loss = _amountNeeded - liquidatedAmount;
        // }
    }

    function _liquidateAllPositions() internal override returns (uint256 amountFreed) {
        // _delever(type(uint256).max);
        // _withdrawUnderlying(balanceOfPool());
        // return balanceOfWant();
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
        // _processGeistVestsAndSwapToFtm();
        // callerFee = _chargeFees();
        // _convertWftmToWant();
        
        // uint256 allocated = IVault(vault).strategies(address(this)).allocated;
        // uint256 totalAssets = balanceOf();
        // uint256 toFree = _debt;

        // if (totalAssets > allocated) {
        //     uint256 profit = totalAssets - allocated;
        //     toFree += profit;
        //     roi = int256(profit);
        // } else if (totalAssets < allocated) {
        //     roi = -int256(allocated - totalAssets);
        // }

        // (uint256 amountFreed, uint256 loss) = _liquidatePosition(toFree);
        // repayment = MathUpgradeable.min(_debt, amountFreed);
        // roi -= int256(loss);
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
    function _withdraw(uint256 _amount) internal {
        // if (_amount == 0) {
        //     return;
        // }

        // (uint256 supply, uint256 borrow) = getSupplyAndBorrow();
        // supply -= _amount;
        // uint256 postWithdrawLtv = supply != 0 ? (borrow * PERCENT_DIVISOR) / supply : 0;

        // if (postWithdrawLtv > maxLtv) {
        //     _delever(_amount);
        //     _withdrawUnderlying(_amount);
        // } else if (postWithdrawLtv < targetLtv) {
        //     _withdrawUnderlying(_amount);
        //     _leverUpMax();
        // } else {
        //     _withdrawUnderlying(_amount);
        // }
    }

    /**
     * @dev Attempts to Withdraw {_withdrawAmount} from pool. Withdraws max amount that can be
     *      safely withdrawn if {_withdrawAmount} is too high.
     */
    function _withdrawUnderlying(uint256 _withdrawAmount) internal {
        // (uint256 supply, uint256 borrow) = getSupplyAndBorrow();
        // uint256 necessarySupply = maxLtv != 0 ? borrow.mulDivUp(PERCENT_DIVISOR, maxLtv) : 0; // use maxLtv instead of targetLtv here
        // require(supply > necessarySupply, "can't withdraw anything!");

        // uint256 withdrawable = supply - necessarySupply;
        // _withdrawAmount = MathUpgradeable.min(_withdrawAmount, withdrawable);
        // LENDING_POOL().withdraw(address(want), _withdrawAmount, address(this));
    }

    /**
     * @dev Core harvest function.
     * Swaps amount using path
     */
    function _swap(uint256 amount, address[] storage path) internal {
        // if (amount != 0) {
        //     IERC20Upgradeable(path[0]).safeIncreaseAllowance(
        //         UNI_ROUTER,
        //         amount
        //     );
        //     IUniswapV2Router02(UNI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
        //         amount,
        //         0,
        //         path,
        //         address(this),
        //         block.timestamp + 600
        //     );
        // }
    }

    /**
     * @dev Core harvest function.
     * Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal returns (uint256 callerFee) {
        // uint256 wftmFee = IERC20Upgradeable(WFTM).balanceOf(address(this)) * totalFee / PERCENT_DIVISOR;

        // IERC20Upgradeable dai = IERC20Upgradeable(DAI);
        // uint256 daiBalanceBefore = dai.balanceOf(address(this));
        // _swap(wftmFee, wftmToDaiPath);
        // uint256 daiBalanceAfter = dai.balanceOf(address(this));
        
        // uint256 daiFee = daiBalanceAfter - daiBalanceBefore;
        // if (daiFee != 0) {
        //     callerFee = (daiFee * callFee) / PERCENT_DIVISOR;
        //     uint256 treasuryFeeToVault = (daiFee * treasuryFee) / PERCENT_DIVISOR;
        //     uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
        //     treasuryFeeToVault -= feeToStrategist;

        //     dai.safeTransfer(msg.sender, callerFee);
        //     dai.safeTransfer(treasury, treasuryFeeToVault);
        //     dai.safeTransfer(strategistRemitter, feeToStrategist);
        // }
    }

    /**
     * @dev Function to calculate the total {want} held by the strat.
     * It takes into account both the funds in hand, plus the funds in the lendingPool.
     */
    function balanceOf() public view override returns (uint256) {
        // return balanceOfPool() + balanceOfWant();
    }

    function balanceOfWant() public view returns (uint256) {
        // return IERC20Upgradeable(want).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        // (uint256 supply, uint256 borrow) = getSupplyAndBorrow();
        // uint256 realSupply = supply - borrow;
        // return realSupply;
    }
}