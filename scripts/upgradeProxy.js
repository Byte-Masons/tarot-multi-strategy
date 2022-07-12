async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyTarot');
  await hre.upgrades.upgradeProxy('0x4DD7B43D1B9920D78e8016a74DAdcA8f472573aD', stratFactory, {
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
