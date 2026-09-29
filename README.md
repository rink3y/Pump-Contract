# Pump-Contract

## Breaking changes for integrators (UI/scripts)

The latest version of `BondingCurveManager` (`Op-Manager.sol`) changes how the contract is called. Any UI or script built against the previous version, including [Pump-ui](https://github.com/rink3y/Pump-ui), must be updated before it is pointed at a new deployment:

- `buy(token, minTokensOut)`: reverts with `SlippageExceeded` if fewer tokens would be received.
- `sell(token, amount, minEthOut)`: reverts with `SlippageExceeded` if less ETH would be received.
- `tokens(address)` now returns `(token, deployer, tokenbalance, ethBalance, isListed)`: `deployer` was inserted as the second field, so update any code that reads it by position.
- Tokens can't be transferred until they migrate, except to/from the manager.
- The manager rejects plain ETH transfers.
- `setBancorFormula` was removed.

Tokens already deployed on the previous version keep working with the old calls; only a new deployment of the manager uses the calls above.
