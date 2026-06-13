# SuperPaymaster E2E — Real On-Chain Transaction Evidence

> Full Sepolia E2E run 2026-06-13 (`ba1tjtain`): **36/37 PASS, 0 FAIL**; #28 standalone-verified → effective **37/37**.
> Every hash below is a real confirmed on-chain transaction. Network: Sepolia · SuperPaymaster `0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a`.

## How to verify
`cast tx <hash> --rpc-url <sepolia>` and `cast receipt <hash>` — check status=1, decode logs.


## Gasless gas sponsorship — paymaster pays ETH gas, user pays community token (aPNTs/PNTs)

**#26 Gasless: PaymasterV4**
- `tx` → https://sepolia.etherscan.io/tx/0x15d16ae3d1ef1bb5abff0cbf5c6e48688d6fbb0a9d2b3cb02e66ba6c2ba45f65

**#27 Gasless: SuperPaymaster xPNTs1**
- `tx` → https://sepolia.etherscan.io/tx/0x6cb1552d2fd6c8ae15eaafa21b372b0ebc223560a5208703140769b61c0edd9e

**#28 Gasless: SuperPaymaster xPNTs2 (PNTs)**
- `gasless PNTs UserOp (standalone-verified)` → https://sepolia.etherscan.io/tx/0x682cf0e63ecb34d027945e426da4edee1897601a3cce4eff47bca6ead61d1a95

## Credit-based gas sponsorship — operator extends credit, debt recorded in postOp

> ⚠️ **No definitive debt-path tx captured yet — do NOT cite #29 as debt evidence.**
> The tx below took the **BURN path** this run (the AA account held 731 aPNTs, so
> postOp burned tokens instead of recording debt). It proves gasless-burn, the same
> capability as #27 — NOT credit/debt. See the verdicts table at the bottom. A real
> debt-path tx requires re-running test-case-4 with the AA account drained below the
> charge so postOp records debt instead of burning.

**#29 SP Credit/Debt Path — BURN PATH this run (not debt; see verdicts table)**
- `gasless-burn (NOT debt)` → https://sepolia.etherscan.io/tx/0x2b8defdf9f351a1551c9d2411846c62797ed75d7a08c17d5b5137d8320b4691a

## x402 Agent payment settlement — EIP-3009 (USDC) + C-02 direct (xPNTs, drain-proof)

**#31 x402: EIP-3009 Settlement**
- `settleX402Payment` → https://sepolia.etherscan.io/tx/0x82fd3396ee87c25b8d415ef8e6c33732ff7e305b9741de4bb0b02a10891ad7ee

**#32 x402: Direct Settle (C-02 signed auth)**
- `mint` → https://sepolia.etherscan.io/tx/0x8598bb893c587251aa6dd09f6d72d731dac489fb647be22af7d04e1191a19d54
- `settleX402PaymentDirect` → https://sepolia.etherscan.io/tx/0x1901c3eb22e7b786851b893c682ee566c5eb151e0ffc238fe6ded5d2e78f1e68
- `settleX402PaymentDirect(5b)` → https://sepolia.etherscan.io/tx/0xe48720cf4acc3f1a685f0cc97cbcce92d971facca8118818881d968021d55633

## MicroPayment streaming channel — off-chain cumulative vouchers, on-chain settle/close

**#30 MicroPaymentChannel: Open / Settle / Close**
- `openChannel` → https://sepolia.etherscan.io/tx/0xb935b5a6b41cd9daf6efdcb6518a435eda0666c8d101d598442a998864b1795d
- `settleChannel` → https://sepolia.etherscan.io/tx/0xdca794fb8d21434c795a2d34152818403b85465cc8255dd5b1f8211ddb678a65
- `closeChannel` → https://sepolia.etherscan.io/tx/0xde9fbe02b3bb4bb5db4f3f3a2ff62dda1a24d8d366d9b3ffe9121f33517f6876

## Operator lifecycle & SuperPaymaster governance

