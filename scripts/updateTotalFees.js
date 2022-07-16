async function main() {
  const Strategy = await ethers.getContractFactory('ReaperStrategyTarot');
  const strategyAddresses = [
    '0xd2e77d311dDca106d64c61E8CCb258d37636dd68',
    '0xa641bB87c1ed73D7C2c1a9B5cBa409CBBF6bE3A3',
    '0x303DF25f303376ebb84D0F2F0139E7b0C7F3Bf43',
    '0x18b746E7304Bd7ed3feAF4657D237907191DdB69',
    '0x31A8616375259f7EBc4D67aAf8dEdEB6947F20e1',
    '0xec249B7F643539D1A4B752D8f98C07E194Bcc058',
    '0xaaBFBC79DaaA5e9B882EE10D4acCB96c72e366A8',
    '0x58907Ac386dB688860125bdB035Ae24505fA28e4',
    '0x3c399524c9BC775E1BdF7f3aA3F9851ea8140527',
    '0x824CcC6e02Ad721197D8A50B3a371bF2ba6E4405',
    '0xB85e3e31cC226218bFc3a43DE181370CfE3F96FA',
    '0x2fbEDa4876341Ef0Bcb4AA9e135Bb99e41A09CC4',
    '0x78c436272fA7d3CFEf1cEE0B3c14d9f5C4856647',
    '0xCF266AF4b6688352fFD08BAeA9b58ff89ff09A3a',
    '0x6613B0772F9841A0a21e14B7ce422760F7f22CAB',
    '0x25CfE6b6F28F56F4250455fe52B0fcd637db1195',
  ];

  for (let i = 0; i < strategyAddresses.length; i++) {
    const strategyAddress = strategyAddresses[i];
    const strategy = Strategy.attach(strategyAddress);
    console.log(`Updating fees for: ${strategyAddress}`);
    const newFee = 1000;
    const tx = await strategy.updateTotalFee(newFee);
    await tx.wait();
    console.log('Fees updated!');
    await new Promise((r) => setTimeout(r, 4000));
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
