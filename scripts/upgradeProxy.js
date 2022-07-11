async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyTarot');
  await hre.upgrades.upgradeProxy('0xDd957FbBdB549B957A1Db92b88bBA5297D0BbE99', stratFactory, {
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