**#5 B1: Operator Config**
- `setOperatorLimits(60)` → https://sepolia.etherscan.io/tx/0xf648f4112f125a941bdea583c94a3bb654c558542e98bea2184cc84d44193811
- `Pause operator` → https://sepolia.etherscan.io/tx/0x15cab591003590a9a327033bc7a33a48c0268d1d8d4e5bbf4672b678b7978a6a
- `Unpause operator` → https://sepolia.etherscan.io/tx/0xce6b45930fbff35608daf382237cf16e579fdfbc604d6fe34d0a44b84cdcf4fb

**#6 B2: Operator Deposit/Withdraw**
- `deposit(10)` → https://sepolia.etherscan.io/tx/0x2bf8b96cbd976f8d8f7845c7b7b1d82620cd0879de3b0626154b3e2e6ae74f59
- `depositFor(5)` → https://sepolia.etherscan.io/tx/0xcecc34da2cf939acbc082187ee8d507ea568aa6368cd812d78572f8bc3f5be4c
- `withdraw(3)` → https://sepolia.etherscan.io/tx/0x07108c3cca975932e490f8ce853a674db3dd6575c81b9f7879a78a18aa50b367
- `withdraw(12.0)` → https://sepolia.etherscan.io/tx/0x73858bc0479d99c599e2606de135667b0751110a588016aa78538c58a91c821a

**#7 B3: configureOperator v2 (2-arg, PR#200)**
- `configureOperator(xPNTs, treasury)` → https://sepolia.etherscan.io/tx/0x2103e4b4b0943fe152966c425051f5058e2d1cba7f04097abc390e15b63c82f2
- `configureOperator (restore treasury)` → https://sepolia.etherscan.io/tx/0xa1acf71d3f7baab7bc83a40c0945a7823b3f95d9d7c8ac085e3cc9a80e2d6311

**#8 B4: SP Governance Admin**
- `setTreasury(deployer)` → https://sepolia.etherscan.io/tx/0xc586a5898a404d39bf3988cf8097b752dcc1126992f1b229526ec628c78c7120
- `setAgentRegistries(deployer)` → https://sepolia.etherscan.io/tx/0x0db897864fef9e11d422715f6a63f9d973d81d7078d78615b288263470384937
- `setAgentRegistries(restore)` → https://sepolia.etherscan.io/tx/0x5e40572396061c837f9c7a8fc5fb6ea78d7481322dd305881716b6c0e6f71602
- `setFacilitatorFeeBPS(100)` → https://sepolia.etherscan.io/tx/0xd0d046b2fb58c5832cb461b61b54393bc9193c1cb1fbf09c7f35cf045a8947ed
- `setFacilitatorFeeBPS(restore)` → https://sepolia.etherscan.io/tx/0x6fb73d1d91e1ef59d2bbf0c3a302ca3380b8f6fd7846b50b9cc9b7b1bca19b33
- `setOpFacFee(50)` → https://sepolia.etherscan.io/tx/0x5c406e6f6fd2d5889295aba7a11c402f3d0df0cb5660c1087f2c2e501dca6c69
- `setOpFacFee(restore)` → https://sepolia.etherscan.io/tx/0x4cc21147c0c03e6f0ba75bc8566aa67fba4359bbb687933f6821870a15e95683
- `queue BLS agg (deployer as test address)` → https://sepolia.etherscan.io/tx/0x821738eabc5760c369abc6cb6d7e14757d9e466e40371f850fa30ec5763a8bac
- `withdrawProtocolRevenue(33.891658829500286642)` → https://sepolia.etherscan.io/tx/0xe3af503bf5c59cacdc97786e743722a6e0d5f826cd95511b53d47ea047fc0d4b

