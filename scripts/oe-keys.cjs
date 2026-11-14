#!/usr/bin/env node
/*
 * oe-keys — key/keystore + chain utilities for the Ocean Enterprise launcher.
 *
 * All output is a single JSON object on stdout so the shell can consume it
 * with `jq -r`. Diagnostics go to stderr.
 *
 * Subcommands
 *   encrypt --out <file> [--key 0x..|--random] [--password-file F|--password-stdin]
 *   decrypt --keystore <file> [--password-file F|--password-stdin]
 *   address --keystore <file> [--password-file F|--password-stdin]
 *   netinfo --rpc <url> [--address 0x..] [--token 0x..]
 *   balance --rpc <url> --address 0x..            (wei + ETH on any EVM chain)
 *   watch-balance --rpc <url> --address 0x.. --min-eth 0.05 [--timeout 1800] [--interval 15]
 *   bridge  --keystore <file> --rpc <L1 url> --bridge 0x.. --to 0x.. --amount-eth 0.05
 *           [--password-file F|--password-stdin] [--expect-chain-id 11155111]
 *           [--min-gas-limit 200000] [--dry-run]   (L1StandardBridge.depositETHTo)
 *   units   --amount <decimal> [--decimals 18]
 *
 * Requires `ethers` v6 resolvable from node's module path (the launcher
 * installs it into <repo>/.tools/node_modules and sets NODE_PATH).
 */
'use strict';

const fs = require('fs');
const path = require('path');

function die(msg) {
  process.stderr.write('oe-keys: ' + msg + '\n');
  process.exit(1);
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { out._.push(...argv.slice(i + 1)); break; }
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq > -1) { out[a.slice(2, eq)] = a.slice(eq + 1); continue; }
      const name = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[name] = true;
      else { out[name] = next; i++; }
    } else out._.push(a);
  }
  return out;
}

function requireEthers() {
  try {
    return require('ethers');
  } catch (e) {
    die('the "ethers" module is not resolvable — run ./customize.sh once so it can be installed into .tools/');
  }
}

function readPassword(o) {
  if (typeof o['password-file'] === 'string') {
    try {
      return fs.readFileSync(o['password-file'], 'utf8').replace(/\r?\n$/, '');
    } catch (e) {
      die('cannot read --password-file: ' + e.message);
    }
  }
  if (o['password-stdin']) {
    const data = fs.readFileSync(0, 'utf8');
    return data.replace(/\r?\n$/, '');
  }
  die('no password source (use --password-file or --password-stdin)');
}

function writePrivate(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, contents, { mode: 0o600 });
  try { fs.chmodSync(file, 0o600); } catch (e) { /* best effort */ }
}

async function cmdEncrypt(o) {
  const { Wallet } = requireEthers();
  if (typeof o.out !== 'string') die('--out is required');
  const password = readPassword(o);
  if (!password) die('empty keystore password refused');

  let wallet;
  if (typeof o.key === 'string') {
    if (!/^0x[0-9a-fA-F]{64}$/.test(o.key)) die('--key must be 0x + 64 hex characters');
    try { wallet = new Wallet(o.key); } catch (e) { die('invalid private key: ' + e.message); }
  } else if (o.random) {
    wallet = Wallet.createRandom();
  } else {
    die('either --key <hex> or --random is required');
  }

  const json = await wallet.encrypt(password);
  // ethers emits "Crypto" (capitalised); the canonical Web3 Secret Storage
  // spelling used by geth/MetaMask/eth-keyfile is lowercase "crypto".
  let keystore = JSON.parse(json);
  if (keystore.Crypto && !keystore.crypto) {
    keystore.crypto = keystore.Crypto;
    delete keystore.Crypto;
  }
  const text = JSON.stringify(keystore);
  writePrivate(o.out, text.endsWith('\n') ? text : text + '\n');
  process.stdout.write(JSON.stringify({ address: wallet.address, keystore: o.out }) + '\n');
}

async function openKeystore(o) {
  const { Wallet } = requireEthers();
  if (typeof o.keystore !== 'string') die('--keystore is required');
  let json;
  try {
    json = fs.readFileSync(o.keystore, 'utf8');
  } catch (e) {
    die('cannot read keystore: ' + e.message);
  }
  const password = readPassword(o);
  try {
    const w = await Wallet.fromEncryptedJson(json, password);
    return new Wallet(w.privateKey);
  } catch (e) {
    die('cannot decrypt ' + o.keystore + ' (wrong password or corrupt file)');
  }
}

