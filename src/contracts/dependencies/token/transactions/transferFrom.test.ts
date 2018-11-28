import { createQuantity } from '@melonproject/token-math/quantity';
import { Address } from '@melonproject/token-math/address';

import { initTestEnvironment } from '~/utils/environment/initTestEnvironment';
import { getGlobalEnvironment } from '~/utils/environment/globalEnvironment';
import { approve } from '../transactions/approve';
import { transferFrom } from '../transactions/transferFrom';
import { deployToken } from '../transactions/deploy';
import { getToken } from '../calls/getToken';

const shared: any = {};

beforeAll(async () => {
  await initTestEnvironment();
  shared.address = await deployToken();
  shared.token = await getToken(shared.address);
});

test('transferFrom', async () => {
  const environment = getGlobalEnvironment();
  const accounts = await environment.eth.getAccounts();
  const howMuch = createQuantity(shared.token, '1000000000000000000');

  await approve({ howMuch, spender: new Address(accounts[0]) });

  const receipt = await transferFrom({
    from: new Address(accounts[0]),
    howMuch,
    to: new Address(accounts[1]),
  });

  expect(receipt).toBeTruthy();
});
