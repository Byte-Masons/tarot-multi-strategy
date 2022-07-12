async function main() {
  const vaultAddress = '0x9B7bd49E37195Ea029BdDCBEF14e4eB2349DDe0E';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0xA26FFf7821FEd25eb37AF785c04c743649cE6EDb';
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
