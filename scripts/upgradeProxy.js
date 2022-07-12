async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyTarot');
  await hre.upgrades.upgradeProxy('0xA26FFf7821FEd25eb37AF785c04c743649cE6EDb', stratFactory, {
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
