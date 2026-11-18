## Original 53 checks → current names

All original checks remain; exact-target companion checks strengthen negative ownership checks.

| Original # | Original check | Current name |
|---|---|---|
| 1 | `owner(superPaymaster) != deployer` | `owner(superPaymaster) != deployer` |
| 2 | `owner(registry) != deployer` | `owner(registry) != deployer` |
| 3 | `owner(staking) != deployer` | `owner(staking) != deployer` |
| 4 | `owner(gToken) != deployer` | `owner(gToken) != deployer` |
| 5 | `owner(xPNTsFactoryV2) != deployer` | `owner(xPNTsFactoryV2) != deployer` |
| 6 | `owner(aoaProtocolRegistry) != deployer` | `owner(aoaProtocolRegistry) != deployer` |
| 7 | `owner(reputationSystem) != deployer` | `owner(reputationSystem) != deployer` |
| 8 | `owner(blsAggregator) != deployer` | `owner(blsAggregator) != deployer` |
| 9 | `owner(dvtValidator) != deployer` | `owner(dvtValidator) != deployer` |
| 10 | `roleConfigs[COMMUNITY].owner != deployer` | `roleConfigs[COMMUNITY].owner != deployer` |
| 11 | `roleConfigs[ENDUSER].owner != deployer` | `roleConfigs[ENDUSER].owner != deployer` |
| 12 | `roleConfigs[PAYMASTER_AOA].owner != deployer` | `roleConfigs[PAYMASTER_AOA].owner != deployer` |
| 13 | `roleConfigs[PAYMASTER_SUPER].owner != deployer` | `roleConfigs[PAYMASTER_SUPER].owner != deployer` |
| 14 | `roleConfigs[DVT].owner != deployer` | `roleConfigs[DVT].owner != deployer` |
| 15 | `roleConfigs[ANODE].owner != deployer` | `roleConfigs[ANODE].owner != deployer` |
| 16 | `roleConfigs[KMS].owner != deployer` | `roleConfigs[KMS].owner != deployer` |
| 17 | `isReputationSource(repSystem)` | `isReputationSource(repSystem)` |
| 18 | `isReputationSource(aggregator)` | `isReputationSource(aggregator)` |
| 19 | `isReputationSource(deployer) == false` | `isReputationSource(deployer) == false` |
| 20 | `SP.treasury != deployer` | `SP.treasury != deployer` |
| 21 | `staking.treasury != deployer` | `staking.treasury != deployer` |
| 22 | `MySBT.daoMultisig != deployer` | `MySBT.daoMultisig != deployer` |
| 23 | `aggregator.slashPolicyAdmin != deployer` | `aggregator.slashPolicyAdmin != deployer` |
| 24 | `SP.guardian != deployer` | `SP.guardian != deployer` |
| 25 | `PolicyRegistry.guardian != deployer` | `PolicyRegistry.guardian != deployer` |
| 26 | `DVT.isValidator(deployer) == false` | `DVT.isValidator(deployer) == false` |
| 27 | `TL.PROPOSER_ROLE(deployer) == false` | `TL.PROPOSER_ROLE(deployer) == false` |
| 28 | `TL.EXECUTOR_ROLE(deployer) == false` | `TL.EXECUTOR_ROLE(deployer) == false` |
| 29 | `TL.CANCELLER_ROLE(deployer) == false` | `TL.CANCELLER_ROLE(deployer) == false` |
| 30 | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` |
| 31 | `authorizedSlashers(aggregator) == false` | `authorizedSlashers(aggregator) == false` |
| 32 | `fraudProofVerifier == 0` | `fraudProofVerifier == 0` |
| 33 | `owner(superPaymaster) != aggregator` | `owner(superPaymaster) != aggregator` |
| 34 | `owner(registry) != aggregator` | `owner(registry) != aggregator` |
| 35 | `owner(staking) != aggregator` | `owner(staking) != aggregator` |
| 36 | `owner(gToken) != aggregator` | `owner(gToken) != aggregator` |
| 37 | `owner(xPNTsFactoryV2) != aggregator` | `owner(xPNTsFactoryV2) != aggregator` |
| 38 | `owner(aoaProtocolRegistry) != aggregator` | `owner(aoaProtocolRegistry) != aggregator` |
| 39 | `owner(reputationSystem) != aggregator` | `owner(reputationSystem) != aggregator` |
| 40 | `owner(blsAggregator) != aggregator` | `owner(blsAggregator) != aggregator` |
| 41 | `owner(dvtValidator) != aggregator` | `owner(dvtValidator) != aggregator` |
| 42 | `owner(xPNTsFactory) != aggregator` | `owner(xPNTsFactory) != aggregator` |
| 43 | `owner(paymasterFactory) != aggregator` | `owner(paymasterFactory) != aggregator` |
| 44 | `owner(paymasterV4Impl) != aggregator` | `owner(paymasterV4Impl) != aggregator` |
| 45 | `owner(microPaymentChannel) != aggregator` | `owner(microPaymentChannel) != aggregator` |
| 46 | `owner(x402Facilitator) != aggregator` | `owner(x402Facilitator) != aggregator` |
| 47 | `aggregator ETH balance == 0` | `aggregator ETH balance == 0` |
| 48 | `aggregator gToken balance == 0` | `aggregator gToken balance == 0` |
| 49 | `aggregator aPNTs balance == 0` | `aggregator aPNTs balance == 0` |
| 50 | `aggregator pnts balance == 0` | `config legacy pnts == zero` |
| 51 | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` |
| 52 | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` |
| 53 | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` |
