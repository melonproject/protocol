const fs = require('fs');
const Web3 = require('web3');
const deployIn = require('./get-deploy-input');

const web3 = new Web3(
  deployIn.conf.provider,
  null,
  { transactionConfirmationBlocks: 1 }
);

// TODO: get keys from a non-ganache setup

// get private keys stored in a file, like that produced by ganache --acctKeys
if (process.env.GANACHE_KEYS) { // TODO: move away from env var
  const keys = JSON.parse(fs.readFileSync(process.env.GANACHE_KEYS));
  for (let [addr, pkey] of Object.entries(keys.private_keys)) {
    if (!pkey.startsWith('0x')) {
      pkey = '0x' + pkey;
    }
    web3.eth.accounts.wallet.add({
      address: addr,
      privateKey: pkey
    });
  }
}

module.exports = web3;