**#34 P2: PaymasterV4 Lifecycle (deposit/withdraw/activate)**
- `deactivate` → https://sepolia.etherscan.io/tx/0x0e500d75942dfca880137a04e838c1c47bcd7ac39a98e46e4ec622d8fdc9fc62
- `activate` → https://sepolia.etherscan.io/tx/0x0138f6cae8a97ede7191f79ecac0b205cc6287684f2c0f13d3fdf943d1ab6730
- `depositFor(user, aPNTs, 1)` → https://sepolia.etherscan.io/tx/0xd6aa16888ed9345096a7611e925cc763504a7a2c581acaf899475a5a86440cf0
- `withdraw(aPNTs, amount)` → https://sepolia.etherscan.io/tx/0xf1756c6e49cd755e7dc3fa4b8c29e3e9c880182a8d8abbec65dc1d131a604232
- `updatePrice` → https://sepolia.etherscan.io/tx/0x272faf213f29589f6e57339c2a686a00bd037f41fbd728e6e032ce807f345cab

**#35 X1: xPNTs Token Admin (limits/spenders/exchange-rate)**
- `setMaxSingleTxLimit` → https://sepolia.etherscan.io/tx/0xde6b273a2c1c3ab3539bbd6dcccb859782e0089ed43d6d4ce9f2ede0dde176b7
- `restoreMaxSingleTxLimit` → https://sepolia.etherscan.io/tx/0x59e6b152f2b2bd77548acfaac76e7f6de90e10a3a37edf23f155b87ea5577025
- `setSpenderDailyCap` → https://sepolia.etherscan.io/tx/0x763af15d78ac4d9d3257034ba5e96a0ad138d03957822b5d484c1d3118206bbf
- `restoreSpenderDailyCap` → https://sepolia.etherscan.io/tx/0x9abf487ed8eb72eae9b76f0071b4e9ab2f2f5eb6328e11adc60f7eaaafdfd0b9
- `removeAutoApprovedSpender` → https://sepolia.etherscan.io/tx/0x4097c6a76c67595142ae4441af848f9e763e68c3c7f0808f1f0db87b1c2e9f6b
- `addAutoApprovedSpender(restore)` → https://sepolia.etherscan.io/tx/0xe43fa212de0e43ad855b3e64d5b592ca5fba911dc4b80221f1688a6d7e0c973b
- `removeApprovedFacilitator` → https://sepolia.etherscan.io/tx/0x384265372bc893bc800d5291b0ba0e54000d7ea10bc8df291e504fc486adbf8e
- `addApprovedFacilitator(restore)` → https://sepolia.etherscan.io/tx/0x819b76b84672f56256e66f3cec5c33ce53093b8e4c7e63b65b28b4a3d8221c1a
- `burn(1 wei)` → https://sepolia.etherscan.io/tx/0x0925bc9adb27a6243e10074b72db04027cc997cab99c895d5c825245408b205b
- `tx` → https://sepolia.etherscan.io/tx/0x9c8c05830693a838bd1316b7f0f08a4e002dca8669c794a3d66c08e9bbbc3f98

## Reputation system & credit tiers

**#12 D1: Reputation Rules**
- `setRule(E2E_ACTIVITY)` → https://sepolia.etherscan.io/tx/0x8a48fb4cfa0cd21be1e144b4992173a3c1e51b16bf8d61ad1c00d3e281a1d281
- `setEntropyFactor(1.5)` → https://sepolia.etherscan.io/tx/0x59729e7dd20574e897d48e6a7879fe82ddcc84f5e995c32a36b419ba75219f8d
- `Restore entropyFactor(1)` → https://sepolia.etherscan.io/tx/0xc9c839a8807d6a30419256fdd095d3b3e7a7db54416517900b6e26ebd787bba4
- `setCommunityReputation(42)` → https://sepolia.etherscan.io/tx/0xb937a2ea3dd17ecfecae63a21067657c8034b4f828378beb5d7d5a9a66bf7362
- `Remove E2E_ACTIVITY rule` → https://sepolia.etherscan.io/tx/0x19f7caaba059a2e60ac7d2954445d9c60db95e00bb7846774653e417cd85f084

**#13 D2: Credit Tiers**
- `setCreditTier(7, 5000)` → https://sepolia.etherscan.io/tx/0xeb2e7904c0ec295709baab4cc96e4f077d48117fb7e393afd650029387e2f8db
- `setCreditTier(7, 0)` → https://sepolia.etherscan.io/tx/0x877e1f7d0158983c05f3180dbb795e422b2353a9594817c1048e23808eea926d

