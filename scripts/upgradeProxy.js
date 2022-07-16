async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyTarot');
  await hre.upgrades.upgradeProxy('0x7f438CFB14F6089C617c79D516Dea73052eb5c29', stratFactory, {
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
