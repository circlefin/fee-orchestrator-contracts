# fee-orchestrator-contracts

Repository for Circle Fee Orchestrator smart contracts.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (v1.2.3+)
- [Node.js](https://nodejs.org/) (v20+)
- [Yarn](https://classic.yarnpkg.com/) (v1.22+)

## Setup

```bash
# Install Foundry dependencies (forge-std, pinned in foundry.lock).
# Keep the default lib/forge-std location: the remapping is part of every
# contract's compiler metadata, so installing elsewhere changes the bytecode.
forge install --no-git foundry-rs/forge-std@v1.15.0

# Install Node dependencies (solhint, OpenZeppelin, etc.)
yarn install

# Build contracts
yarn build
```

## Development

### Build

```bash
yarn build
```

### Test

```bash
yarn test
```

`yarn test` uses `forge test -j 1` because deploy script tests set `vm.setEnv`; Foundry's default multi-threaded run shares process environment across tests.

### Lint

```bash
# Solhint (Solidity linting)
yarn lint

# Forge fmt (formatting check)
yarn format:check

# Auto-fix formatting
yarn format:write
```

### Coverage

```bash
yarn coverage
```

Coverage enforces a minimum of 90% across lines, statements, branches, and functions.
Exclusions can be configured in `script/coverage/excludedFiles.txt` and `script/coverage/excludedFunctions.txt`.

### Pre-commit hooks

This repo uses [pre-commit](https://pre-commit.com/) to verify that every Solidity
source file carries the Apache-2.0 copyright header
(`script/pre-commit/check-copyright-header.sh`). If a staged `.sol` file is missing
the header, the hook prepends it and fails the commit so you can re-stage the change.

`pre-commit` is a Python tool and is **required** — install it before running
`yarn install`, which activates the git hooks (via the `prepare` script) and
will fail if `pre-commit` is missing:

```bash
brew install pre-commit      # macOS
pipx install pre-commit      # or: pip install pre-commit
```

`yarn install` runs `pre-commit install` for you. To activate manually or run
against all files:

```bash
pre-commit install

# Optional: run against all files
pre-commit run --all-files
```

## Project Structure

```
├── src/
│   ├── access/                    # Reusable abstract contracts (WithConfigurator, WithAllowedCallers, WithTrustedQuoteSigners, WithFeeCollectionAddress)
│   ├── constants/                 # Shared constant definitions
│   │   └── QuoteTypes.sol         #   Canonical quote-type identifiers (FORWARD, PRE_FINALITY)
│   ├── contracts/                 # Concrete contract implementations
│   │   ├── Create3Factory.sol     #   Deterministic deployment factory (CREATE3)
│   │   ├── FeeManager.sol         #   Fee collection against server-signed quotes
│   │   └── TokenMessengerWithFees.sol  #   CCTP wrapper that collects fees via FeeManager
│   ├── interfaces/                # Solidity interfaces
│   ├── libraries/                 # Utility libraries (AddressUtils, BurnMessageV2Lib, HookDataLib, MessageV2Lib, QuoteLib, SignedQuoteLib)
│   └── storage/                   # EIP-7201 namespaced storage libraries
├── test/                          # Foundry test files (.t.sol)
├── lib/                           # Foundry dependencies (forge-std)
├── script/
│   ├── deploy/                    # Forge deployment scripts (.s.sol)
│   │   ├── Addresses.sol          #   Predicts deterministic CREATE3 addresses from factory + salt
│   │   ├── PrintAddresses.s.sol   #   Log predicted addresses (no gas, no transactions)
│   │   ├── DeployCreate3Factory.s.sol
│   │   ├── DeployFeeManager.s.sol
│   │   ├── DeployTokenMessengerWithFees.s.sol
│   │   ├── UpgradeFeeManager.s.sol              #   New impl via CREATE3 + optional UUPS upgrade
│   │   ├── UpgradeTokenMessengerWithFees.s.sol  #   Same for TokenMessengerWithFees
│   │   └── Salts.sol              #   Derives impl/proxy salts from per-contract env vars
│   ├── test/                      # Forge helper/test scripts (.s.sol)
│   │   ├── QuoteScriptUtils.sol                    # Shared quote signing helpers + QUOTE_TYPES parsing
│   │   ├── GenerateSignedTestQuote.s.sol           # Print a signed test quote (console output)
│   │   ├── DepositForBurnWithGeneratedQuote.s.sol  # Burn via TokenMessengerWithFees with a generated quote
│   │   ├── DepositForBurnWithSignedQuote.s.sol     # Burn via TokenMessengerWithFees using a pre-signed quote supplied via env
│   │   ├── cast-deposit-for-burn.sh                # cast send alternative for chains with native precompiles (generates the quote)
│   │   └── cast-deposit-for-burn-with-quote.sh     # cast send alternative for chains with native precompiles (takes a pre-signed quote)
│   └── coverage/                  # Coverage enforcement tooling
├── configs/                       # Environment config templates
├── foundry.toml                   # Foundry configuration
├── package.json                   # Node dependencies & scripts
├── remappings.txt                 # Solidity import remappings
├── .solhint-src.json              # Solhint config for src/
├── .solhint-test.json             # Solhint config for test/
└── .solhint-script.json           # Solhint config for script/
```

## Signed quote wire format

Integrations pass server-signed fee quotes as a **versioned ABI blob**:

`[uint8 version][abi.encode(IFeeManager.Quote)]`

The current `version` byte is `1` (`SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION`). The `Quote` struct is ABI-encoded as produced by Solidity; ECDSA signatures are **65 bytes** (`r ‖ s ‖ v`), matching OpenZeppelin `ECDSA.recover`.

**Decode behavior** (shared by `FeeManager.decodeQuote`, in-process `SignedQuoteLib` in `FeeManager` and `TokenMessengerWithFees`, and the `signedQuote` parameters on those flows):

- Obvious garbage (empty input, tail shorter than the minimum for a valid encoding, or decoded `signature` length not 65) reverts with custom errors such as `SignedQuoteDecodeFailed` or `UnsupportedQuoteVersion`.
- If the tail is long enough to pass cheap checks but still not valid ABI for `Quote`, the compiler may revert with a Solidity **Panic(0x21)** while decoding. Off-chain tooling should treat **any** revert during decode as failure, not only `SignedQuoteDecodeFailed`.
- Successful decode does **not** prove a valid EIP-712 signature; `FeeManager.collectFeesWithQuote` verifies the signer separately.

## Cross-Chain Address Determinism

All contracts are deployed via `Create3Factory` for deterministic addresses across chains. The CREATE3 address depends only on `hash(factory_address, salt)` — it is independent of the creation bytecode. Constructor arguments, compiler settings, or minor code changes do not affect the deployed address.

Each contract has its own proxy and implementation salt env vars: **`FEE_MANAGER_PROXY_SALT`** / **`FEE_MANAGER_IMPLEMENTATION_SALT`** for FeeManager and **`TOKEN_MESSENGER_WITH_FEES_PROXY_SALT`** / **`TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT`** for TokenMessengerWithFees. Keep proxy salts stable so predicted proxy addresses stay the same across implementation upgrades. Bump the implementation salt when deploying a new implementation so CREATE3 does not collide with the previous impl. Use the same proxy salts on every chain where you want identical proxy addresses.

To print the predicted addresses for the current env (no transaction, no `--broadcast`): `forge script script/deploy/PrintAddresses.s.sol --rpc-url $BLOCKCHAIN_RPC_URL` (same factory and salt env vars as deploy; the RPC must be the chain where `CREATE3_FACTORY_ADDRESS` is deployed — `getAddress` is a staticcall to the factory).

## Deployment

`FeeManager` and `TokenMessengerWithFees` are deployed behind UUPS (ERC1967) proxies via `Create3Factory`. Use the **proxy addresses** for integrations; implementations can be upgraded by the owner without changing the proxy address or losing state.

### Downstream dependency

Downstream deployment tooling reuses the Foundry deployment scripts under `script/deploy/` in this repo. Avoid renaming or relocating those scripts, changing `forge script` entry points or signatures, or altering required environment variables and deployment flow without coordinating with the owners of that tooling; otherwise downstream pipelines may break.

### Deploy script invocation

All deploy scripts follow the same pattern. For brevity, subsequent steps show only the script path.

**Local (Anvil)** — start `anvil` in a separate terminal, then:

```bash
forge script <SCRIPT_PATH> --rpc-url http://127.0.0.1:8545 --broadcast
```

**Testnet / Mainnet:**

```bash
forge script <SCRIPT_PATH> \
  --rpc-url $BLOCKCHAIN_RPC_URL \
  --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

For mainnet, consider adding `--slow` and using a hardware wallet (`--ledger`).

### 1. Create and source the env file

```bash
cp configs/.env.dev.template configs/.env.dev
```

Edit `configs/.env.dev` and fill in at minimum:

| Variable | Required for | Description |
|---|---|---|
| `DEPLOYER_PRIVATE_KEY` | all deploys | Private key used to broadcast transactions |
| `BLOCKCHAIN_RPC_URL` | all deploys | RPC endpoint |
| `CREATE3_FACTORY_ADDRESS` | FeeManager, TMWF | Address of the pre-deployed `Create3Factory` (set after step 2) |
| `FEE_MANAGER_PROXY_SALT` | FeeManager | Proxy CREATE3 salt; keep stable across impl upgrades; same value across chains for identical proxy addresses |
| `FEE_MANAGER_IMPLEMENTATION_SALT` | FeeManager | Implementation CREATE3 salt; bump when deploying a new impl (avoids collision) |
| `TOKEN_MESSENGER_WITH_FEES_PROXY_SALT` | TMWF (+ FeeManager deploy) | Proxy CREATE3 salt for TokenMessengerWithFees; FeeManager deploy reads it to predict the TMWF proxy for the allowed caller list |
| `TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT` | TMWF | Implementation CREATE3 salt for TokenMessengerWithFees |
| `FEE_TAKER_ADDRESS` | FeeManager only | Deployed `FeeTaker` proxy on the target chain (immutable constructor arg) |
| `USDC_ADDRESS` | FeeManager only | USDC token contract; must match `FeeTaker`’s configured USDC (immutable constructor arg for `FeeManager.isDenylisted`) |
| `TOKEN_MESSENGER_V2_ADDRESS` | TMWF only | Address of the existing `TokenMessengerV2` on the target chain |

Optional:

| Variable | Description |
|---|---|
| `FEE_MANAGER_CALLER_ADMIN` | If set and non-zero, granted `CALLER_ADMIN_ROLE`; omit to leave unassigned (owner grants via `grantRole` later) |
| `FEE_MANAGER_SIGNER_ADMIN` | If set and non-zero, granted `SIGNER_ADMIN_ROLE`; omit to leave unassigned (owner grants via `grantRole` later) |
| `FEE_MANAGER_FEE_COLLECTION_ADMIN` | If set and non-zero, granted `FEE_COLLECTION_ADMIN_ROLE`; omit to leave unassigned (owner grants via `grantRole` later) |
| `FEE_MANAGER_OWNER` | Final owner address for FeeManager; defaults to the deployer if unset |
| `FEE_MANAGER_TRUSTED_SIGNER` | If non-zero, registered as a trusted quote signer during deploy |
| `FEE_MANAGER_PAUSER` | If non-zero, granted `PAUSER_ROLE` during deploy |
| `FEE_MANAGER_PROXY_ADDRESS` | Deployed FeeManager proxy (quote test scripts, verification) |
| `TOKEN_MESSENGER_WITH_FEES_OWNER` | Final owner address for TokenMessengerWithFees; defaults to the deployer if unset |
| `ETHERSCAN_API_KEY` | Required for `--verify` on testnet/mainnet |

Source the env file in every terminal session before deploying:

```bash
set -o allexport && source configs/.env.dev && set +o allexport
```

### 2. Deploy Create3Factory (once per chain)

```
script/deploy/DeployCreate3Factory.s.sol
```

Record the printed address and set `CREATE3_FACTORY_ADDRESS` in `.env.dev`, then re-source.

### 3. Deploy FeeManager

```
script/deploy/DeployFeeManager.s.sol
```

The script:

1. Deploys the `FeeManager` implementation via `Create3Factory.deploy()` with immutables `feeTaker` (`FEE_TAKER_ADDRESS`) and `usdcBlacklist` (`USDC_ADDRESS`).
2. Deploys an `ERC1967Proxy` via `Create3Factory.deployAndMultiCall()`, which atomically:
   - Initializes the proxy.
   - Pre-registers the predicted `TokenMessengerWithFees` proxy as an allowed caller.
   - Optionally registers `FEE_MANAGER_TRUSTED_SIGNER` as a trusted quote signer.
   - Optionally grants `FEE_MANAGER_PAUSER` the `PAUSER_ROLE` if non-zero.
   - If `FEE_MANAGER_CALLER_ADMIN` / `FEE_MANAGER_SIGNER_ADMIN` are set and non-zero, grants those roles; otherwise skips (minimal privilege — owner assigns later).
   - Initiates ownership transfer to `FEE_MANAGER_OWNER` (defaults to deployer).

The owner must call `acceptOwnership()` on the proxy separately after deployment to complete the two-step transfer.

Use the printed **FeeManager proxy** address for integrations.

**Roles.** The **owner** authorizes upgrades and may **`grantRole`** `CALLER_ADMIN_ROLE` / `SIGNER_ADMIN_ROLE` / `FEE_COLLECTION_ADMIN_ROLE` when those env vars were omitted at deploy. Holders of **`CALLER_ADMIN_ROLE`** and **`SIGNER_ADMIN_ROLE`** manage allowed callers and trusted quote signers respectively. Holders of **`FEE_COLLECTION_ADMIN_ROLE`** can override the address `FeeManager` forwards to `IFeeTaker` on `takeFee*` calls via `setFeeCollectionAddress`; when unset (zero), `FeeManager` falls back to `IFeeTaker.protocolFeeAddress()` (default behavior). These roles are separate from ownership to limit blast radius if any admin key is compromised.

### 4. Deploy TokenMessengerWithFees

Requires `TOKEN_MESSENGER_V2_ADDRESS`. The `FeeManager` proxy address is resolved via `FEE_MANAGER_PROXY_ADDRESS` if set, otherwise predicted deterministically from `FEE_MANAGER_PROXY_SALT`.

```
script/deploy/DeployTokenMessengerWithFees.s.sol
```

The script:

1. Deploys the `TokenMessengerWithFees` implementation via `Create3Factory.deploy()` with `tokenMessenger` and `feeManager` set as immutables.
2. Deploys an `ERC1967Proxy` via `Create3Factory.deployAndMultiCall()`, which atomically initializes and initiates ownership transfer to `TOKEN_MESSENGER_WITH_FEES_OWNER` (defaults to deployer).

The owner must call `acceptOwnership()` on the proxy separately after deployment to complete the two-step transfer.

The proxy is already pre-registered as an allowed caller on `FeeManager` from step 3.

Use the printed **TokenMessengerWithFees proxy** address for integrations.

## Test utility scripts

These scripts share quote construction and EIP-712 signing via `script/test/QuoteScriptUtils.sol`.

### Generate signed quote (console only)

Use `script/test/GenerateSignedTestQuote.s.sol` to print a signed quote for manual/local testing (no on-chain transaction).

The script produces a quote with:
- `FORWARD` and `PRE_FINALITY` items by default (see `QUOTE_TYPES` below to narrow the selection)
- 1-hour validity (`base + 1 hours`; see **Quote time** below)
- `FORWARD` args hash binds `[address(TokenMessengerWithFees), destinationDomain, burnToken, destinationCaller, hookData]` and uses the same default `cctp-forward` hook bytes as `HookDataLib.defaultForwardHookData()` / `TokenMessengerWithFees` when you call `depositForBurnWithFees` with no caller hook data (not empty-string hook — that would not match `TokenMessengerWithFees` and only `PRE_FINALITY` would collect)
- `PRE_FINALITY` args hash binds `[address(TokenMessengerWithFees), destinationDomain, burnToken, amount]` for `BURN_TOKEN_ADDRESS` and burn amount `500_000` (0.5 USDC, 6 decimals) — same pairing as `DepositForBurnWithGeneratedQuote`
- zero destination caller (`bytes32(0)`)
- native fee token (`address(0)`)
- `FORWARD` amount `0.00001` ether (`10_000_000_000_000` wei)
- `PRE_FINALITY` amount `0.000005` ether (`5_000_000_000_000` wei)

Required env vars:
- `QUOTE_SIGNER` — private key used to sign the quote
- `FEE_MANAGER_PROXY_ADDRESS` — EIP-712 verifying contract (`FeeManager` proxy)
- `TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS` — wrapper address bound into both the `FORWARD` and `PRE_FINALITY` args hashes; must match the `TokenMessengerWithFees` instance that will redeem the quote
- `BURN_TOKEN_ADDRESS` — burn token address bound into both the `FORWARD` and `PRE_FINALITY` args hashes (must match the token you burn if you reuse the quote with `depositForBurnWithFees`)

Optional env vars:
- `DESTINATION_DOMAIN` — destination domain bound into both the `FORWARD` and `PRE_FINALITY` args hashes (default: `0`)
- `QUOTE_BASE_TIMESTAMP` — Unix seconds used as “now” for expiry (default: `block.timestamp`)
- `QUOTE_TYPES` — comma-separated subset of `{FORWARD, PRE_FINALITY}` selecting which line items the quote contains (default: `FORWARD,PRE_FINALITY`). Order is irrelevant; the bash scripts tolerate surrounding whitespace but the Solidity scripts do not (use `FORWARD,PRE_FINALITY` without spaces). Unknown entries, duplicate entries (`FORWARD,FORWARD`), empty tokens (`FORWARD,`), and an empty selection all revert on both the bash and Solidity sides.

**Quote time.** Solidity cannot read your machine clock. To get a realistic expiry without setting `QUOTE_BASE_TIMESTAMP` manually:
- Run with `--rpc-url $BLOCKCHAIN_RPC_URL` so `block.timestamp` is the chain’s latest block time.
- Or pass shell time: `QUOTE_BASE_TIMESTAMP=$(date +%s) forge script ...` (same pattern works for the deposit script below).

Example:

```bash
set -o allexport && source configs/.env.dev && set +o allexport
export QUOTE_SIGNER=<private_key_uint>
export FEE_MANAGER_PROXY_ADDRESS=<fee_manager_proxy_address>
export TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS=<tmwf_proxy>
export BURN_TOKEN_ADDRESS=<usdc_or_test_token>
# optional: DESTINATION_DOMAIN=0  # default
# optional: QUOTE_BASE_TIMESTAMP=$(date +%s)

forge script script/test/GenerateSignedTestQuote.s.sol:GenerateSignedTestQuote \
  --rpc-url $BLOCKCHAIN_RPC_URL
```

The script prints `digest`, `signature`, and the final version-prefixed `signedQuote` bytes to the console.

### Deposit for burn with generated quote

Use `script/test/DepositForBurnWithGeneratedQuote.s.sol` to build the same style of signed quote and call `TokenMessengerWithFees.depositForBurnWithFees`. It approves `0.5` USDC (6 decimals) for the burn, attaches native value matching the items present in the quote (`0.00001` ether for FORWARD + `0.000005` ether for PRE\_FINALITY; `0.000015` ether total when both are included), and broadcasts the transaction.

Required env vars:
- `CALLER_PRIVATE_KEY` — EOA that submits the burn (must hold USDC and native fee value)
- `QUOTE_SIGNER` — private key that signs the quote (must be a trusted signer on `FeeManager`)
- `TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS` — `TokenMessengerWithFees` proxy
- `BURN_TOKEN_ADDRESS` — burn token (e.g. USDC on the source chain)

Optional env vars:
- `DESTINATION_DOMAIN` — CCTP destination domain (default: `0`, Ethereum)
- `MINT_RECIPIENT` — `bytes32` mint recipient on the destination (default: caller address, left-padded)
- `QUOTE_BASE_TIMESTAMP` — same as above (default: `block.timestamp`)
- `QUOTE_TYPES` — same parsing as `GenerateSignedTestQuote` (default: `FORWARD,PRE_FINALITY`; duplicates and empty tokens revert). Drives both the items in the generated quote and the attached `msg.value`; with only `FORWARD` the wrapper picks the slow finality threshold and auto-injects the default forward hook, with only `PRE_FINALITY` the wrapper picks the fast finality threshold and skips the hook.

Example:

```bash
set -o allexport && source configs/.env.dev && set +o allexport
export CALLER_PRIVATE_KEY=<private_key_uint>
export QUOTE_SIGNER=<private_key_uint>
export TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS=<tmwf_proxy>
export BURN_TOKEN_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
# optional: DESTINATION_DOMAIN=0
# optional: MINT_RECIPIENT=<0x-padded-32-byte-hex>
# optional: QUOTE_BASE_TIMESTAMP=$(date +%s)
# optional: QUOTE_TYPES=FORWARD              # only FORWARD; msg.value = 0.00001 ether
# optional: QUOTE_TYPES=PRE_FINALITY         # only PRE_FINALITY; msg.value = 0.000005 ether

forge script script/test/DepositForBurnWithGeneratedQuote.s.sol:DepositForBurnWithGeneratedQuote \
  --rpc-url $BLOCKCHAIN_RPC_URL \
  --broadcast
```

Omit `--broadcast` to simulate only (no transaction sent).

### Deposit for burn with an externally-signed quote

Use `script/test/DepositForBurnWithSignedQuote.s.sol` when you already have a version-prefixed signed quote (for example produced by a backend signer service) and just want to relay it on-chain. The script does **not** sign anything — it derives `msg.value` from the wrapper's `getFee(bytes)` view and rejects ERC-20-fee quotes (an ERC-20 path would also need an `approve` step that this script deliberately leaves out of scope).

Required env vars:
- `CALLER_PRIVATE_KEY` — EOA that submits the burn (must hold the burn token and the native fee)
- `TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS` — `TokenMessengerWithFees` proxy that the quote was signed against
- `BURN_TOKEN_ADDRESS` — burn token bound into the quote args
- `SIGNED_QUOTE` — `0x`-prefixed version-prefixed signed quote bytes

Optional env vars:
- `BURN_AMOUNT` — token units to burn (default: `500000`). Must match the `amount` bound into any `PRE_FINALITY` quote args.
- `DESTINATION_DOMAIN` — CCTP destination domain (default: `0`)
- `MINT_RECIPIENT` — `bytes32` mint recipient on the destination (default: caller, left-padded)
- `DESTINATION_CALLER` — `bytes32` authorized destination caller (default: `bytes32(0)`)
- `REFUND_ADDRESS` — refund attribution address (default: caller). Forwarded to `FeeManager` verbatim — `address(0)` bypasses the USDC blocklist screen on the refund target.
- `HOOK_DATA` — `0x`-prefixed hook bytes. Empty (default) routes through `depositForBurnWithFees`, so the wrapper auto-injects `HookDataLib.defaultForwardHookData()` when the quote contains a `FORWARD` item. Non-empty routes through `depositForBurnWithHookAndFees`; the bytes must match whatever the `FORWARD` args hash was bound to off-chain.

Example:

```bash
set -o allexport && source configs/.env.dev && set +o allexport
export CALLER_PRIVATE_KEY=<private_key_uint>
export TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS=<tmwf_proxy>
export BURN_TOKEN_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
export SIGNED_QUOTE=0x01...        # version-prefixed, signed by a trusted FeeManager signer
# optional: BURN_AMOUNT=500000
# optional: DESTINATION_DOMAIN=1
# optional: HOOK_DATA=0x...        # non-default hook the FORWARD args were bound to

forge script script/test/DepositForBurnWithSignedQuote.s.sol:DepositForBurnWithSignedQuote \
  --rpc-url $BLOCKCHAIN_RPC_URL \
  --broadcast
```

#### Chains with native precompiles (Arc Testnet)

Arc Testnet (chain id `5042002`) implements USDC balance transfers and blocklist checks via native precompiles (`0x1800…00`, `0x1800…01`). These precompiles execute at the node/protocol level and have no standard EVM bytecode. Forge's local EVM (`revm`) fetches the empty code at those addresses and fails with `StackUnderflow` when it tries to simulate the transaction before broadcasting.

**`forge script --broadcast` does not work on this chain** for any script that touches USDC (approve, transfer, `depositForBurnWithFees`). Two `cast send` wrappers are provided as drop-in replacements — both submit the approve + deposit transactions directly to the RPC node, bypassing local EVM simulation.

##### Generated quote (`cast-deposit-for-burn.sh`)

Generates a signed quote via the view-only `GenerateSignedTestQuote` Forge script (which does not hit precompiles) and then relays it:

```bash
set -o allexport && source configs/.env.dev && set +o allexport
export CALLER_PRIVATE_KEY=0x<hex_private_key>
export QUOTE_SIGNER=<uint256_private_key>
export BURN_TOKEN_ADDRESS=$USDC_ADDRESS

bash script/test/cast-deposit-for-burn.sh
```

The script hardcodes `BURN_AMOUNT=500000` (0.5 USDC) and computes `NATIVE_FEE` from `QUOTE_TYPES` using the same per-item amounts as `GenerateSignedTestQuote.s.sol` (FORWARD `0.00001` ether + PRE\_FINALITY `0.000005` ether). To change individual fee amounts, update both the Solidity constants and the `FORWARD_FEE_WEI` / `PRE_FINALITY_FEE_WEI` constants in the bash script.

Optional env overrides:
- `QUOTE_TYPES` — comma-separated subset of `{FORWARD, PRE_FINALITY}` selecting the items in the generated quote and the fees rolled into `NATIVE_FEE` (default: `FORWARD,PRE_FINALITY`). The value is forwarded to the Forge subprocess so the bash and Solidity sides cannot drift. Both sides reject duplicates (`FORWARD,FORWARD`) and empty tokens (`FORWARD,`) so the per-item `NATIVE_FEE` accumulator stays in sync with the Solidity item builder, which collapses duplicates to a single `QuoteItem`.
- `DESTINATION_DOMAIN` — default `0`
- `MINT_RECIPIENT` — default: caller address, left-padded to `bytes32`
- `REFUND_ADDRESS` — default: `address(0)` (no refund target; bypasses the USDC blocklist screen)

##### Pre-signed quote (`cast-deposit-for-burn-with-quote.sh`)

Companion script for when the quote is signed elsewhere (e.g. backend signer) and you just want to relay it. Resolves the native fee value automatically by calling the wrapper's `getFee(bytes)` view through `cast call`:

```bash
set -o allexport && source configs/.env.dev && set +o allexport
export CALLER_PRIVATE_KEY=0x<hex_private_key>
export BURN_TOKEN_ADDRESS=$USDC_ADDRESS
export SIGNED_QUOTE=0x01...                    # version-prefixed, signed by a trusted FeeManager signer

bash script/test/cast-deposit-for-burn-with-quote.sh
```

The script rejects quotes whose `feeToken` is not `address(0)` (an ERC-20 path would need an additional `approve` step that the script intentionally does not perform).

Optional env overrides:
- `BURN_AMOUNT` — default `500000`; must match the amount bound into any `PRE_FINALITY` quote args
- `DESTINATION_DOMAIN` — default `0`
- `MINT_RECIPIENT` — default: caller address, left-padded to `bytes32`
- `DESTINATION_CALLER` — default `bytes32(0)`
- `REFUND_ADDRESS` — default: `address(0)`
- `HOOK_DATA` — `0x`-prefixed hook bytes; non-empty switches the relay to `depositForBurnWithHookAndFees` and must match whatever the `FORWARD` args hash was bound to off-chain
- `NATIVE_FEE` — explicit `msg.value` (wei); defaults to the `getFee(bytes)` result. `getFee` is always queried regardless (so the script can enforce the native-fee invariant) and a mismatch against the quoted value is logged — the override only changes the value attached to the deposit call (handy for deliberately triggering `IncorrectNativePayment` in smoke tests)

## Upgrading

Both `FeeManager` and `TokenMessengerWithFees` use the UUPS (ERC-1822) proxy pattern. The proxy address and all on-chain state are preserved across upgrades — only the implementation logic changes. Only the current `owner()` can call `upgradeToAndCall`. Ownership uses `Ownable2StepUpgradeable`, so transferring the owner requires the new owner to explicitly accept.

Use **`script/deploy/UpgradeFeeManager.s.sol`** and **`script/deploy/UpgradeTokenMessengerWithFees.s.sol`** so you do not hand-assemble init code or `cast send` the factory. The broadcaster must own both the `Create3Factory` and the proxy (same pattern as initial deploy).

### Upgrade procedure

1. **Run `forge clean && forge build` and `yarn validate:upgrades`** (storage / UUPS checks).

2. **Bump the implementation salt only** — each new implementation needs a fresh impl salt so CREATE3 does not reuse the slot of the previous implementation. **Do not change proxy salts** when upgrading.

```bash
# FeeManager upgrade:
export FEE_MANAGER_IMPLEMENTATION_SALT="fee-manager-impl-v2"
# FEE_MANAGER_PROXY_SALT unchanged from initial deploy

# TokenMessengerWithFees upgrade:
export TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT="tmwf-impl-v2"
# TOKEN_MESSENGER_WITH_FEES_PROXY_SALT unchanged from initial deploy
```

3. **Deploy the new implementation and upgrade the proxy** (default `run()` — deploy then `upgradeToAndCall` in one broadcast):

**FeeManager**

```bash
set -o allexport && source configs/.env.dev && set +o allexport
forge script script/deploy/UpgradeFeeManager.s.sol:UpgradeFeeManager \
  --rpc-url $BLOCKCHAIN_RPC_URL \
  --broadcast
```

**TokenMessengerWithFees**

```bash
set -o allexport && source configs/.env.dev && set +o allexport
forge script script/deploy/UpgradeTokenMessengerWithFees.s.sol:UpgradeTokenMessengerWithFees \
  --rpc-url $BLOCKCHAIN_RPC_URL \
  --broadcast
```

**Split flows** (optional):

| Goal | Script | Entry point |
|------|--------|-------------|
| Deploy implementation only | `UpgradeFeeManager` / `UpgradeTokenMessengerWithFees` | `--sig deployImplementationOnly` |
| Point proxy at an impl you already deployed | same | `--sig upgradeProxyOnly` — set `FEE_MANAGER_IMPLEMENTATION_ADDRESS` or `TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_ADDRESS` |

Replace the default `run()` body with a `reinitializer` call only if a future version requires it (today `upgradeToAndCall` uses empty `data`).

4. **Verify** the new implementation on the block explorer. Use the **implementation** address from the deploy script logs, or read it from the proxy (EIP-1967 implementation slot). Run only the assignment for the contract you are verifying:

```bash
FEE_MANAGER_IMPLEMENTATION=$(cast parse-bytes32-address $(cast storage $FEE_MANAGER_PROXY_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $BLOCKCHAIN_RPC_URL))

TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION=$(cast parse-bytes32-address $(cast storage $TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $BLOCKCHAIN_RPC_URL))
```

**FeeManager** — immutables: `feeTaker`, `usdcBlacklist` (same as deploy).

```bash
forge verify-contract $FEE_MANAGER_IMPLEMENTATION FeeManager \
  --constructor-args $(cast abi-encode "constructor(address,address)" $FEE_TAKER_ADDRESS $USDC_ADDRESS) \
  --chain-id $(cast chain-id --rpc-url $BLOCKCHAIN_RPC_URL) \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

**TokenMessengerWithFees** — immutables: `tokenMessenger` (`TOKEN_MESSENGER_V2_ADDRESS`), `feeManager` (the **FeeManager proxy**, same as `FEE_MANAGER_PROXY_ADDRESS`).

```bash
forge verify-contract $TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION TokenMessengerWithFees \
  --constructor-args $(cast abi-encode "constructor(address,address)" $TOKEN_MESSENGER_V2_ADDRESS $FEE_MANAGER_PROXY_ADDRESS) \
  --chain-id $(cast chain-id --rpc-url $BLOCKCHAIN_RPC_URL) \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Manual alternative (cast / `forge inspect`)

To **preview** addresses without broadcasting, use `script/deploy/PrintAddresses.s.sol` with `--rpc-url` (or `--sig feeManagerProxyAddress`, etc.).

To **deploy without the Forge scripts**, build init code as **creation bytecode + ABI-encoded constructor args** and call `Create3Factory.deploy` (see NatSpec on `UpgradeFeeManager` / `DeployFeeManager` for the exact encoding).

### Post-upgrade verification

EIP-1967 implementation slot (same for both proxies):

```bash
# FeeManager
cast storage $FEE_MANAGER_PROXY_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $BLOCKCHAIN_RPC_URL

# TokenMessengerWithFees (after upgrading that proxy)
cast storage $TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $BLOCKCHAIN_RPC_URL

cast call $FEE_MANAGER_PROXY_ADDRESS "owner()(address)" --rpc-url $BLOCKCHAIN_RPC_URL
cast call $TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS "owner()(address)" --rpc-url $BLOCKCHAIN_RPC_URL
```

### Storage layout compatibility

All contracts use **EIP-7201 namespaced storage**. When adding state in new versions:
- **Append** new fields to the relevant namespaced struct.
- **Never** reorder, remove, or change the type of existing fields.

Validate upgrade safety before deploying:

```bash
forge clean && forge build
yarn validate:upgrades
```

This checks UUPS conventions and storage layout compatibility. To compare against a specific previous version, use the `@custom:oz-upgrades-from` NatSpec annotation and the `--referenceBuildInfoDirs` flag (see [OpenZeppelin docs](https://docs.openzeppelin.com/upgrades-plugins/1.x/api-core)).

### Rollback

The owner can upgrade back to the previous implementation address via `upgradeToAndCall(previousImplAddress, "")`. Previous implementations remain deployed on-chain indefinitely.

### Emergency pause

`FeeManager` exposes `pause()` and `unpause()`, callable only by addresses with `PAUSER_ROLE`. While paused, `collectFeesWithQuote` reverts (`whenNotPaused`). Grant `PAUSER_ROLE` during deploy via `FEE_MANAGER_PAUSER`, or later via `grantRole` from the owner.

## Static Analysis

To run Slither locally:

```bash
slither .
```
