/*
 * @file Tests fund accounting calculations in a real fund
 *
 * @test initial investment (with quote token)
 * @test sending quote token directly to Trading does not affect fund calcs
 */

import { BN, toWei } from 'web3-utils';
import { call, send } from '~/deploy/utils/deploy-contract';
import { partialRedeploy } from '~/deploy/scripts/deploy-system';
import { CONTRACT_NAMES } from '~/tests/utils/constants';
import { investInFund, setupFundWithParams } from '~/tests/utils/fund';
import getAccounts from '~/deploy/utils/getAccounts';

let deployer, manager, investor;
let defaultTxOpts;
let mln, weth;
let fund;

beforeAll(async () => {
  [deployer, manager, investor] = await getAccounts();
  defaultTxOpts = { from: deployer, gas: 8000000 };

  const deployed = await partialRedeploy([CONTRACT_NAMES.FUND_FACTORY]);
  const contracts = deployed.contracts;

  mln = contracts.MLN;
  weth = contracts.WETH;
  const fundFactory = contracts.FundFactory;

  fund = await setupFundWithParams({
    defaultTokens: [mln.options.address, weth.options.address],
    manager,
    quoteToken: weth.options.address,
    fundFactory
  });
});

test('initial investment (with quote token)', async () => {
  const { accounting, hub } = fund;

  const contribAmount = toWei('1', 'ether');

  await investInFund({
    fundAddress: hub.options.address,
    investment: {
      contribAmount,
      investor,
      isInitial: true,
      tokenContract: weth
    }
  });

  const fundWethHoldings = await call(accounting, 'getFundHoldingsForAsset', [weth.options.address])
  const fundCalculations = await call(accounting, 'calcFundMetrics');

  expect(fundWethHoldings).toBe(contribAmount);
  expect(fundCalculations.gav_).toBe(contribAmount);
  expect(fundCalculations.feesInDenominationAsset_).toBe('0');
  expect(fundCalculations.feesInShares_).toBe('0');
  expect(fundCalculations.nav_).toBe(contribAmount);
  expect(fundCalculations.sharePrice_).toBe(contribAmount);
});

test('sending quote token directly to Trading does NOT affect fund calculations', async () => {
  const { accounting, vault } = fund;
  const tokenQuantity = toWei('1', 'ether');

  const preFundCalculations = await call(accounting, 'calcFundMetrics');
  const preFundWethHoldings = new BN(
    await call(accounting, 'getFundHoldingsForAsset', [weth.options.address])
  );

  await send(weth, 'transfer', [vault.options.address, tokenQuantity], defaultTxOpts);

  const postFundCalculations = await call(accounting, 'calcFundMetrics');
  const postFundWethHoldings = new BN(
    await call(accounting, 'getFundHoldingsForAsset', [weth.options.address])
  );
  
  expect(postFundWethHoldings).bigNumberEq(preFundWethHoldings);
  expect(postFundCalculations).toEqual(preFundCalculations);
});