async function cmdDecrypt(o) {
  const w = await openKeystore(o);
  process.stdout.write(JSON.stringify({ address: w.address, privateKey: w.privateKey }) + '\n');
}

async function cmdAddress(o) {
  const w = await openKeystore(o);
  process.stdout.write(JSON.stringify({ address: w.address, keystore: o.keystore }) + '\n');
}

async function cmdNetinfo(o) {
  const { JsonRpcProvider, Contract, formatEther, formatUnits } = requireEthers();
  if (typeof o.rpc !== 'string') die('--rpc is required');
  const provider = new JsonRpcProvider(o.rpc, undefined, { staticNetwork: true });

  const result = { rpc: o.rpc };
  try {
    const net = await provider.getNetwork();
    result.chainId = net.chainId.toString();
    result.head = await provider.getBlockNumber();
  } catch (e) {
    die('RPC unreachable (' + o.rpc + '): ' + (e.shortMessage || e.message));
  }

  if (typeof o.address === 'string') {
    if (!/^0x[0-9a-fA-F]{40}$/.test(o.address)) die('--address must be 0x + 40 hex characters');
    try {
      result.eth = formatEther(await provider.getBalance(o.address));
    } catch (e) {
      result.eth = null;
    }
    if (typeof o.token === 'string') {
      try {
        const erc20 = new Contract(
          o.token,
          [
            'function balanceOf(address) view returns (uint256)',
            'function decimals() view returns (uint8)',
            'function symbol() view returns (string)'
          ],
          provider
        );
        const [raw, decimals, symbol] = await Promise.all([
          erc20.balanceOf(o.address),
          erc20.decimals().catch(() => 18),
          erc20.symbol().catch(() => null)
        ]);
        result.token = { address: o.token, symbol, raw: raw.toString(), formatted: formatUnits(raw, decimals) };
      } catch (e) {
        result.token = null;
      }
    }
  }

  process.stdout.write(JSON.stringify(result) + '\n');
  // JsonRpcProvider keeps sockets/pollers alive; exit explicitly.
  process.exit(0);
}

async function cmdBalance(o) {
  const { JsonRpcProvider, formatEther } = requireEthers();
  if (typeof o.rpc !== 'string') die('--rpc is required');
  if (!/^0x[0-9a-fA-F]{40}$/.test(o.address || '')) die('--address must be 0x + 40 hex characters');
  const provider = new JsonRpcProvider(o.rpc, undefined, { staticNetwork: true });
  let chainId;
  let wei;
  try {
    chainId = (await provider.getNetwork()).chainId.toString();
    wei = await provider.getBalance(o.address);
  } catch (e) {
    die('RPC unreachable (' + o.rpc + '): ' + (e.shortMessage || e.message));
  }
  process.stdout.write(
    JSON.stringify({ rpc: o.rpc, chainId, address: o.address, wei: wei.toString(), eth: formatEther(wei) }) + '\n'
  );
  process.exit(0);
}

async function cmdWatchBalance(o) {
  const { JsonRpcProvider, formatEther, parseEther } = requireEthers();
  const { setTimeout: sleep } = require('timers/promises');
  if (typeof o.rpc !== 'string') die('--rpc is required');
  if (!/^0x[0-9a-fA-F]{40}$/.test(o.address || '')) die('--address must be 0x + 40 hex characters');
  let min;
  try {
    min = parseEther(String(o['min-eth'] === undefined ? '0' : o['min-eth']));
  } catch (e) {
    die('--min-eth must be a decimal amount, e.g. 0.05');
  }
  const timeout = Number(o.timeout === undefined ? 1800 : o.timeout);
  const interval = Number(o.interval === undefined ? 15 : o.interval);
  if (!Number.isFinite(timeout) || timeout <= 0) die('--timeout must be seconds > 0');
  if (!Number.isFinite(interval) || interval <= 0) die('--interval must be seconds > 0');

  const provider = new JsonRpcProvider(o.rpc, undefined, { staticNetwork: true });
  const started = Date.now();
  let wei;
  for (;;) {
    try {
      wei = await provider.getBalance(o.address);
    } catch (e) {
      process.stderr.write('oe-keys: poll failed (' + (e.shortMessage || e.message) + '), retrying\n');
      wei = null;
    }
    const waited = Math.round((Date.now() - started) / 1000);
    if (wei !== null && wei >= min) {
      process.stdout.write(
        JSON.stringify({ address: o.address, rpc: o.rpc, eth: formatEther(wei), wei: wei.toString(), reached: true, waitedSec: waited }) + '\n'
      );
      process.exit(0);
    }
    if (waited >= timeout) {
      process.stdout.write(
        JSON.stringify({
          address: o.address,
          rpc: o.rpc,
          eth: wei === null ? null : formatEther(wei),
          wei: wei === null ? null : wei.toString(),
          reached: false,
          waitedSec: waited
        }) + '\n'
      );
      process.exit(0);
    }
    process.stderr.write(
      '  ' + waited + 's: ' + (wei === null ? '?' : formatEther(wei)) + ' ETH (waiting for ' +
      formatEther(min) + ')\n'
    );
    await sleep(interval * 1000);
  }
}

