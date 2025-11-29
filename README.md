# cLend EIP-7702 Liquidator

This is a weekend project implementing a position exiter that utilizes the benefits of EIP 7702 (turning an EOA into a smart contract for a single transaction) to bypass the cLend design pitfalls that prevent external parties from repaying another parties loans (even with consent). This is due to the contract recognizing msg.sender as the user who's loans are being handled during interaction.

By using EIP-7702, a party can utilize MakerDAO's flash mint functionality to flash borrow the amount of money they have in debt, repay their loan, reclaim collateral, and dump their asset for a profit on Uniswap V2's CORE/WETH Pair. 

This only works if a. the primary collateral asset is CORE and b. CORE is more valuable on Uniswap then it is cLend 

This repo is currently in a scratch pad state and most likely none of this stuff works. I was liquidated long before EIP-7702 came out, so this is purely for fun and untested. 

## Setup



```sh
# Install dependencies
forge soldeer install
yarn install
```

## Structure

- **Contracts**: `src/` - Smart wallet implementations and examples

## Usage

```sh
# Run Test
export MAINNET_RPC_URL="https://ethereum-rpc.publicnode.com"
export MAKER_FLASH="0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA"
forge test --fork-url "$MAINNET_RPC_URL" --match-contract ClendingLiquidatorForkTest

```
```sh
# Run Foundry tests
forge test

# Run TypeScript tests
yarn test

# Start local node (Prague hardfork)
yarn anvil
```

## Available Scripts

- `yarn test` - Run TypeScript tests with Vitest
- `yarn test:run` - Run tests once
- `yarn test:ui` - Run tests with UI
- `yarn test:forge` - Run Foundry tests
- `yarn anvil` - Start local node with Prague hardfork