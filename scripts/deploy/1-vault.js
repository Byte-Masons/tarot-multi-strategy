async function main() {
  const Vault = await ethers.getContractFactory('ReaperVaultV2');

  const wantAddress = '0x4200000000000000000000000000000000000006';
  const tokenName = 'ETH Crypt';
  const tokenSymbol = 'rfETH';
  const tvlCap = ethers.utils.parseEther('1');

  const strategist1 = '0x1E71AEE6081f62053123140aacC7a06021D77348';
  const strategist2 = '0x81876677843D00a7D792E1617459aC2E93202576';
  const strategist3 = '0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4';

  const superAdmin = '0x9BC776dBb134Ef9D7014dB1823Cd755Ac5015203';
  const admin = '0xeb9C9b785aA7818B2EBC8f9842926c4B9f707e4B';
  const guardian = '0xb0C9D5851deF8A2Aac4A23031CA2610f8C3483F9';

  const strategists = [strategist1, strategist2, strategist3];
  const multisigRoles = [superAdmin, admin, guardian];

  const vault = await Vault.deploy(wantAddress, tokenName, tokenSymbol, tvlCap, strategists, multisigRoles);

  await vault.deployed();
  console.log('Vault deployed to:', vault.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
