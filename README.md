# Pool V2

![Foundry CI](https://github.com/maple-labs/poolV2/actions/workflows/push-to-main.yaml/badge.svg) [![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

## Overview

This repository contains the core contracts of the Maple V2 protocol that are responsible for the deployment and management of lending pools:

| Contract | Description |
| -------- | ------- |
| [`Pool`](https://github.com/maple-labs/maple-core-v2/wiki/Pools) | Each pool represents a different lending pool with a unique strategy and pool delegate that issues loans on behalf of the liquidity providers. The `Pool` contract is compatible with the [ERC-4626 Tokenized Vault standard](https://eips.ethereum.org/EIPS/eip-4626). |
| [`PoolManager`](https://github.com/maple-labs/maple-core-v2/wiki/PoolManager) | Used by the pool delegate to manage pool level parameters and to issue loans to borrowers. |
| [`LoanManager`](https://github.com/maple-labs/maple-core-v2/wiki/LoanManager) | Owns and keeps track of value of all outstanding loans. |
| [`PoolDelegateCover`](https://github.com/maple-labs/maple-core-v2/wiki/Pool-Delegate-Cover) | Holds first-loss capital in escrow on behalf of the pool delegate. |
| [`PoolDeployer`](https://github.com/maple-labs/maple-core-v2/wiki/Pool-Creation) | Used to deploy new pools with all the required dependencies. |

## Setup

This project was built using [Foundry](https://book.getfoundry.sh/). Refer to installation instructions [here](https://github.com/foundry-rs/foundry#installation).

```sh
git clone git@github.com:maple-labs/pool-v2.git
cd pool-v2
forge install
```

## Running Tests

- To run all tests: `./scripts/test.sh`
- To run specific unit tests: `./scripts/test.sh -t <test_name>`

`./scripts/test.sh` is used to enable Foundry profile usage with the `-p` flag. Profiles are used to specify the number of fuzz runs.

## About Maple

[Maple Finance](https://maple.finance/) is a decentralized corporate credit market. Maple provides capital to institutional borrowers through globally accessible fixed-income yield opportunities.

For all technical documentation related to the Maple V2 protocol, please refer to the GitHub [wiki](https://github.com/maple-labs/maple-core-v2/wiki).

---

<p align="center">
  <img src="https://user-images.githubusercontent.com/44272939/116272804-33e78d00-a74f-11eb-97ab-77b7e13dc663.png" height="100" />
</p>
