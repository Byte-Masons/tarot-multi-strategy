async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyTarot');
  await hre.upgrades.upgradeProxy('0x0C13a59a95da229562eF8Fa47C9B117b2F3C51Bb', stratFactory, {
    timeout: 0,
  });
  console.log('Strategy upgraded!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
