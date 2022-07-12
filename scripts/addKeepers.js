async function main() {
  const strategyAddress = '0x4DD7B43D1B9920D78e8016a74DAdcA8f472573aD';
  const Strategy = await ethers.getContractFactory('ReaperStrategyTarot');
  const strategy = Strategy.attach(strategyAddress);

  const keeperAddress = ['0x9ccA5c3829224F7ac9077540bC365De4384823A7'];

  const keeperRole = '0x71a9859d7dd21b24504a6f306077ffc2d510b4d4b61128e931fe937441ad1836';

  for (let i = 0; i < keeperAddress.length; i++) {
    const keeper = keeperAddress[i];
    console.log(`Granting keeper role to: ${keeper}`);
    const tx = await strategy.grantRole(keeperRole, keeper);
    await tx.wait();
    console.log('Keeper role granted!');
    await new Promise((r) => setTimeout(r, 4000));
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
