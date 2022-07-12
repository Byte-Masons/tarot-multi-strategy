async function main() {
  const vaultAddress = '0xfF4eEf59A89E953926Ce5A61C6f68c504D47c7b6';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0x4DD7B43D1B9920D78e8016a74DAdcA8f472573aD';
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
