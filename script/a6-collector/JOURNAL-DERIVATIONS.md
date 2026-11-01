# Journal decision inputs

The archive boundary is `artifactErrors`; `exclusionReason`, `windowErrors`, and
`evidenceIndex` also serve in-memory construction/structural validation and are
not standalone archive acceptance gates. Formal CLI acceptance requires both
archive verification and the independent conservation/matching pass.

Fields below include control metadata: policy, provenance and grouping fields
are constrained by pinned configuration and structural invariants, not claimed
to be facts obtainable from Ethereum receipts. Derived measurements must equal
the archived evidence. Missing nonempty derived values fail. Legacy non-formal
journals may omit empty arrays and UOE log positions; formal receipt positions
and observed events are required when present in raw receipt evidence.

| Journal fields (brace notation expands each member) | Source / constraint | Decision read / binding |
|---|---|---|
| sent; tx.hash | Successful archived eth_sendRawTransaction in attempt range | derived-evidence.mjs:52; validate.mjs:76 |
| verdict; failingCheck | Receipt status, UOE identity/success, revert events; NOT_SENT preflight/error/fee branch | derived-evidence.mjs:30; validate.mjs:76; disposition.mjs:4 |
| logs[].{address,topics,data,logIndex,transactionHash}; tx.status | Complete ordered A/B receipt | artifact-validate.mjs:226; validate.mjs:80 |
| userOpEvent.{userOpHash,sender,paymaster,nonce,success,actualGasCost,actualGasUsed,logIndex} | Decode matching UserOperationEvent | derived-evidence.mjs:46; evidence.mjs:69 |
| observedUserOpEvent.{userOpHash,sender,paymaster,nonce,success,actualGasCost,actualGasUsed,logIndex,txHash} | Decode sender/nonce UOE, receipt transaction identity | derived-evidence.mjs:47; evidence.mjs:69 |
| execRevert[].{userOpHash,sender,nonce,revertReason} | UserOperationRevertReason receipt logs | derived-evidence.mjs:24; evidence.mjs:145 |
| postOpRevert[].{userOpHash,sender,nonce,revertReason} | PostOpRevertReason receipt logs | derived-evidence.mjs:24; evidence.mjs:134 |
| prefundTooLow[].{userOpHash,sender,nonce} | UserOperationPrefundTooLow receipt logs | derived-evidence.mjs:24; evidence.mjs:134 |
| revertKind | Decoded UOE success and revert-event precedence | derived-evidence.mjs:44; evidence.mjs:145 |
| preflight.{infraFailure,sponsorshipFailed,undecoded,revertReason,inner} | Matching archived A eth_call error; exact bundle/from/to, request/response identity, fixed block and attempt id range; FailedOp/FailedOpWithRevert/Panic decoder | evidence.mjs:104; artifact-validate.mjs:162 |
| submissionException.message | Archived eth_sendRawTransaction error.message in attempt range; signed transaction target/input must match handleOps | derived-evidence.mjs:61; evidence.mjs:147 |
| feeBlock.{number,hash}; baseFeePerGas | Archived eth_getBlockByNumber base fee, compared with packed/frozen fee cap | derived-evidence.mjs:70; disposition.mjs:14 |
| traces[].{call,state,postOpRefreshed}; postOpRefreshed; tpmOracle | A/B archived callTracer/prestateTracer, canonical tracer options, oracle from Passport, independent refresh walk | derived-evidence.mjs:77; artifact-validate.mjs:244; evidence.mjs:96 |
| reason; exclusion(.reason); included; stoppedBy.reason | Validated outcome, exclusion vocabulary and failure consistency; stops cannot authorize accepted formal windows | evidence.mjs:133; disposition.mjs:3; evidence-validate.mjs:32 |
| tx.{blockNumber,blockHash,blockTimestamp,blockTxCount,headBefore,from} | A/B inclusion block membership/timestamp/transaction list; archived pre-send head; raw transaction sender | artifact-validate.mjs:170; validate.mjs:606 |
| tx.{input,gasLimit,maxFeePerGas,maxPriorityFeePerGas,raw,handleOpsIndex}; bundledOps[].{sender,nonce,initCode,callData,accountGasLimits,preVerificationGas,gasFees,paymasterAndData,signature} | Raw eth_getTransactionByHash input, decoded handleOps bundle/index/beneficiary, frozen transaction limits | artifact-validate.mjs:44; artifact-validate.mjs:219 |
| packedOp.{sender,nonce,initCode,callData,accountGasLimits,preVerificationGas,gasFees,paymasterAndData,signature} | Selected raw handleOps bundle member | artifact-validate.mjs:49; validate.mjs:64 |
| chainId; entryPoint; sender; nonce; paymaster; bundler | Packed operation, archived chain id/transaction, pinned deployment and Passport identities | validate.mjs:561; artifact-validate.mjs:195 |
| expectedUserOpHash; epUserOpHash; localUserOpHash; bundledUserOpHashes | Independent ERC-4337 hashes from packed operations, EntryPoint and chain id | validate.mjs:592 |
| callDataHash; derivedCallDataHash; gas.{callGasLimit,verificationGasLimit,preVerificationGas,maxFeePerGas,maxPriorityFeePerGas}; derivedGas; pmGas.{ver,post} | Decode packed limits/fees/paymaster bytes and hash calldata; equality with frozen gas config | validate.mjs:570; validate.mjs:598 |
| readbacks.{before,after}.{A,B}.{blockNumber,blockHash,epDeposit,operatorBalance,totalSpent,totalTxSponsored,protocolRevenue,inflightOperator,inflightA0,userXPNTs,totalSupply,lockedOf,debts,creditReservedOf,lockXLocked,tpmTokenBalances,tpmCachedPriceTimestamp} | Fixed-block archived eth_call return values and complete receipt conservation; A/B equality and continuity | artifact-validate.mjs:233; validate.mjs:197; validate.mjs:645 |
| stateTargets.{superPaymaster,token,tpmToken,operator} | Pinned configuration/Passport target identities for raw state calls | artifact-validate.mjs:205 |
| conservation.{ok,evaluated,checks[].id,checks[].src} | Independently recomputed conservation identities and source citations | validate.mjs:687 |
| evidenceStart[0,1]; evidenceEnd[0,1]; collectedAtUtc | Safe, ordered nonoverlapping archive id intervals; chronological rows and archived send time | artifact-validate.mjs:156 |
| kind; schema; runId; attemptIndex; tripletIndex; arm; armOrder | Journal grammar, sequential attempt indices, candidate grouping, deterministic arm rotation and send chronology | validate.mjs:453; validate.mjs:543; artifact-validate.mjs:271 |
| fixture; rehearsal; rehearsalControl.{kind,atBlock,cachedPriceTimestamp.to}; formal; allowSameEndpointLocal; rpcA; rpcB; protocolConformant | Explicit run policy; rehearsal remains non-evidence; control RPC restricted to rehearsal TPM block/id range; endpoint and conformance recomputation | validate.mjs:442; validate.mjs:471; artifact-validate.mjs:32 |
| arms; count; bMax; frozenConfig; configSha256; deploymentConfigSha256; baselineConfigSha256 | Pinned policy/config files, deterministic formalConfig, target and arm validation | validate.mjs:450; validate.mjs:468; artifact-validate.mjs:128 |
| pins.{collector,validator,dependencies,contractSources,abi,config}[].{path,sha256}; rpcIdentity.{path,sha256} | File hashes, confined archive paths, registry identity checks | artifact-validate.mjs:64; artifact-validate.mjs:113 |
| passport.{chainId,block.number,block.hash,block.timestamp,allowSameEndpointLocal} | Archived chain/block responses and endpoint policy | validate.mjs:352; artifact-validate.mjs:192 |
| passport.invariant.code.{entryPoint,superPaymasterProxy,superPaymasterImpl,xPNTsClone,xPNTsImpl,xPNTsExt,account,accountImpl,verifyingPaymaster,tokenPaymaster,tokenPaymasterToken,tokenPaymasterOracle,priceFeed}.{address,codehash,size} | Config identities, archived code/storage, implementation-slot/clone decoding | validate.mjs:350; artifact-validate.mjs:195 |
| passport.invariant.entryPoint.{address,isCanonicalV07Address}; armEntryPoints.{SP,VPM,TPM,account} | Config, canonical identity and archived contract getters | validate.mjs:354; artifact-validate.mjs:201 |
| passport.invariant.superPaymaster.{version,entryPoint,registry,aPNTs,protocolFeeBPS,aPNTsPriceUSD,priceStalenessThreshold,paused,cachedPrice.price,cachedPrice.decimals,operator.address,operator.isConfigured,operator.isPaused,operator.xPNTsToken,operator.minTxInterval,senderEligible,minPostOpGas} | Archived fixed-block contract getters | validate.mjs:356; artifact-validate.mjs:201 |
| passport.invariant.xPNTs.{address,version,exchangeRate,superPaymaster,maxSingleTxLimit,emergencyDisabled} | Config identity and archived contract getters | validate.mjs:357; artifact-validate.mjs:201 |
| passport.invariant.stakes.{SP,VPM,TPM}.{staked,stake,unstakeDelaySec,withdrawTime}; passport.volatile.depositInfo.{SP,VPM,TPM}.{deposit,staked,stake,unstakeDelaySec,withdrawTime} | Archived EntryPoint depositInfo | validate.mjs:358; artifact-validate.mjs:201 |
| passport.invariant.{verifyingSigner,sender,bundler,beneficiary,callDataHash,gas,pmGas}; credit.{policy,hasPendingPolicy,pendingPolicy,pendingPolicyEta,policyEpoch}; passport.volatile.{cachedPriceUpdatedAt,operatorBalance} | Config/packed task identities, archived getters and credit/storage evidence | validate.mjs:360; validate.mjs:377; artifact-validate.mjs:201 |
| run_end.{tally,triplets[].tripletIndex,triplets[].attempts,triplets[].matched,targetTriplets,matchedTriplets,stop.reason,stop.code,exitCode,passport,rehearsal} | Recomputed attempts/verdicts, conservation, matching, traces, target, terminal status and end Passport | validate.mjs:705; evidence-validate.mjs:122 |
| index.{windowId,attempt,tripleIndex,arm,armOrder,included,verdict,failureReason,notSentReason,exclusionReason,stopReason,replaces,replacedBy,chainId,entryPoint,sender,nonce,paymaster,bundler,packedOp,bundle,callDataHash,gas,expectedUserOpHash,observedUserOpHash,tx,uoe,state,endpoints,passports,trace,pins,rpcIdentity,missing,schemaVersion} | Rebuilt index from bound journal/archive, schema, identity/order and completeness; no final disposition on attempt rows | evidence.mjs:54; evidence-validate.mjs:34; artifact-validate.mjs:208 |
| trailer.{schemaVersion,windowId,void,stopReason,stopAttempt,rehearsal,endPassport,finalBlockCheck,triples[].tripleIndex,triples[].attempts,triples[].included,replacements[].abandoned,replacements[].replacement,replacements[].reason,counts} | Retained candidate partition, validated exclusion edges, one-to-one forward replacement graph, recomputed per-arm counts, historical anchors, end journal and matching | evidence-validate.mjs:29; evidence-validate.mjs:71; evidence.mjs:160; artifact-validate.mjs:141 |

`guard` is required for journal completeness but no member is read to authorize
verdicts/matching/counts. Archive byte aliases, request ids/methods/params,
block anchors, trace options and credential flags are archive integrity inputs,
not journal-derived measurements. `missing` explains absent index evidence but
cannot waive an included candidate's required fields.

Validation: `node --test script/a6-collector/*.test.mjs` — 158 passed,
0 failed, 0 skipped. `node --check script/a6-collector/collector.mjs` passed.
The new regression file contains 23 tests; the archive acceptance test also
exercises 12 mutations. Revert controls are recorded in
`derived-red-results.json`: receipt summary gate (8 failures), archived
disposition gate (4 failures), original bypass restoration (3 failures,
including both requested counterexamples). Each control exited 1; the original
working implementation was restored in a finally block before final validation.
