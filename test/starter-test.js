const hre = require('hardhat');
const chai = require('chai');
const {solidity} = require('ethereum-waffle');
chai.use(solidity);
const {expect} = chai;

const moveTimeForward = async (seconds) => {
  await network.provider.send('evm_increaseTime', [seconds]);
  await network.provider.send('evm_mine');
};

// use with small values in case harvest is block-dependent instead of time-dependent
const moveBlocksForward = async (blocks) => {
  for (let i = 0; i < blocks; i++) {
    await network.provider.send('evm_increaseTime', [1]);
    await network.provider.send('evm_mine');
  }
};

const toWantUnit = (num) => {
  return ethers.utils.parseEther(num);
};

const rebalance = async (strategy) => {
  const poolAllocations = [
    // {
    //   poolAddress: '0x6CFcA68b32Bdb5B02039Ccd03784cdc96De7FB87', // ZipSwap ETH-OP
    //   allocation: toWantUnit('50'),
    // },
    {
      poolAddress: '0x0af2Fdfde652310677ddf3b0bb6cD903476C4342', // Velodrome OP-USDC
      allocation: toWantUnit('50'),
    },
  ];
  await strategy.rebalance(poolAllocations);
};

describe('Vaults', function () {
  let Vault;
  let vault;

  let Strategy;
  let strategy;

  let Want;
  let want;
  let usdc;

  const treasuryAddr = '0x1E71AEE6081f62053123140aacC7a06021D77348';
  const paymentSplitterAddress = '0x1E71AEE6081f62053123140aacC7a06021D77348';

  const superAdminAddress = '0x04C710a1E8a738CDf7cAD3a52Ba77A784C35d8CE';
  const adminAddress = '0x539eF36C804e4D735d8cAb69e8e441c12d4B88E0';
  const guardianAddress = '0xf20E25f2AB644C8ecBFc992a6829478a85A98F2c';
  const maintainerAddress = '0x81876677843D00a7D792E1617459aC2E93202576';

  const usdcAddress = '0x7F5c764cBc14f9669B88837ca1490cCa17c31607';
  const wantAddress = '0x4200000000000000000000000000000000000042';
  const wantToUsdcPath = [wantAddress, usdcAddress];
  const wantToUsdcFee = [3000];

  const wantHolderAddr = '0xebe80f029b1c02862b9e8a70a7e5317c06f62cae';
  const strategistAddr = '0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4';

  const poolIndex = 3;
  const routerType = 1;
  // index 2, type 1 is Velo ETH-USDC
  // index 5, type 0 is ZipSwap ETH-OP

  let owner;
  let wantHolder;
  let strategist;
  let guardian;
  let maintainer;
  let admin;
  let superAdmin;
  let unassignedRole;
  let targetLTV;
  let allowedLTVDrift;

  beforeEach(async function () {
    //reset network
    await network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl: 'https://mainnet.optimism.io',
            // blockNumber: 90053,
          },
        },
      ],
    });

    //get signers
    [owner, unassignedRole] = await ethers.getSigners();
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [wantHolderAddr],
    });
    wantHolder = await ethers.provider.getSigner(wantHolderAddr);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [strategistAddr],
    });
    strategist = await ethers.provider.getSigner(strategistAddr);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [adminAddress],
    });
    admin = await ethers.provider.getSigner(adminAddress);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [superAdminAddress],
    });
    superAdmin = await ethers.provider.getSigner(superAdminAddress);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [guardianAddress],
    });
    guardian = await ethers.provider.getSigner(guardianAddress);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [maintainerAddress],
    });
    maintainer = await ethers.provider.getSigner(maintainerAddress);

    //get artifacts
    Vault = await ethers.getContractFactory('ReaperVaultV2');
    Strategy = await ethers.getContractFactory('ReaperStrategyTarot');
    Want = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');

    //deploy contracts
    vault = await Vault.deploy(
      wantAddress,
      'WFTM Crypt',
      'rf-WFTM',
      ethers.constants.MaxUint256,
      [strategistAddr],
      [superAdminAddress, maintainerAddress, guardianAddress],
    );

    strategy = await hre.upgrades.deployProxy(
      Strategy,
      [
        vault.address,
        [treasuryAddr, paymentSplitterAddress],
        [strategistAddr],
        [superAdminAddress, adminAddress, guardianAddress],
        wantToUsdcPath,
        wantToUsdcFee,
        poolIndex,
        routerType,
      ],
      {kind: 'uups'},
    );
    await strategy.deployed();
    await vault.addStrategy(strategy.address, 9000);
    want = await Want.attach(wantAddress);
    usdc = await Want.attach(usdcAddress);

    //approving LP token and vault share spend
    await want.connect(wantHolder).approve(vault.address, ethers.constants.MaxUint256);
  });

  xdescribe('Deploying the vault and strategy', function () {
    it('should initiate vault with a 0 balance', async function () {
      const assets = ethers.utils.parseEther('1');
      const totalBalance = await vault.totalAssets();
      const pricePerFullShare = await vault.convertToAssets(assets);
      expect(totalBalance).to.equal(0);
      expect(pricePerFullShare).to.equal(assets);
    });
  });

  xdescribe('Strategy Access control tests', function () {
    it('unassignedRole has no privileges', async function () {
      await expect(strategy.connect(unassignedRole).setEmergencyExit()).to.be.reverted;
    });

    it('strategist has right privileges', async function () {
      await expect(strategy.connect(strategist).setEmergencyExit()).to.be.reverted;
    });

    it('guardian has right privileges', async function () {
      const tx = await strategist.sendTransaction({
        to: guardianAddress,
        value: ethers.utils.parseEther('1.0'),
      });
      await tx.wait();

      await expect(strategy.connect(guardian).setEmergencyExit()).to.not.be.reverted;
    });

    it('admin has right privileges', async function () {
      const tx = await strategist.sendTransaction({
        to: adminAddress,
        value: ethers.utils.parseEther('1.0'),
      });
      await tx.wait();

      await expect(strategy.connect(admin).setEmergencyExit()).to.not.be.reverted;
    });

    it('super-admin/owner has right privileges', async function () {
      const tx = await strategist.sendTransaction({
        to: superAdminAddress,
        value: ethers.utils.parseEther('1.0'),
      });
      await tx.wait();

      await expect(strategy.connect(superAdmin).setEmergencyExit()).to.not.be.reverted;
    });
  });

  xdescribe('Vault Access control tests', function () {
    it('unassignedRole has no privileges', async function () {
      await expect(vault.connect(unassignedRole).addStrategy(strategy.address, 1000)).to.be.reverted;

      await expect(vault.connect(unassignedRole).updateStrategyAllocBPS(strategy.address, 1000)).to.be.reverted;

      await expect(vault.connect(unassignedRole).revokeStrategy(strategy.address)).to.be.reverted;

      await expect(vault.connect(unassignedRole).setEmergencyShutdown(true)).to.be.reverted;
    });

    it('guardian has right privileges', async function () {
      const tx = await owner.sendTransaction({
        to: guardianAddress,
        value: ethers.utils.parseEther('10'),
      });
      await tx.wait();

      await expect(vault.connect(guardian).addStrategy(strategy.address, 1000)).to.be.reverted;

      await expect(vault.connect(guardian).updateStrategyAllocBPS(strategy.address, 1000)).to.not.be.reverted;

      await expect(vault.connect(guardian).revokeStrategy(strategy.address)).to.not.be.reverted;

      await expect(vault.connect(guardian).setEmergencyShutdown(true)).to.not.be.reverted;

      await expect(vault.connect(guardian).setEmergencyShutdown(false)).to.be.reverted;

      await expect(vault.connect(guardian).removeTvlCap()).to.be.reverted;
    });

    it('strategist has right privileges', async function () {
      await expect(vault.connect(strategist).addStrategy(strategy.address, 1000)).to.be.reverted;

      await expect(vault.connect(strategist).updateStrategyAllocBPS(strategy.address, 1000)).to.not.be.reverted;

      await expect(vault.connect(strategist).revokeStrategy(strategy.address)).to.be.reverted;

      await expect(vault.connect(strategist).setEmergencyShutdown(true)).to.be.reverted;
    });

    it('superAdmin has right privileges', async function () {
      await expect(vault.connect(superAdmin).addStrategy(strategy.address, 1000)).to.not.be.reverted;

      await expect(vault.connect(superAdmin).updateStrategyAllocBPS(strategy.address, 1000)).to.not.be.reverted;

      await expect(vault.connect(superAdmin).revokeStrategy(strategy.address)).to.not.be.reverted;

      await expect(vault.connect(superAdmin).setEmergencyShutdown(true)).to.not.be.reverted;
    });
  });

  xdescribe('Vault Tests', function () {
    it('should allow deposits and account for them correctly', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const vaultBalance = await vault.totalAssets();
      const depositAmount = toWantUnit('10');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      const newVaultBalance = await vault.totalAssets();
      const newUserBalance = await want.balanceOf(wantHolderAddr);
      const allowedInaccuracy = depositAmount.div(200);
      expect(depositAmount).to.be.closeTo(newVaultBalance, allowedInaccuracy);
    });

    it('should mint user their pool share', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('10');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      const ownerDepositAmount = toWantUnit('0.1');
      await want.connect(wantHolder).transfer(owner.address, ownerDepositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      await vault.connect(owner).deposit(ownerDepositAmount, owner.address);

      const allowedImprecision = toWantUnit('0.0001');

      const userVaultBalance = await vault.balanceOf(wantHolderAddr);
      expect(userVaultBalance).to.be.closeTo(depositAmount, allowedImprecision);
      const ownerVaultBalance = await vault.balanceOf(owner.address);
      expect(ownerVaultBalance).to.be.closeTo(ownerDepositAmount, allowedImprecision);

      await vault.connect(owner).redeemAll();
      const ownerWantBalance = await want.balanceOf(owner.address);
      expect(ownerWantBalance).to.be.closeTo(ownerDepositAmount, allowedImprecision);
      const afterOwnerVaultBalance = await vault.balanceOf(owner.address);
      expect(afterOwnerVaultBalance).to.equal(0);
    });

    it('should allow withdrawals', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('100');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      await vault.connect(wantHolder).redeemAll();
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);

      const expectedBalance = userBalance;
      const smallDifference = depositAmount.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw).lt(smallDifference);
      console.log(`expectedBalance: ${expectedBalance}`);
      console.log(`userBalanceAfterWithdraw: ${userBalanceAfterWithdraw}`);
      console.log(`expectedBalance.sub(userBalanceAfterWithdraw): ${expectedBalance.sub(userBalanceAfterWithdraw)}`);
      console.log(`smallDifference: ${smallDifference}`);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    it('should allow small withdrawal', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('0.001');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      const ownerDepositAmount = toWantUnit('0.1');
      await want.connect(wantHolder).transfer(owner.address, ownerDepositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      await vault.connect(owner).deposit(ownerDepositAmount, owner.address);

      await vault.connect(wantHolder).redeemAll();
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);

      const expectedBalance = userBalance.sub(ownerDepositAmount);
      const smallDifference = depositAmount.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw).lt(smallDifference);
      console.log(`expectedBalance: ${expectedBalance}`);
      console.log(`userBalanceAfterWithdraw: ${userBalanceAfterWithdraw}`);
      console.log(`expectedBalance.sub(userBalanceAfterWithdraw): ${expectedBalance.sub(userBalanceAfterWithdraw)}`);
      console.log(`smallDifference: ${smallDifference}`);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    it('should handle small deposit + redeem', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('0.001');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      await vault.connect(wantHolder).redeem(depositAmount, wantHolderAddr, wantHolderAddr);
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);

      const expectedBalance = userBalance;
      const smallDifference = depositAmount.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    it('should be able to convert assets in to amount of shares', async function () {
      const depositAmount = toWantUnit('2');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);

      let totalAssets = await vault.totalAssets();
      console.log(`totalAssets: ${totalAssets}`);
      // Modify the price per share to not be 1 to 1
      await want.connect(wantHolder).transfer(vault.address, toWantUnit('13'));
      totalAssets = await vault.totalAssets();
      console.log(`totalAssets: ${totalAssets}`);

      await want.connect(wantHolder).transfer(owner.address, depositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      const shares = await vault.connect(owner).convertToShares(depositAmount);
      await vault.connect(owner).deposit(depositAmount, owner.address);
      console.log(`shares: ${shares}`);

      const vaultBalance = await vault.balanceOf(owner.address);
      console.log(`vaultBalance: ${vaultBalance}`);
      expect(shares).to.equal(vaultBalance);
    });

    it('should be able to convert shares in to amount of assets', async function () {
      const shareAmount = toWantUnit('3');
      let assets = await vault.convertToAssets(shareAmount);
      expect(assets).to.equal(shareAmount);
      console.log(`assets: ${assets}`);

      const depositAmount = toWantUnit('13');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);

      await want.connect(wantHolder).transfer(vault.address, depositAmount);

      assets = await vault.convertToAssets(shareAmount);
      console.log(`assets: ${assets}`);
      expect(assets).to.equal(shareAmount.mul(2));
    });

    it('maxDeposit returns the maximum amount that can be deposited', async function () {
      let tvlCap = toWantUnit('50');
      await vault.updateTvlCap(tvlCap);
      let maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(tvlCap);

      const depositAmount = toWantUnit('25');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(tvlCap.sub(depositAmount));

      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(0);

      tvlCap = toWantUnit('10');
      await vault.updateTvlCap(tvlCap);
      maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(0);
    });

    it('can previewDeposit', async function () {
      let depositAmount = toWantUnit('13');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);

      depositAmount = toWantUnit('4');
      let depositPreview = await vault.connect(wantHolder).previewDeposit(depositAmount);
      let vaultBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      let vaultBalanceAfter = await vault.balanceOf(wantHolderAddr);
      let balanceIncrease = vaultBalanceAfter.sub(vaultBalance);
      expect(depositPreview).to.equal(balanceIncrease);

      await want.connect(wantHolder).transfer(vault.address, toWantUnit('11'));

      depositAmount = toWantUnit('13');
      depositPreview = await vault.connect(wantHolder).previewDeposit(depositAmount);
      vaultBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      vaultBalanceAfter = await vault.balanceOf(wantHolderAddr);
      balanceIncrease = vaultBalanceAfter.sub(vaultBalance);
      expect(depositPreview).to.equal(balanceIncrease);
    });

    it('maxMint returns the max amount of shares that can be minted', async function () {
      let maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(ethers.constants.MaxUint256);

      let tvlCap = toWantUnit('50');
      await vault.updateTvlCap(tvlCap);
      maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(tvlCap);

      let depositAmount = toWantUnit('35');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(tvlCap.sub(depositAmount));

      // Change the price per share
      const transferAmount = toWantUnit('11');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);
      depositAmount = toWantUnit('15');
      await vault.updateTvlCap(tvlCap.add(transferAmount).add(depositAmount));
      const depositPreview = await vault.connect(wantHolder).previewDeposit(depositAmount);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(depositPreview);
    });

    it('previewMint returns the amount of asset taken on a mint', async function () {
      let mintAmount = toWantUnit('55');
      let mintPreview = await vault.connect(wantHolder).previewMint(mintAmount);
      expect(mintPreview).to.equal(mintAmount);

      let userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      let userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      expect(userBalanceAfterMint).to.equal(userBalance.sub(mintPreview));

      // Change the price per share
      const transferAmount = toWantUnit('11');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);

      mintAmount = toWantUnit('13');
      mintPreview = await vault.connect(wantHolder).previewMint(mintAmount);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      expect(userBalanceAfterMint).to.equal(userBalance.sub(mintPreview));
    });

    it('mint creates the correct amount of shares', async function () {
      let mintAmount = toWantUnit('55');
      let userBalance = await want.balanceOf(wantHolderAddr);
      // let shareBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      let shareBalanceAfterMint = await vault.balanceOf(wantHolderAddr);
      let userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      expect(userBalanceAfterMint).to.equal(userBalance.sub(mintAmount));
      expect(shareBalanceAfterMint).to.equal(mintAmount);

      // Change the price per share
      const transferAmount = toWantUnit('11');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);

      // Ensure it mints expected amount of shares with different price per share
      mintAmount = toWantUnit('11');
      let shareBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      shareBalanceAfterMint = await vault.balanceOf(wantHolderAddr);
      expect(shareBalanceAfterMint).to.equal(shareBalance.add(mintAmount));

      // Ensure deposit and mint are equivalent
      const depositAmount = toWantUnit('5');
      shareBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      const shareBalanceAfterDeposit = await vault.balanceOf(wantHolderAddr);
      const depositShareIncrease = shareBalanceAfterDeposit.sub(shareBalance);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(depositShareIncrease, wantHolderAddr);
      userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      const mintedAssets = userBalance.sub(userBalanceAfterMint);
      const allowedInaccuracy = 1000;
      expect(depositAmount).to.be.closeTo(mintedAssets, allowedInaccuracy);
    });

    it('previewWithdraw returns the correct amount of shares', async function () {
      let withdrawAmount = toWantUnit('7');
      let burnedSharesPreview = await vault.previewWithdraw(withdrawAmount);
      expect(burnedSharesPreview).to.equal(0);
      const depositAmount = toWantUnit('8');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      burnedSharesPreview = await vault.previewWithdraw(withdrawAmount);
      expect(burnedSharesPreview).to.equal(withdrawAmount);
      withdrawAmount = toWantUnit('0');
      burnedSharesPreview = await vault.previewWithdraw(withdrawAmount);
      expect(burnedSharesPreview).to.equal(withdrawAmount);
      // // Change the price per share
      const transferAmount = toWantUnit('35');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);
      withdrawAmount = toWantUnit('33');
      burnedSharesPreview = await vault.previewWithdraw(withdrawAmount);
      const userVaultBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).withdraw(withdrawAmount, wantHolderAddr, wantHolderAddr);
      const userVaultBalanceAfter = await vault.balanceOf(wantHolderAddr);
      const burnedShares = userVaultBalance.sub(userVaultBalanceAfter);
      expect(burnedSharesPreview).to.equal(burnedShares);
    });

    it('previewRedeem returns the correct amount of assets', async function () {
      let redeemAmount = toWantUnit('7');
      let redeemedAssetsPreview = await vault.previewRedeem(redeemAmount);
      expect(redeemedAssetsPreview).to.equal(redeemAmount);
      const depositAmount = toWantUnit('56');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      redeemedAssetsPreview = await vault.previewRedeem(redeemAmount);
      expect(redeemedAssetsPreview).to.equal(redeemAmount);
      redeemAmount = toWantUnit('0');
      redeemedAssetsPreview = await vault.previewRedeem(redeemAmount);
      expect(redeemedAssetsPreview).to.equal(redeemAmount);
      // // // Change the price per share
      const transferAmount = toWantUnit('35782');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);
      redeemAmount = toWantUnit('33');
      redeemedAssetsPreview = await vault.previewRedeem(redeemAmount);
      const userVaultBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).redeem(redeemAmount, wantHolderAddr, wantHolderAddr);
      const userVaultBalanceAfter = await want.balanceOf(wantHolderAddr);
      const redeemedAssets = userVaultBalanceAfter.sub(userVaultBalance);
      expect(redeemedAssetsPreview).to.equal(redeemedAssets);
    });

    it('mint and redeem are inverse operations', async function () {
      let mintAmount = toWantUnit('34');
      let mintAssetsPreview = await vault.previewMint(mintAmount);
      let userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      let userBalanceAfter = await want.balanceOf(wantHolderAddr);
      let mintedAssets = userBalance.sub(userBalanceAfter);
      let redeemAssetsPreview = await vault.previewRedeem(mintAmount);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).redeem(mintAmount, wantHolderAddr, wantHolderAddr);
      userBalanceAfter = await want.balanceOf(wantHolderAddr);
      let redeemedAssets = userBalanceAfter.sub(userBalance);
      // Assets:Shares are 1:1 so should be equal
      expect(mintAssetsPreview).to.equal(mintAmount);
      expect(mintedAssets).to.equal(mintAmount);
      expect(redeemAssetsPreview).to.equal(mintAmount);
      expect(redeemedAssets).to.equal(mintAmount);
      expect(mintedAssets).to.equal(redeemedAssets);

      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      // Change the price per share
      const transferAmount = toWantUnit('35');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);

      mintAmount = toWantUnit('6');
      mintAssetsPreview = await vault.previewMint(mintAmount);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      userBalanceAfter = await want.balanceOf(wantHolderAddr);
      mintedAssets = userBalance.sub(userBalanceAfter);
      redeemAssetsPreview = await vault.previewRedeem(mintAmount);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).redeem(mintAmount, wantHolderAddr, wantHolderAddr);
      userBalanceAfter = await want.balanceOf(wantHolderAddr);
      redeemedAssets = userBalanceAfter.sub(userBalance);
      const allowedInaccuracy = 2;
      // Assets:Shares price are not 1:1, difference in rounding should be allowed
      expect(mintAssetsPreview).to.be.closeTo(mintedAssets, allowedInaccuracy);
      expect(redeemAssetsPreview).to.be.closeTo(redeemedAssets, allowedInaccuracy);
      expect(mintedAssets).to.be.closeTo(redeemedAssets, allowedInaccuracy);
    });

    it('should lock profits from harvests', async function () {
      const timeToSkip = 3600;
      const initialUserBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = initialUserBalance;

      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();
      let vaultBalance = await vault.totalAssets();
      let lockedProfit = await vault.lockedProfit();
      console.log(`vaultBalance ${vaultBalance}`);
      console.log(`lockedProfit ${lockedProfit}`);

      await moveTimeForward(timeToSkip);
      await strategy.harvest();

      vaultBalance = await vault.totalAssets();
      lockedProfit = await vault.lockedProfit();
      console.log(`vaultBalance ${vaultBalance}`);
      console.log(`lockedProfit ${lockedProfit}`);
      expect(lockedProfit).to.be.gt(0);

      let pricePerShare = await vault.previewRedeem(toWantUnit('1'));
      console.log(`pricePerShare ${pricePerShare}`);

      for (let index = 0; index < 5; index++) {
        await moveTimeForward(timeToSkip);
        let previousPricePerShare = pricePerShare;
        pricePerShare = await vault.previewRedeem(toWantUnit('1'));
        console.log(`pricePerShare ${pricePerShare}`);
        expect(pricePerShare).to.be.gt(previousPricePerShare);
      }

      // Setting degradation to 1e18 will release all the profit in 1 block
      // so all the profit should be released
      await vault.setLockedProfitDegradation(toWantUnit('1'));
      await vault.connect(wantHolder).redeemAll();
      vaultBalance = await vault.totalAssets();
      console.log(`vaultBalance: ${vaultBalance}`);
      // All the profit should have been unlocked to allow a redeem of all assets
      expect(vaultBalance).to.equal(0);
    });

    it('mint and deposit are equivalent', async function () {
      let mintAmount = toWantUnit('18');
      let mintBalanceBefore = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      let mintBalanceAfter = await vault.balanceOf(wantHolderAddr);
      let mintedShares = mintBalanceAfter.sub(mintBalanceBefore);
      console.log(`mintedShares: ${mintedShares}`);

      let depositAmount = toWantUnit('18');
      let depositBalanceBefore = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      let depositBalanceAfter = await vault.balanceOf(wantHolderAddr);
      let depositedShares = depositBalanceAfter.sub(depositBalanceBefore);
      console.log(`depositedShares: ${depositedShares}`);

      expect(mintedShares).to.equal(depositedShares);

      // Change the price per share
      const transferAmount = toWantUnit('35');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);

      mintBalanceBefore = await vault.balanceOf(wantHolderAddr);
      const userBalanceBefore = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      const userBalanceAfter = await want.balanceOf(wantHolderAddr);
      mintBalanceAfter = await vault.balanceOf(wantHolderAddr);
      mintedShares = mintBalanceAfter.sub(mintBalanceBefore);
      console.log(`mintedShares: ${mintedShares}`);

      depositAmount = userBalanceBefore.sub(userBalanceAfter);
      depositBalanceBefore = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      depositBalanceAfter = await vault.balanceOf(wantHolderAddr);
      depositedShares = depositBalanceAfter.sub(depositBalanceBefore);
      console.log(`depositedShares: ${depositedShares}`);

      expect(mintedShares).to.equal(depositedShares);
    });
  });

  xdescribe('Strategy', function () {
    it('should provide yield', async function () {
      const timeToSkip = 3600;
      const initialUserBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('50');

      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      const initialVaultBalance = await vault.totalAssets();
      await rebalance(strategy);

      const numHarvests = 5;
      for (let i = 0; i < numHarvests; i++) {
        await moveTimeForward(timeToSkip);
        await moveBlocksForward(100);
        await strategy.updateExchangeRates();
        await strategy.harvest();
      }

      const finalVaultBalance = await vault.totalAssets();
      console.log(`initialVaultBalance: ${initialVaultBalance}`);
      console.log(`finalVaultBalance: ${finalVaultBalance}`);
      expect(finalVaultBalance).to.be.gt(initialVaultBalance);
    });

    it('should be able to harvest', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('100'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      const readOnlyStrat = await strategy.connect(ethers.provider);
      const predictedCallerFee = await readOnlyStrat.callStatic.harvest();
      console.log(`predicted caller fee ${ethers.utils.formatEther(predictedCallerFee)}`);

      const daiBalBefore = await usdc.balanceOf(owner.address);
      await strategy.harvest();
      const daiBalAfter = await usdc.balanceOf(owner.address);
      const daiBalDifference = daiBalAfter.sub(daiBalBefore);
      console.log(`actual caller fee ${ethers.utils.formatEther(daiBalDifference)}`);
    });
  });

  xdescribe('Vault<>Strat accounting', function () {
    it('Strat gets more money when it flows in', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('500'), wantHolderAddr);
      await strategy.harvest();

      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(ethers.utils.parseEther('50'));
      let stratBalance = await strategy.balanceOf();
      let expectedStrategyBalance = ethers.utils.parseEther('450');
      let smallDifference = expectedStrategyBalance.div(1e12);
      console.log(`smallDifference ${smallDifference}`);
      console.log(`expectedStrategyBalance ${expectedStrategyBalance}`);
      console.log(`stratBalance ${stratBalance}`);
      let isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
      //await moveTimeForward(3600);
      await vault.connect(wantHolder).deposit(toWantUnit('500'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      vaultBalance = await want.balanceOf(vault.address);
      console.log(`vaultBalance ${vaultBalance}`);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('100'));
      stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('900');
      smallDifference = expectedStrategyBalance.div(1e12);
      console.log(`smallDifference ${smallDifference}`);
      console.log(`expectedStrategyBalance: ${expectedStrategyBalance}`);
      console.log(`stratBalance: ${stratBalance}`);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    it('Vault pulls funds from strat as needed', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(ethers.utils.parseEther('100'));
      let stratBalance = await strategy.balanceOf();
      let expectedStrategyBalance = ethers.utils.parseEther('900');
      let smallDifference = expectedStrategyBalance.div(1e12);
      let isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.updateStrategyAllocBPS(strategy.address, 7000);
      await strategy.harvest();
      await moveTimeForward(3600);
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('300'));
      stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('700');
      smallDifference = expectedStrategyBalance.div(1e12);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.connect(wantHolder).deposit(toWantUnit('100'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('330'));
      stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('770');
      smallDifference = expectedStrategyBalance.div(1e12);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });
  });

  describe('Emergency scenarios', function () {
    it('Vault should handle emergency shutdown', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(toWantUnit('100'));
      let stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = toWantUnit('900');
      smallDifference = expectedStrategyBalance.div(1e12);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.setEmergencyShutdown(true);
      await strategy.harvest();
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(toWantUnit('1000'));
      stratBalance = await strategy.balanceOf();
      smallDifference = vaultBalance.div(1e12);
      isSmallBalanceDifference = stratBalance.lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    it('Strategy should handle emergency exit', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(toWantUnit('100'));
      let stratBalance = await strategy.balanceOf();
      let expectedStrategyBalance = toWantUnit('900');
      let smallDifference = expectedStrategyBalance.div(1e12);
      let isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.setEmergencyShutdown(true);
      await strategy.harvest();
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(toWantUnit('1000'));
      stratBalance = await strategy.balanceOf();
      smallDifference = vaultBalance.div(1e12);
      isSmallBalanceDifference = stratBalance.lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });
  });
});
