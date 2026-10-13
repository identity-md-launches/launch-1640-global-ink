# GLOBAL INK (PAVE)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Field | Value |
| --- | --- |
| Solidity contract | `PaveToken` (`src/PaveToken.sol`) |
| `name()` | `GLOBAL INK` |
| `symbol()` | `PAVE` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 PAVE = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Owner / admin | none |

## Behaviour

- **One mint, in the constructor.** The whole supply is minted to `msg.sender` when the contract is
  created. At launch `msg.sender` is the IMD ProjectFactory, which then pays the supply out. There is
  no `mint`, no minter role and no owner: `totalSupply` can never exceed `INITIAL_SUPPLY`.
- **Plain transfers.** `transfer`, `approve`, `transferFrom`, `increaseAllowance` and
  `decreaseAllowance` behave as in the ERC-20 standard. There is no fee, tax, reflection, cooldown,
  max-wallet or max-transaction rule: every transfer delivers exactly the amount requested, to the
  factory, the MerkleDistributor, the Uniswap v4 PoolManager and ordinary holders alike. No address
  is exempted because nothing needs exempting.
- **No privileged powers.** There is no pause, blacklist, freeze, lock, seize, `burnFrom` or
  upgrade path. The runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`
  (asserted by a test).
- **Holder-only burn.** `burn(uint256)` destroys the caller's own tokens and lowers `totalSupply`.
  Nobody can burn another account's balance, so the supply can only shrink, never grow.
- **Allowance semantics.** `approve` sets an absolute allowance (the usual front-running caveat of
  ERC-20 applies; use `increaseAllowance` / `decreaseAllowance` to adjust). An allowance of
  `type(uint256).max` is unlimited and is not decremented by `transferFrom`.
- **Reverts** use custom errors: `ZeroAddress`, `InsufficientBalance`, `InsufficientAllowance`,
  `AllowanceBelowZero`. Transfers to and approvals of the zero address revert.

## Assumptions

- The requester asked for a plain token: name, symbol, supply and decimals only. No tax, vesting,
  governance or reflection mechanics were requested, so none are implemented.
- The deployer is whoever creates the contract. For the launch that is the ProjectFactory; the
  requester's share reaches them through the launch economics (`remainderTo`), not through the
  constructor. No value in this contract depends on the requester, so nothing is left unset.
- The token does not depend on any other contract or external address and makes no external calls.

## Deployment parameters

The contract takes **no constructor arguments**. The launch manifest step records:

- `token.contract`: `PaveToken`
- `token.name`: `GLOBAL INK`
- `token.symbol`: `PAVE`
- `token.decimals`: `18`
- `token.totalSupply`: `1000000000000000000000000000`
- `token.constructorArgs`: `[]`

Launch terms decided by the launch, not by this repository: chain Ethereum (1), paired currency IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), pool fee 12500 (1.25%), tick spacing 60, economics
`poolBps` 8800, `initialMarketCapWei` 2500 IMD, `remainderTo` `0x12a7aad083cef06fef7c295514b52fc8bc81960d`.
10% of the supply goes to the swarm's MerkleDistributor by construction; 88% seeds the pool; the
remaining 2% is forwarded to `remainderTo`. The deployer derives the opening price; this repository
does not.

Named constants chosen here: none were left open by the brief besides the supply, which is fixed at
`INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` as requested.

## Operational responsibilities

- **After launch there is nothing to configure.** The token has no owner-settable values and no
  "after launch" setters.
- **Nobody can intervene.** Because there is no admin, no one (the requester included) can pause
  trading, recover tokens sent to the wrong address, or change the supply. Holders are responsible for
  their own keys and for what they burn.
- **Verification** of the source on an explorer is the launch deployer's step; the bytecode is built
  with `bytecode_hash = "none"` and `cbor_metadata = false` so it is reproducible from this tree.
- The tests here are not an audit. The contract is small and self-contained, but an independent
  review before relying on it for anything beyond the launch flows is still good practice.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, enables the optimizer (200 runs), sets `bytecode_hash = "none"`
and disables `ffi` and filesystem permissions. `forge-std` v1.11.0 is vendored as plain files under
`lib/forge-std` (no submodule), mapped by `remappings.txt`.

Tests live in `test/PaveToken.t.sol`: metadata and supply, constructor mint to an EOA and to a
contract deployer, transfer/approve/transferFrom success and failure paths, allowance edge cases,
burn, fuzzed conservation of supply, and a bytecode scan for forbidden opcodes. They read no
environment variables and run in any order.
