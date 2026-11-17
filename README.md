# Morpheus Distributor yield-share verification

Foundry fork proof of concept for a Morpheus (mor.org) bug bounty submission.
It shows that a direct aToken transfer to the Distributor is counted as pool
yield by `DistributorV2.distributeRewards()`, inflating that pool's share of
the MOR tranche. All testing was done on a local Ethereum mainnet fork. No
live transaction was ever sent.

## Summary

`distributeRewards()` is public. For each AAVE-strategy pool it measures yield
as the Distributor's current aToken balance minus `lastUnderlyingBalance`,
multiplied by the Chainlink price, with no check on where the aTokens came
from. The period's MOR tranche is then split between pools in proportion to
their measured USD yield. Anyone can transfer aTokens directly to the
Distributor, have the transfer counted as that pool's yield, and claim the
inflated share of the tranche after the 14-day claim lock. The transfer
itself is a sunk cost: it is swept to L1Sender as protocol yield on the next
withdrawal, but the inflated MOR share exceeds it.

## Measured results (fork, block 26433548, 17 Nov 2026)

The tester stakes 1 wBTC in the wBTC DepositPool, then (scenario B only)
supplies wBTC to Aave V3, receives aWBTC, and transfers it directly to the
Distributor before calling `distributeRewards(0)`.

| Measure | A: baseline (no transfer) | B: with direct transfer |
|---|---|---|
| wBTC pool share, first distribution | 0.0013% | 45.89% (2,415.95 MOR of a 5,264.30 MOR tranche) |
| Claimable MOR for the tester | 2.741 MOR ($1.92) | 1,329.01 MOR ($930.31) |
| Direct transfer value | | $416.55 (647,999 aWBTC) |
| wBTC swept to L1Sender on withdraw | 141 satoshi | 648,142 satoshi |
| Net for one measured cycle | | +$511.84 |

Net: (1,329.01 - 2.741) MOR x $0.70 - $416.55 = +$511.84. Steady-state
projection from the measured parameters (daily tranche ~2,856 MOR, real daily
yield ~$522-578): an optimal daily transfer of ~$218-235 yields a net of
~+$82-106/day, diverting ~$580/day of MOR rewards from honest stakers in
the other four pools. The projection is arithmetic from measured parameters,
not a separate test.

## How to run

```bash
forge install foundry-rs/forge-std
forge test -vvv
```

`foundry.toml` pins the fork: public RPC `https://eth-mainnet.public.blastapi.io`
(no API key needed), block `26433548`, `evm_version = "cancun"`. The Cancun
setting matters: the default EVM version makes state-changing calls to the
Aave Pool fail (`NotActivated`, the Pool implementation uses TSTORE/TLOAD/
MCOPY). The Chainlink feeds are pinned with a `MockPriceFeed` etched at the
six live feed addresses, returning the fork-block prices with a fresh
timestamp, because warping makes the feeds stale. The `claim()` call sends a
LayerZero message via L1Sender; on the fork it succeeds with 0.05 ETH value
and claimable MOR goes to 0 (the Arbitrum mint itself cannot be observed
from an Ethereum fork).

Last run: 6/6 tests pass (see `run-20261117.log`).

## Files

- `foundry.toml` - fork RPC, pinned block, `evm_version = "cancun"`.
- `test/YieldShareVerification.t.sol` - main test (baseline, direct
  transfer, yield breakdown) plus `MockPriceFeed`.
- `test/AaveIsolation.t.sol` - diagnosis of the EVM/Aave fork issue
  (3 tests).
- `run-20261117.log` - full log of the last run (6/6 pass).

## Target

- Distributor: `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`
- DepositPool (wBTC): `0xdE283F8309Fd1AA46c95d299f6B8310716277A42`
- RewardPool: `0xb7994dE339AEe515C9b2792831CD83f3C9D8df87`
- Source reviewed: MorpheusAIs/SmartContracts @
  `07f6032fde968ba95948e53681762105d6440b27`, `DistributorV2.sol`
  (`distributeRewards`, around lines 355-447).
