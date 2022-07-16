async function main() {
  const vaultAddress = '0xa9A9dB466685F977F9ECEe347958bcef90498177';
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
