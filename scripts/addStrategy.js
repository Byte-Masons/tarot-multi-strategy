async function main() {
  const vaultAddress = '0x17D099fc623bd06CFE4861d874704Af184773c75';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0x0C13a59a95da229562eF8Fa47C9B117b2F3C51Bb';
  const strategyAllocation = 9990;
  await vault.addStrategy(strategyAddress, strategyAllocation);
  console.log('Strategy added!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
