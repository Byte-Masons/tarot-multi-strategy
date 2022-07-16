const hre = require('hardhat');

async function main() {
  const vaultAddress = '0xeb7761d05A31769D35073f703dD3a41f3ca9bD3d';

  const Strategy = await ethers.getContractFactory('ReaperStrategyTarot');

  const treasuryAddress = '0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b';
  const paymentSplitterAddress = '0x63cbd4134c2253041F370472c130e92daE4Ff174';

  const strategist1 = '0x1E71AEE6081f62053123140aacC7a06021D77348';
  const strategist2 = '0x81876677843D00a7D792E1617459aC2E93202576';
  const strategist3 = '0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4';

  const superAdmin = '0x04C710a1E8a738CDf7cAD3a52Ba77A784C35d8CE';
  const admin = '0x539eF36C804e4D735d8cAb69e8e441c12d4B88E0';
  const guardian = '0xf20E25f2AB644C8ecBFc992a6829478a85A98F2c';

  const usdcAddress = '0x04068da6c83afcfa0e13ba15a6696662335d5b75';
  const wftmAddress = '0x21be370d5312f44cb42ce377bc9b8a0cef1a4c83';
  const wantAddress = '0x321162Cd933E2Be498Cd2267a90534A804051b11';
  const wantToUsdcPath = [wantAddress, wftmAddress, usdcAddress];
  const poolIndex = 37;
  const routerType = 0;

  const strategy = await hre.upgrades.deployProxy(
    Strategy,
    [
      vaultAddress,
      [treasuryAddress, paymentSplitterAddress],
      [strategist1, strategist2, strategist3],
      [superAdmin, admin, guardian],
      wantToUsdcPath,
      poolIndex,
      routerType,
    ],
    {kind: 'uups', timeout: 0},
  );

  await strategy.deployed();
  console.log('Strategy deployed to:', strategy.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
