# Journal decision inputs

The archive boundary is `artifactErrors`; `exclusionReason`, `windowErrors`, and
`evidenceIndex` also serve in-memory construction/structural validation and are
not standalone archive acceptance gates. Formal CLI acceptance requires both
archive verification and the independent conservation/matching pass.

The “journal alone” guarantees apply only on the formal validation path. Raw
archive bytes have no external commitment yet: a consistently rewritten journal
and archive are not independently authenticated. Commit raw-file digests to an
external, append-only record at window start, and commit subsequent raw-file
digests as collection proceeds (including the final files).

Fields below include control metadata: policy, provenance and grouping fields
are constrained by pinned configuration and structural invariants, not claimed
to be facts obtainable from Ethereum receipts. Derived measurements must equal
the archived evidence. Missing nonempty derived values fail. Legacy non-formal
journals may omit empty arrays and UOE log positions; formal receipt positions
and observed events are required when present in raw receipt evidence.

Bindings below name source modules rather than unstable line offsets. In
`evidence-validate.mjs`, `windowErrors` checks row disposition and exclusions.

| Journal fields (brace notation expands each member) | Source / constraint | Decision read / binding |
|---|---|---|
| sent; tx.hash | Successful archived eth_sendRawTransaction in attempt range | `derived-evidence.mjs`; `validate.mjs` |
| verdict; failingCheck | Receipt status, UOE identity/success, revert events; NOT_SENT preflight/error/fee branch | `derived-evidence.mjs`; `validate.mjs`; `disposition.mjs` |
| logs[].{address,topics,data,logIndex,transactionHash}; tx.{status,gasUsed,effectiveGasPrice} | Complete ordered A/B receipt | `artifact-validate.mjs`; `validate.mjs` |
| userOpEvent.{userOpHash,sender,paymaster,nonce,success,actualGasCost,actualGasUsed,logIndex} | Decode matching UserOperationEvent | `derived-evidence.mjs`; `evidence.mjs` |
| observedUserOpEvent.{userOpHash,sender,paymaster,nonce,success,actualGasCost,actualGasUsed,logIndex,txHash} | Decode sender/nonce UOE, receipt transaction identity | `derived-evidence.mjs`; `evidence.mjs` |
| execRevert[].{userOpHash,sender,nonce,revertReason} | UserOperationRevertReason receipt logs | `derived-evidence.mjs`; `evidence.mjs` |
| postOpRevert[].{userOpHash,sender,nonce,revertReason} | PostOpRevertReason receipt logs | `derived-evidence.mjs`; `evidence.mjs` |
| prefundTooLow[].{userOpHash,sender,nonce} | UserOperationPrefundTooLow receipt logs | `derived-evidence.mjs`; `evidence.mjs` |
| revertKind | Decoded UOE success and revert-event precedence | `derived-evidence.mjs`; `evidence.mjs` |
| preflight.{infraFailure,sponsorshipFailed,undecoded,revertReason,inner} | Matching archived A eth_call error; exact bundle/from/to, request/response identity, fixed block and attempt id range; FailedOp/FailedOpWithRevert/Panic decoder | `evidence.mjs`; `artifact-validate.mjs` |
| submissionException.message | Archived eth_sendRawTransaction error.message in attempt range; signed transaction target/input must match handleOps | `derived-evidence.mjs`; `evidence.mjs` |
| feeBlock.{number,hash}; baseFeePerGas | Archived eth_getBlockByNumber base fee, compared with packed/frozen fee cap | `derived-evidence.mjs`; `disposition.mjs` |
| traces[].{call,state,postOpRefreshed}; postOpRefreshed; tpmOracle | A/B archived callTracer/prestateTracer, canonical tracer options, oracle from Passport, independent refresh walk | `derived-evidence.mjs`; `artifact-validate.mjs`; `evidence.mjs` |
| reason; exclusion(.reason); included; stoppedBy.reason | Validated outcome, exclusion vocabulary and failure consistency; stops cannot authorize accepted formal windows | `evidence.mjs`; `disposition.mjs`; `evidence-validate.mjs` |
| tx.{blockNumber,blockHash,blockTimestamp,blockTxCount,headBefore,from} | A/B inclusion block membership/timestamp/transaction list; archived pre-send head; raw transaction sender | `artifact-validate.mjs`; `validate.mjs` |
| tx.{input,gasLimit,maxFeePerGas,maxPriorityFeePerGas,raw,handleOpsIndex}; bundledOps[].{sender,nonce,initCode,callData,accountGasLimits,preVerificationGas,gasFees,paymasterAndData,signature} | Complete viem-formatted tx.raw equals each A/B archived eth_getTransactionByHash response; raw input, decoded handleOps bundle/index/beneficiary, frozen transaction limits | `artifact-validate.mjs`; `artifact-validate.mjs` |
| packedOp.{sender,nonce,initCode,callData,accountGasLimits,preVerificationGas,gasFees,paymasterAndData,signature} | Selected raw handleOps bundle member | `artifact-validate.mjs`; `validate.mjs` |
| chainId; entryPoint; sender; nonce; paymaster; bundler | Packed operation, archived chain id/transaction, pinned deployment and Passport identities | `validate.mjs`; `artifact-validate.mjs` |
| expectedUserOpHash; epUserOpHash; localUserOpHash; bundledUserOpHashes | Independent ERC-4337 hashes from packed operations, EntryPoint and chain id | `validate.mjs` |
| callDataHash; derivedCallDataHash; gas.{callGasLimit,verificationGasLimit,preVerificationGas,maxFeePerGas,maxPriorityFeePerGas}; derivedGas; pmGas.{ver,post} | Decode packed limits/fees/paymaster bytes and hash calldata; equality with frozen gas config | `validate.mjs`; `validate.mjs` |
| readbacks.{before,after}.{A,B}.{blockNumber,blockHash,epDeposit,operatorBalance,totalSpent,totalTxSponsored,protocolRevenue,inflightOperator,inflightA0,userXPNTs,totalSupply,lockedOf,debts,creditReservedOf,lockXLocked,tpmTokenBalances,tpmCachedPriceTimestamp} | Fixed-block archived eth_call return values and complete receipt conservation; A/B equality and continuity | `artifact-validate.mjs`; `validate.mjs`; `validate.mjs` |
| stateTargets.{superPaymaster,token,tpmToken,operator} | Pinned configuration/Passport target identities for raw state calls | `artifact-validate.mjs` |
| conservation.{ok,evaluated,checks[].id,checks[].src} | Independently recomputed conservation identities and source citations | `validate.mjs` |
| evidenceStart[0,1]; evidenceEnd[0,1]; collectedAtUtc | Safe, ordered nonoverlapping archive id intervals; chronological rows and archived send time | `artifact-validate.mjs` |
| kind; schema; runId; attemptIndex; tripletIndex; arm; armOrder | Journal grammar, sequential attempt indices, candidate grouping, deterministic arm rotation and send chronology | `validate.mjs`; `validate.mjs`; `artifact-validate.mjs` |
| fixture; rehearsal; rehearsalControl.{kind,atBlock,cachedPriceTimestamp.to}; formal; allowSameEndpointLocal; rpcA; rpcB; protocolConformant | Explicit run policy; rehearsal remains non-evidence; control RPC restricted to rehearsal TPM block/id range; endpoint and conformance recomputation | `validate.mjs`; `validate.mjs`; `artifact-validate.mjs` |
| arms; count; bMax; frozenConfig; configSha256; deploymentConfigSha256; baselineConfigSha256 | Pinned policy/config files, deterministic formalConfig, target and arm validation | `validate.mjs`; `validate.mjs`; `artifact-validate.mjs` |
| pins.{collector,validator,dependencies,contractSources,abi,config}[].{path,sha256}; rpcIdentity.{path,sha256} | File hashes, confined archive paths, registry identity checks | `artifact-validate.mjs`; `artifact-validate.mjs` |
| passport.{chainId,block.number,block.hash,block.timestamp,allowSameEndpointLocal} | Archived chain/block responses and endpoint policy | `validate.mjs`; `artifact-validate.mjs` |
| passport.invariant.code.{entryPoint,superPaymasterProxy,superPaymasterImpl,xPNTsClone,xPNTsImpl,xPNTsExt,account,accountImpl,verifyingPaymaster,tokenPaymaster,tokenPaymasterToken,tokenPaymasterOracle,priceFeed}.{address,codehash,size} | Config identities, archived code/storage, implementation-slot/clone decoding | `validate.mjs`; `artifact-validate.mjs` |
| passport.invariant.entryPoint.{address,isCanonicalV07Address}; armEntryPoints.{SP,VPM,TPM,account} | Config, canonical identity and archived contract getters | `validate.mjs`; `artifact-validate.mjs` |
| passport.invariant.superPaymaster.{version,entryPoint,registry,aPNTs,protocolFeeBPS,aPNTsPriceUSD,priceStalenessThreshold,paused,cachedPrice.price,cachedPrice.decimals,operator.address,operator.isConfigured,operator.isPaused,operator.xPNTsToken,operator.minTxInterval,senderEligible,minPostOpGas} | Archived fixed-block contract getters | `validate.mjs`; `artifact-validate.mjs` |
| passport.invariant.xPNTs.{address,version,exchangeRate,superPaymaster,maxSingleTxLimit,emergencyDisabled} | Config identity and archived contract getters | `validate.mjs`; `artifact-validate.mjs` |
| passport.invariant.stakes.{SP,VPM,TPM}.{staked,stake,unstakeDelaySec,withdrawTime}; passport.volatile.depositInfo.{SP,VPM,TPM}.{deposit,staked,stake,unstakeDelaySec,withdrawTime} | Archived EntryPoint depositInfo | `validate.mjs`; `artifact-validate.mjs` |
| passport.invariant.{verifyingSigner,sender,bundler,beneficiary,callDataHash,gas,pmGas}; credit.{policy,hasPendingPolicy,pendingPolicy,pendingPolicyEta,policyEpoch}; passport.volatile.{cachedPriceUpdatedAt,operatorBalance} | Config/packed task identities, archived getters and credit/storage evidence | `validate.mjs`; `validate.mjs`; `artifact-validate.mjs` |
| run_end.{tally,triplets[].tripletIndex,triplets[].attempts,triplets[].matched,targetTriplets,matchedTriplets,stop.reason,stop.code,exitCode,passport,rehearsal} | Recomputed attempts/verdicts, conservation, matching, traces, target, terminal status and end Passport | `validate.mjs`; `evidence-validate.mjs` |
| index.{windowId,attempt,tripleIndex,arm,armOrder,included,verdict,failureReason,notSentReason,exclusionReason,stopReason,replaces,replacedBy,chainId,entryPoint,sender,nonce,paymaster,bundler,packedOp,bundle,callDataHash,gas,expectedUserOpHash,observedUserOpHash,tx,uoe,state,endpoints,passports,trace,pins,rpcIdentity,missing,schemaVersion} | Rebuilt index from bound journal/archive, schema, identity/order and completeness; no final disposition on attempt rows | `evidence.mjs`; `evidence-validate.mjs`; `artifact-validate.mjs` |
| trailer.{schemaVersion,windowId,void,stopReason,stopAttempt,rehearsal,endPassport,finalBlockCheck,triples[].tripleIndex,triples[].attempts,triples[].included,replacements[].abandoned,replacements[].replacement,replacements[].reason,counts} | Retained candidate partition, validated exclusion edges, one-to-one forward replacement graph, recomputed per-arm counts, historical anchors, end journal and matching | `evidence-validate.mjs`; `evidence-validate.mjs`; `evidence.mjs`; `artifact-validate.mjs` |

`guard` is required for journal completeness but no member is read to authorize
verdicts/matching/counts. Archive byte aliases, request ids/methods/params,
block anchors, trace options and credential flags are archive integrity inputs,
not journal-derived measurements. `missing` explains absent index evidence but
cannot waive an included candidate's required fields.

Validation and per-finding revert controls for PR #581 are recorded in
`R581-REVIEW-FIXES.md`. Earlier review controls remain in
`derived-red-results.json`.