async function cmdBridge(o) {
  const { JsonRpcProvider, Contract, formatEther, parseEther } = requireEthers();
  if (typeof o.rpc !== 'string') die('--rpc is required (the L1 RPC, e.g. Sepolia)');
  if (!/^0x[0-9a-fA-F]{40}$/.test(o.bridge || '')) die('--bridge must be the L1StandardBridge address');
  const to = o.to;
  if (!/^0x[0-9a-fA-F]{40}$/.test(to || '')) die('--to must be 0x + 40 hex characters');
  let value;
  if (typeof o['amount-wei'] === 'string') {
    if (!/^[0-9]+$/.test(o['amount-wei'])) die('--amount-wei must be an integer (wei)');
    value = BigInt(o['amount-wei']);
  } else if (typeof o['amount-eth'] === 'string') {
    try {
      value = parseEther(o['amount-eth']);
    } catch (e) {
      die('--amount-eth must be a decimal amount, e.g. 0.05');
    }
  } else {
    die('--amount-eth <decimal> or --amount-wei <integer> is required');
  }
  if (value <= 0n) die('the amount to bridge must be > 0');
  const minGasLimit = Number(o['min-gas-limit'] === undefined ? 200000 : o['min-gas-limit']);
  if (!Number.isInteger(minGasLimit) || minGasLimit < 21000) die('--min-gas-limit must be an integer >= 21000');

  if (typeof o.keystore !== 'string') die('--keystore is required');
  let keystoreJson;
  try {
    keystoreJson = fs.readFileSync(o.keystore, 'utf8');
  } catch (e) {
    die('cannot read keystore: ' + e.message);
  }
  // --dry-run can plan the deposit without the password: the keystore JSON
  // carries the address, and eth_estimateGas accepts a "from" without a key.
  const hasPasswordSource = typeof o['password-file'] === 'string' || Boolean(o['password-stdin']);
  const needSigner = !o['dry-run'] || hasPasswordSource;
  let signer = null;
  let from;
  if (needSigner) {
    signer = await openKeystore(o);
    from = signer.address;
  } else {
    try {
      from = '0x' + JSON.parse(keystoreJson).address;
    } catch (e) {
      die('keystore is not valid JSON: ' + e.message);
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(from)) die('keystore does not contain an address');
  }
  if (o['dry-run'] && typeof o.from === 'string') {
    if (!/^0x[0-9a-fA-F]{40}$/.test(o.from)) die('--from must be 0x + 40 hex characters');
    from = o.from; // plan only: lets you estimate with any address, no key needed
  }
  const provider = new JsonRpcProvider(o.rpc, undefined, { staticNetwork: true });
  const connected = signer ? signer.connect(provider) : provider;

  let chainId;
  try {
    chainId = (await provider.getNetwork()).chainId.toString();
  } catch (e) {
    die('RPC unreachable (' + o.rpc + '): ' + (e.shortMessage || e.message));
  }
  if (o['expect-chain-id'] !== undefined && String(o['expect-chain-id']) !== chainId) {
    die('wrong network: ' + o.rpc + ' is chain ' + chainId + ', expected ' + o['expect-chain-id']);
  }

  const abi = [
    'function depositETHTo(address _to, uint32 _minGasLimit, bytes _extraData) payable',
    'function depositETH(uint32 _minGasLimit, bytes _extraData) payable'
  ];
  const bridge = new Contract(o.bridge, abi, connected);

  const [feeData, balance] = await Promise.all([
    provider.getFeeData(),
    provider.getBalance(from)
  ]);
  const gasPrice = feeData.maxFeePerGas || feeData.gasPrice || 0n;

  let gasEstimate = null;
  let planNote = null;
  try {
    gasEstimate = await bridge.depositETHTo.estimateGas(to, minGasLimit, '0x', { value, from });
  } catch (e) {
    if (!o['dry-run']) die('depositETHTo would revert: ' + (e.shortMessage || e.message));
    // An unfunded sender makes estimation fail on most nodes; that is not a
    // revert, so keep the plan and say the gas figure is unknown.
    planNote = 'gas not estimated (' + (e.shortMessage || e.message) + ') — a deposit uses ~130k gas';
  }
  const feeCeiling = gasEstimate === null ? null : gasEstimate * gasPrice;
  const needed = feeCeiling === null ? value : value + feeCeiling;
  if (balance < needed && !o['dry-run']) {
    die(
      'not enough L1 ETH: have ' + formatEther(balance) + ', need ~' + formatEther(needed) +
      ' (' + formatEther(value) + ' to bridge + gas)'
    );
  }
  if (!o['dry-run'] && gasEstimate === null) die('could not estimate the deposit gas');

  if (o['dry-run']) {
    process.stdout.write(
      JSON.stringify({
        dryRun: true,
        chainId,
        from,
        to,
        bridge: o.bridge,
        value: value.toString(),
        amountEth: formatEther(value),
        data: bridge.interface.encodeFunctionData('depositETHTo', [to, minGasLimit, '0x']),
        minGasLimit,
        gasEstimate: gasEstimate === null ? null : gasEstimate.toString(),
        gasPrice: gasPrice.toString(),
        estimatedFee: feeCeiling === null ? null : formatEther(feeCeiling),
        balance: formatEther(balance),
        note: planNote
      }) + '\n'
    );
    process.exit(0);
  }

  let tx;
  try {
    tx = await bridge.depositETHTo(to, minGasLimit, '0x', {
      value,
      gasLimit: (gasEstimate * 12n) / 10n
    });
  } catch (e) {
    die('could not send the deposit: ' + (e.shortMessage || e.message));
  }
  process.stderr.write('  sent ' + tx.hash + ' — waiting for the L1 receipt\n');
  let receipt;
  try {
    receipt = await tx.wait(1);
  } catch (e) {
    die('deposit tx ' + tx.hash + ' did not confirm: ' + (e.shortMessage || e.message));
  }
  if (!receipt || receipt.status !== 1) {
    die('deposit tx ' + tx.hash + ' reverted');
  }
  process.stdout.write(
    JSON.stringify({
      txHash: receipt.hash,
      status: receipt.status,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      fee: formatEther(receipt.gasUsed * (receipt.gasPrice || gasPrice)),
      from,
      to,
      amountEth: formatEther(value)
    }) + '\n'
  );
  process.exit(0);
}

