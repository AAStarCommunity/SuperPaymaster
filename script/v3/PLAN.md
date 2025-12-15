# V3 E2E Gasless Integration Test Plan

## Objective
Perform a full end-to-end integration test of the SuperPaymaster V3 ecosystem, including `SuperPaymasterV3` (Shared) and `PaymasterV4` (Unified/Factory). The test will submit valid UserOperations to EntryPoint v0.7 via a TypeScript script.

## Directory Structure
`script/v3/`
- `PLAN.md`: This plan.
- `SetupV3.s.sol`: Solidity script for Deployment, Wiring, and Data Preparation.
- `test-e2e.ts`: TypeScript script for constructing and submitting UserOps.
- `config.json`: (Generated) Output of SetupV3 containing contract addresses.

## 1. Data Preparation (Solidity Script)
**Script**: `script/v3/SetupV3.s.sol`

This script will run on the target network (Sepolia) or Anvil to prepare the environment state.

### Phase 1: Deployment
1.  Deploy `GToken`, `GTokenStaking`, `Registry`, `MySBT` (Core V3).
2.  Deploy `SuperPaymasterV3`.
3.  Deploy `PaymasterFactory` & `PaymasterV4`.
4.  Deploy `xPNTsFactory` and a Test `xPNTs` Token.

### Phase 2: Wiring
1.  Set Registry & SuperPaymaster as Lockers in Staking.
2.  Set MySBT Protocol Addresses.
3.  Configure `SuperPaymaster` (Treasury, aPNTs).

### Phase 3: Registration & Initialization
1.  **Community**: Register a Community (for xPNTs). Stake 30 GT.
2.  **Operator**: Register an Operator (for SuperPaymaster). Stake 30 GT.
    *   Deposit `aPNTs` into SuperPaymaster balance.
3.  **Paymaster V4**:
    *   Community deploys V4 Paymaster via Factory.
    *   Deposit ETH to EntryPoint for V4.
    *   Register V4 in Registry (Optional/Unified).
4.  **SuperPaymaster**:
    *   Deposit ETH to EntryPoint for SuperPaymaster.
    *   Configure Operator (Map xPNTs -> Treasury).

### Phase 4: User Setup
1.  Identify User AA Account (SimpleAccount).
2.  **Mint GToken** to User.
3.  **Register EndUser Role** (Mint MySBT).
4.  **Mint xPNTs** to User AA.
5.  **Approve xPNTs**:
    *   User AA approves `SuperPaymaster` (for Scenario B).
    *   User AA approves `PaymasterV4` (for Scenario A).
    *   *Note: Approvals handled via `execute` in UserOp or setup script.*

## 2. Test Execution (TypeScript)
**Script**: `script/v3/test-e2e.ts`

This script replaces the historical `gasless-tests` scripts. It uses `ethers.js` to interact with the deployed environment.

### Scenario A: Paymaster V4 (Factory Mode)
1.  Construct `UserOp` (Transfer xPNTs).
2.  `paymasterAndData` = `[V4_Address] + [validPeriod]`.
3.  Get Hash via `entryPoint.getUserOpHash`.
4.  Sign UserOp (EOA).
5.  Submit via `entryPoint.handleOps`.
6.  Verify: xPNTs Transfer succeeded, No fee in `xPNTs` (V4 specific logic - maybe native payment?).
    *   *Clarification*: V4 supports `xPNTs` payment? Yes, implied.

### Scenario B: SuperPaymaster V3 (Shared Mode)
1.  Construct `UserOp` (Transfer xPNTs).
2.  `paymasterAndData` = `[SP_Address] + [mode?]`.
    *   Since V3, validation relies on Registry.
3.  Get Hash.
4.  Sign UserOp.
5.  Submit via `entryPoint.handleOps`.
6.  Verify:
    *   xPNTs deducted from User.
    *   aPNTs deducted from Operator in SuperPaymaster.

## Execution Steps
1.  Run `forge script script/v3/SetupV3.s.sol --broadcast --rpc-url sepolia`
2.  Export addresses to `script/v3/config.json`.
3.  Run `ts-node script/v3/test-e2e.ts`.
