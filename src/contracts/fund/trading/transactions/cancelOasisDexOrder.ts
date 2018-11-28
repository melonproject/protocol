import {
  PrepareArgsFunction,
  withTransactionDecorator,
  GuardFunction,
  PostProcessFunction,
} from '~/utils/solidity/transactionFactory';
import { getDeployment } from '~/utils/solidity/getDeployment';
import { Address } from '@melonproject/token-math/address';
import { getExchangeIndex } from '../calls/getExchangeIndex';
// tslint:disable:max-line-length
import { callOnExchange } from '~/contracts/fund/trading/transactions/callOnExchange';
import { getGlobalEnvironment } from '~/utils/environment/globalEnvironment';
import { ensureFundOwner } from '~/contracts/fund/trading/guards/ensureFundOwner';
import * as web3Utils from 'web3-utils';
// tslint:enable:max-line-length

export type CancelOasisDexOrderResult = any;

export interface CancelOasisDexOrderArgs {
  id: number;
  maker: Address;
  makerAsset: Address;
  takerAsset: Address;
}

const guard: GuardFunction<CancelOasisDexOrderArgs> = async (
  { id, maker, makerAsset, takerAsset },
  contractAddress,
  environment = getGlobalEnvironment(),
) => {
  // const hubAddress = await getHub(contractAddress, environment);
  // const { vaultAddress } = await getSettings(hubAddress);

  await ensureFundOwner(contractAddress, environment);
};

const prepareArgs: PrepareArgsFunction<CancelOasisDexOrderArgs> = async (
  { id, maker, makerAsset, takerAsset },
  contractAddress,
  environment = getGlobalEnvironment(),
) => {
  const deployment = await getDeployment();

  const matchingMarketAddress = deployment.exchangeConfigs.find(
    o => o.name === 'MatchingMarket',
  ).exchangeAddress;

  const exchangeIndex = await getExchangeIndex(
    matchingMarketAddress,
    contractAddress,
    environment,
  );

  return {
    dexySignatureMode: 0,
    exchangeIndex,
    feeRecipient: '0x0000000000000000000000000000000000000000',
    fillTakerTokenAmount: '0',
    identifier: id,
    maker,
    makerAsset,
    makerAssetData: web3Utils.padLeft('0x0', 64),
    makerFee: '0',
    makerQuantity: '0',
    method:
      // update when function signature changes
      'cancelOrder(address,address[6],uint256[8],bytes32,bytes,bytes,bytes)',
    salt: '0',
    senderAddress: '0x0000000000000000000000000000000000000000',
    signature: web3Utils.padLeft('0x0', 64),
    taker: '0x0000000000000000000000000000000000000000',
    takerAsset,
    takerAssetData: web3Utils.padLeft('0x0', 64),
    takerFee: '0',
    takerQuantity: '0',
    timestamp: '0',
  };
};

const postProcess: PostProcessFunction<
  CancelOasisDexOrderArgs,
  CancelOasisDexOrderResult
> = async receipt => {
  return {
    id: web3Utils.toDecimal(receipt.events.LogKill.returnValues.id),
  };
};

const options = { gas: '8000000' };

const cancelOasisDexOrder = withTransactionDecorator(callOnExchange, {
  guard,
  options,
  postProcess,
  prepareArgs,
});

export { cancelOasisDexOrder };
