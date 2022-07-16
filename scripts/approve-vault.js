async function main() {
  const vaultAddress = '0xeb7761d05A31769D35073f703dD3a41f3ca9bD3d';
  const ERC20 = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');
  const wantAddress = '0x321162Cd933E2Be498Cd2267a90534A804051b11';
  const want = await ERC20.attach(wantAddress);
  await want.approve(vaultAddress, ethers.utils.parseEther('1000'));
  console.log('want approved');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
