import { Address } from '@melonproject/token-math/address';

import { Environment } from '~/utils/environment/Environment';
import { deploy as deployContract } from '~/utils/solidity/deploy';
import { Contracts } from '~/Contracts';

export const deploy = async (
  environment: Environment,
  priceSource: Address,
  delay: number,
  mlnAddress: Address,
) => {
  const address = await deployContract(environment, Contracts.Engine, [
    priceSource.toString(),
    delay,
    mlnAddress.toString(),
  ]);

  return address;
};