async function cmdSend(o) {
  const { JsonRpcProvider, formatEther, parseEther } = requireEthers();
  if (typeof o.rpc !== 'string') die('--rpc is required');
  if (!/^0x[0-9a-fA-F]{40}$/.test(o.to || '')) die('--to must be 0x + 40 hex characters');
  let value;
  if (typeof o['amount-wei'] === 'string') {
    if (!/^[0-9]+$/.test(o['amount-wei'])) die('--amount-wei must be an integer (wei)');
    value = BigInt(o['amount-wei']);
  } else if (typeof o['amount-eth'] === 'string') {
    try {
      value = parseEther(o['amount-eth']);
    } catch (e) {
      die('--amount-eth must be a decimal amount, e.g. 0.02');
    }
  } else {
    die('--amount-eth <decimal> or --amount-wei <integer> is required');
  }
  if (value <= 0n) die('the amount must be > 0');

  if (typeof o.keystore !== 'string') die('--keystore is required');
  let keystoreJson;
  try {
    keystoreJson = fs.readFileSync(o.keystore, 'utf8');
  } catch (e) {
    die('cannot read keystore: ' + e.message);
  }
  const hasPasswordSource = typeof o['password-file'] === 'string' || Boolean(o['password-stdin']);
  const needSigner = !o['dry-run'] || hasPasswordSource;
  let signer = null;
  let from;
  if (needSigner) {
    signer = await openKeystore(o);
    from = signer.address;
  } else {
    try {
      from = '0x' + JSON.parse(keystoreJson).address;
    } catch (e) {
      die('keystore is not valid JSON: ' + e.message);
    }
  }
  if (o['dry-run'] && typeof o.from === 'string') from = o.from;

  const provider = new JsonRpcProvider(o.rpc, undefined, { staticNetwork: true });
  let chainId;
  try {
    chainId = (await provider.getNetwork()).chainId.toString();
  } catch (e) {
    die('RPC unreachable (' + o.rpc + '): ' + (e.shortMessage || e.message));
  }
  if (o['expect-chain-id'] !== undefined && String(o['expect-chain-id']) !== chainId) {
    die('wrong network: ' + o.rpc + ' is chain ' + chainId + ', expected ' + o['expect-chain-id']);
  }

  const [feeData, balance] = await Promise.all([provider.getFeeData(), provider.getBalance(from)]);
  const gasPrice = feeData.maxFeePerGas || feeData.gasPrice || 0n;
  let gasEstimate = null;
  let planNote = null;
  try {
    gasEstimate = await provider.estimateGas({ from, to: o.to, value });
  } catch (e) {
    if (!o['dry-run']) die('the transfer would fail: ' + (e.shortMessage || e.message));
    planNote = balance < value
      ? 'balance too low for this amount (have ' + formatEther(balance) + ', sending ' + formatEther(value) + ')'
      : 'gas not estimated (' + (e.shortMessage || e.message) + ') — a transfer uses 21000';
  }
  const feeCeiling = gasEstimate === null ? null : gasEstimate * gasPrice;
  const needed = feeCeiling === null ? value : value + feeCeiling;

  if (o['dry-run']) {
    process.stdout.write(
      JSON.stringify({
        dryRun: true,
        chainId,
        from,
        to: o.to,
        amountEth: formatEther(value),
        value: value.toString(),
        gasEstimate: gasEstimate === null ? null : gasEstimate.toString(),
        gasPrice: gasPrice.toString(),
        estimatedFee: feeCeiling === null ? null : formatEther(feeCeiling),
        balance: formatEther(balance),
        note: planNote
      }) + '\n'
    );
    process.exit(0);
  }

  if (balance < needed) {
    die('not enough ETH: have ' + formatEther(balance) + ', need ~' + formatEther(needed));
  }
  if (gasEstimate === null) die('could not estimate the transfer gas');

  let tx;
  try {
    tx = await signer.connect(provider).sendTransaction({
      to: o.to,
      value,
      gasLimit: (gasEstimate * 12n) / 10n
    });
  } catch (e) {
    die('could not send the transfer: ' + (e.shortMessage || e.message));
  }
  process.stderr.write('  sent ' + tx.hash + ' — waiting for the receipt\n');
  const receipt = await tx.wait(1);
  if (!receipt || receipt.status !== 1) die('transfer tx ' + tx.hash + ' failed');
  process.stdout.write(
    JSON.stringify({
      txHash: receipt.hash,
      status: receipt.status,
      from,
      to: o.to,
      amountEth: formatEther(value),
      gasUsed: receipt.gasUsed.toString(),
      fee: formatEther(receipt.gasUsed * (receipt.gasPrice || gasPrice))
    }) + '\n'
  );
  process.exit(0);
}