## Pricing, oracle & protocol fees

**#14 E1: Pricing & Oracle**
- `updatePrice()` → https://sepolia.etherscan.io/tx/0x172ddef3021708cfbb81e5dc4368415a4c05b33b4082d14e0d4fd49ca5502de0
- `setAPNTSPrice(0.03)` → https://sepolia.etherscan.io/tx/0x849ab78f7581c8e88de88dec9600fb5d1c70a76567b7ca944f99489202a45f38
- `Restore aPNTsPriceUSD(0.02205)` → https://sepolia.etherscan.io/tx/0xfb159aa6352e4f43a415ebebd5e80a48bbb983c32104fd6ac74a6c348fe60238
- `PaymasterV4.updatePrice()` → https://sepolia.etherscan.io/tx/0x6b6d9d0e3fad124ba49c091b4277918f31687023e2e82792d0eab6a75ac6a15a

**#15 E2: Protocol Fees**
- `setProtocolFee(500)` → https://sepolia.etherscan.io/tx/0xab30988147a9993dcfd3e209beedb5c469fbcfdacc6e73edc2ed118e7528d7ce
- `Restore protocolFeeBPS(500)` → https://sepolia.etherscan.io/tx/0xff5f3f4ee5fd15fe485248ac64f03df4935399edf22377c4eaf6ae4b28625be5

## Security hardening — H-2 emergency halt + negative paths

**#37 I2: Emergency Halt H-2 Fix**
- `emergencyRevokePaymaster()` → https://sepolia.etherscan.io/tx/0x1ce5219e55755fef09dda3ecddd1871f533a5f1c58a87623a7fee8cfbaaad6a6
- `tx` → https://sepolia.etherscan.io/tx/0xffc5ee2f54e8ec09e0ac74c2729931739add979378c5f26b8c34547ef08bfdf4
- `tx` → https://sepolia.etherscan.io/tx/0xd8907b14a41c9c32356647f55105ddf33b2113a0bcd3dff9701c5278d4aaf1c7
- `tx` → https://sepolia.etherscan.io/tx/0xb0d616bf3472df5951e876a5c55454c581cfe32f8121474bebbc98798c24a8b1
- `unsetEmergencyDisabled()` → https://sepolia.etherscan.io/tx/0x3a2db92c29d5ce2061df1b1d947a4b13e48744416ff1c22c7ff593a979f6312e
- `tx` → https://sepolia.etherscan.io/tx/0xf8836e9859768397af1d98675814795af09e189352bc92408bf6294c4b32910c

**#10 C1: SuperPaymaster Negative**
- `Pause deployer operator` → https://sepolia.etherscan.io/tx/0x9f7237d78932eaef8b2005106a75ec43f4a46e5dadb5ea241681f38325e873f1
- `Unpause deployer operator` → https://sepolia.etherscan.io/tx/0x44a1ae91af46d6cd8d0208149962d3b61454220ce1745604d69c3d8f90c39b3b

## Staking & registry administration

**#19 F2: Slash History**
- `updateReputation(100)` → https://sepolia.etherscan.io/tx/0x97d757b39562e957b4c921b1119c9ac7558d21d73230597f4bc8ce792b88d8ad

