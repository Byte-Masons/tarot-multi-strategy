async function main() {
  const vaultAddress = '0x17D099fc623bd06CFE4861d874704Af184773c75';
  const ERC20 = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');
  const wantAddress = '';
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
