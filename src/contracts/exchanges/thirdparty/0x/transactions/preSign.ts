import { Address } from '@melonproject/token-math/address';
import { SignedOrder, orderHashUtils } from '0x.js';

import { Contracts } from '~/Contracts';
import {
  PrepareArgsFunction,
  EnhancedExecute,
  transactionFactory,
} from '~/utils/solidity/transactionFactory';

interface PreSignArgs {
  signedOrder: SignedOrder;
  signerAddress?: Address;
}

type PreSignResult = boolean;

const prepareArgs: PrepareArgsFunction<PreSignArgs> = async (
  { signedOrder, signerAddress: providedSignerAddress },
  contractAddress,
  environment,
) => {
  const hash = orderHashUtils.getOrderHashHex(signedOrder);
  const signerAddress = providedSignerAddress || environment.wallet.address;
  const args = [hash, signerAddress.toLocaleLowerCase(), signedOrder.signature];
  return args;
};

const preSign: EnhancedExecute<PreSignArgs, PreSignResult> = transactionFactory(
  'preSign',
  Contracts.ZeroExExchange,
  undefined,
  prepareArgs,
);

export { preSign };