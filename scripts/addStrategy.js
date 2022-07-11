async function main() {
  const vaultAddress = '0x17D099fc623bd06CFE4861d874704Af184773c75';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0xDd957FbBdB549B957A1Db92b88bBA5297D0BbE99';
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
