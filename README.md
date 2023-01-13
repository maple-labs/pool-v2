# Pool V2

[![Foundry][foundry-badge]][foundry]
![Foundry CI](https://github.com/maple-labs/poolV2/actions/workflows/forge.yaml/badge.svg)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

This repository contains the core contracts of the Maple V2 protocol that are responsible for the deployment and management of Maple Pools:

| Contract | Description |
| -------- | ------- |
| [`Pool`](https://github.com/maple-labs/maple-core-v2/wiki/Pools) | Each pool represents a different lending pool with a unique strategy and pool delegate that issues loans on behalf of the liquidity providers. The `Pool` contract is compatible with the [ERC-4626 Tokenized Vault standard](https://eips.ethereum.org/EIPS/eip-4626). |
| [`PoolManager`](https://github.com/maple-labs/maple-core-v2/wiki/PoolManager) | Used by the pool delegate to manage pool level parameters and to issue loans to borrowers. |
| [`LoanManager`](https://github.com/maple-labs/maple-core-v2/wiki/LoanManager) | Owns and keeps track of value of all outstanding loans. |
| [`PoolDelegateCover`](https://github.com/maple-labs/maple-core-v2/wiki/Pool-Delegate-Cover) | Holds first-loss capital in escrow on behalf of the pool delegate. |
| [`PoolDeployer`](https://github.com/maple-labs/maple-core-v2/wiki/Pool-Creation) | Used to deploy new pools with all the required dependencies. |

## Dependencies/Inheritance

Contracts in this repo inherit and import code from:
- [`maple-labs/erc20`](https://github.com/maple-labs/erc20)
- [`maple-labs/erc20-helper`](https://github.com/maple-labs/erc20-helper)
- [`maple-labs/maple-proxy-factory`](https://github.com/maple-labs/maple-proxy-factory)

Contracts inherit and import code in the following ways:
- `Pool` inherits `ERC20` for fungible token functionality.
- `PoolDelegateCover`, `PoolDeployer` and `PoolManager` use `ERC20Helper` for token interactions.
- `LoanManager`, `PoolManager`, and `TransitionLoanManager` inherit `MapleProxiedInternals` for proxy logic.
- `LoanManagerFactory` and `PoolManagerFactory` inherit `MapleProxyFactory` for proxy deployment and management.

Versions of dependencies can be checked with `git submodule status`.

## Setup

This project was built using [Foundry](https://book.getfoundry.sh/). Refer to installation instructions [here](https://github.com/foundry-rs/foundry#installation).

```sh
git clone git@github.com:maple-labs/pool-v2.git
cd pool-v2
forge install
```

## Running Tests

- To run all tests: `forge test`
- To run specific tests: `forge test --match <test_name>`

`./scripts/test.sh` is used to enable Foundry profile usage with the `-p` flag. Profiles are used to specify the number of fuzz runs.

## Audit Reports

| Auditor | Report Link |
|---|---|
| Trail of Bits | [`2022-08-24 - Trail of Bits Report`](https://docs.google.com/viewer?url=https://github.com/maple-labs/maple-v2-audits/files/10246688/Maple.Finance.v2.-.Final.Report.-.Fixed.-.2022.pdf) |
| Spearbit | [`2022-10-17 - Spearbit Report`](https://docs.google.com/viewer?url=https://github.com/maple-labs/maple-v2-audits/files/10223545/Maple.Finance.v2.-.Spearbit.pdf) |
| Three Sigma | [`2022-10-24 - Three Sigma Report`](https://docs.google.com/viewer?url=https://github.com/maple-labs/maple-v2-audits/files/10223541/three-sigma_maple-finance_code-audit_v1.1.1.pdf) |

## Bug Bounty

For all information related to the ongoing bug bounty for these contracts run by [Immunefi](https://immunefi.com/), please visit this [site](https://immunefi.com/bounty/maple/).

## About Maple

[Maple Finance](https://maple.finance/) is a decentralized corporate credit market. Maple provides capital to institutional borrowers through globally accessible fixed-income yield opportunities.

For all technical documentation related to the Maple V2 protocol, please refer to the Maple [Gitbook](https://maplefinance.gitbook.io/maple/maple-for-developers/protocol-overview).

---

<p align="center">
  <img src="https://user-images.githubusercontent.com/44272939/196706799-fe96d294-f700-41e7-a65f-2d754d0a6eac.gif" height="100" />
</p>