**#20 F3: Staking & Registry Admin**
- `setRoleExitFee(COMMUNITY)` → https://sepolia.etherscan.io/tx/0x78280966f174404c423f5463c78180b8fb5d8828fb4662f50db1c62d15b44d86
- `restoreExitFee(COMMUNITY)` → https://sepolia.etherscan.io/tx/0x10591e2877c3a9e6255edd277154d501214f4fb58b99a5ded341f3401824fc2c
- `addSlasher` → https://sepolia.etherscan.io/tx/0x61ad0deb3eef07c0e0b99aff66ad49c605c024bc56f11287745f97076e576263
- `removeSlasher` → https://sepolia.etherscan.io/tx/0xb9d9d5deb2ed40ee9f68ca972d135c0864e4288165b95b08e320f77d1f2fe118
- `addRepSource` → https://sepolia.etherscan.io/tx/0x8f3ae050109fbb232cb4a8d886546b3d07426d2b1289337d5b59ad9a1a0a7761
- `removeRepSource` → https://sepolia.etherscan.io/tx/0x7f985e75f97062485a0b4bd054567ac9cb516ab37da1a5bdd126610df037350a
- `setLevelThresholds` → https://sepolia.etherscan.io/tx/0xfbea04ec7550367ac05452dda291df725d3fc24b69625f0e609702ebba568dd8
- `restoreLevelThresholds` → https://sepolia.etherscan.io/tx/0x72b3eecbffe9b972b0828149d8b45f941701fe89fbddf7241c1aa089bd9b8dac
- `setCreditTier(3, 350e18)` → https://sepolia.etherscan.io/tx/0xe88af54f42fb3f5990441c2523ef9e5dd2cad47ae6f4ce5c45eb5d84f605fb7c
- `restoreCreditTier` → https://sepolia.etherscan.io/tx/0xaed01259e0251ec87b7462b624c854c7f456a6d9265f4b44e0ef1ed1874ee85b

---

## Adversarial verification verdicts (codex challenge + on-chain decode)

Each core capability was independently decoded on-chain (logs via public Sepolia RPC) and adversarially judged by codex.

| Capability | Tx | On-chain evidence | Verdict |
|---|---|---|---|
| Gasless — PaymasterV4 (#26) | `0x15d16ae3` | UserOperationEvent paymaster=`0x2118…`(PaymasterV4) paid 0.00047 ETH; user transferred 1 aPNTs; gas debited from PaymasterV4 deposit ledger (no burn event) | ✅ VERIFIED |
| Gasless — SuperPaymaster aPNTs (#27) | `0x6cb1552d` | paymaster=SuperPaymaster paid 0.00065 ETH; AA burned 35.32 aPNTs for gas; AA EOA spent 0 ETH | ✅ VERIFIED |
| Gasless — SuperPaymaster PNTs (#28) | `0x682cf0e6` | paymaster=SuperPaymaster paid 0.00064 ETH; AA burned 33.59 PNTs for gas; user transferred 1 PNTs | ✅ VERIFIED |
| x402 — EIP-3009 USDC (#31) | `0x82fd3396` | USDC payer→SP 1.0, SP→payee 0.99, 0.01 fee (facilitatorFeeBPS=100) | ✅ VERIFIED |
| x402 — Direct C-02 (#32) | `0x1901c3eb`,`0xe48720cf` | xPNTs payer→SP 1.0, SP→payee 0.99 + 0.01 fee, both settles. Drain-protection (recipient-bound sig) is a `staticCall` negative test (test-case-3 Step 5a: redirect→InvalidX402Signature revert) — asserted off-chain, no tx. | ✅ positive VERIFIED + negative via staticCall |
| MicroPayment channel (#30) | `0xb935b5a6`/`dca794fb`/`de9fbe02` | open locked 10 aPNTs; settle paid 3; close paid 4 to payee (cumulative 7) + refunded 3 to payer; 7+3=10 reconciles | ✅ VERIFIED |
| **Credit/debt sponsorship (#29)** | `0x2b8defdf` | ⚠️ This run took the **BURN path** (AA_A held 731 aPNTs → `will use BURN PATH … no debt`), so this tx proves gasless-burn, NOT debt. The credit/debt path (recorded debt when balance is insufficient) requires a balance-starved scenario; its gate is exercised by test-case-4's dryRun credit check. | ⚠️ MISCLASSIFIED — not a debt tx |

**Note on #29**: the credit/debt capability is gated and tested (dryRunValidation credit ceiling, C-01), but the captured tx happens to exercise the burn branch. A definitive debt-path tx requires running test-case-4 with the AA account drained below the charge so postOp records debt instead of burning.