async function cmdUnits(o) {
  const { parseUnits, formatUnits } = requireEthers();
  if (typeof o.amount !== 'string') die('--amount is required');
  const decimals = o.decimals === undefined ? 18 : Number(o.decimals);
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 36) die('--decimals must be 0..36');
  let raw;
  try {
    raw = parseUnits(o.amount.trim(), decimals).toString();
  } catch (e) {
    die('invalid amount "' + o.amount + '" for ' + decimals + ' decimals');
  }
  process.stdout.write(JSON.stringify({ amount: raw, decimals, human: formatUnits(raw, decimals) }) + '\n');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];
  switch (cmd) {
    case 'encrypt': return cmdEncrypt(args);
    case 'decrypt': return cmdDecrypt(args);
    case 'address': return cmdAddress(args);
    case 'netinfo': return cmdNetinfo(args);
    case 'balance': return cmdBalance(args);
    case 'watch-balance': return cmdWatchBalance(args);
    case 'bridge': return cmdBridge(args);
    case 'send': return cmdSend(args);
    case 'units': return cmdUnits(args);
    default:
      die('usage: oe-keys.cjs {encrypt|decrypt|address|netinfo|balance|watch-balance|bridge|send|units} [options]');
  }
}

main().catch((e) => die(e && e.message ? e.message : String(e)));
