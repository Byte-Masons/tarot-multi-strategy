async function main() {
  const vaultAddress = '0x9B7bd49E37195Ea029BdDCBEF14e4eB2349DDe0E';
  const ERC20 = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');
  const wantAddress = '0x7F5c764cBc14f9669B88837ca1490cCa17c31607';
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
