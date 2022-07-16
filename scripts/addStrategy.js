async function main() {
  const vaultAddress = '0xeb7761d05A31769D35073f703dD3a41f3ca9bD3d';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0x7f438CFB14F6089C617c79D516Dea73052eb5c29';
  const strategyAllocation = 40;
  await vault.addStrategy(strategyAddress, strategyAllocation);
  console.log('Strategy added!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
