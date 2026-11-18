// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;
import {PolicyRegistry} from "src/core/PolicyRegistry.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Script.sol";
import {APNTsCapped} from "src/tokens/APNTsCapped.sol";
import {DeployLivePins} from "./DeployLivePins.sol";
import {DeployLiveInputs} from "./DeployLiveInputs.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {TimelockHandoverBootstrap, TimelockHandover} from "./TimelockHandoverBootstrap.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core Imports
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
// Named import: avoid leaking GTokenAuthorization's transitive EIP712 symbol into
// this file's scope (it would clash with MicroPaymentChannel's EIP712 — both inherit
// a differently-pathed EIP712, causing "Identifier already declared").
import {GTokenAuthorization} from "src/tokens/GTokenAuthorization.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";

// Paymaster Imports
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

// Module Imports
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import {GovernanceOwnerGate} from "../checks/GovernanceOwnerGate.sol";
import "src/modules/monitoring/DVTValidator.sol";
import {MicroPaymentChannel} from "src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";
// BLSValidator standalone contract removed in P0-1 — Registry now verifies via BLSAggregator.

// External Interfaces
import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// v5.4 god-split + DVT policy (X402Facilitator + TimelockController + PolicyRegistry + wiring)
import {V54Bootstrap} from "./V54Bootstrap.sol";
// v5.5.0 balance mode: xPNTs v2 stack (AOA registry, tier source, template, factoryV2, lens)
import {V55Bootstrap, IxPNTsV2Script} from "./V55Bootstrap.sol";

/**
 * @title DeployLive
 * @notice Full Infrastructure Deployment (Steps 1-5 AAStar + Step 6 Mycelium Community).
 *         Step 8 deploys the v5.4 god-split contracts so a fresh GA deploy is v5.4-complete.
 * @dev    SuperPaymaster 5.5.0 (D5.2): Step 3b deploys the xPNTs v2 stack (runbook step 4) and
 *         SP.xpntsFactory points at xPNTsFactoryV2 (step 6); Mycelium's PNTs is a v2 token.
 *         The 3.x xPNTsFactory still deploys the protocol aPNTs (APNTS_TOKEN, the operator
 *         deposit asset) and stays bound into GTokenAuthorization and X402Facilitator.
 */
contract DeployLive is V54Bootstrap, V55Bootstrap, DeployLiveInputs, DeployLivePins {
    using Clones for address;

    uint256 deploymentStartBlock;
    uint64 popStartNonce;
    bytes32 popStartBlockHash;
    string popRequestOut;
    string popCommit;
    address bootstrapAddr;
    uint256 bootstrapNonce;
    uint256 observedBootstrapNonce;
    uint256 gtokenTransferred;
    uint256 treasuryGTokenBefore;
    uint256 ticketsToTreasury;
    uint256 gtokenRecipientBefore;
    address[] mintRecipients;
    uint256[] mintAmounts;
    address[] stakeAccounts;
    bytes32[] stakeRoles;
    uint256[] stakeAmounts;
    uint256[] ticketAmounts;
    address[] ticketTreasuries;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;
    address simpleAccountFactory;
    address spImplAddr; // SuperPaymaster implementation (UUPS)
    address registryImplAddr; // Registry implementation (UUPS) — needed by audit-core ERC-1967 check
    address erc8004Validation; // ERC-8004 ValidationRegistry (stored for config; SP doesn't wire it yet)
    MicroPaymentChannel microPaymentCh; // Deployed in Step 4

    GTokenAuthorization gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymaster superPaymaster;
    ReputationSystem repSystem;
    BLSAggregator aggregator;
    DVTValidator dvt;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    Paymaster pmV4Impl;
    address pntsAddr; // Mycelium Community PNTs

    // v5.4 god-split addresses (deployed in Step 8, written to config)
    address x402FacilitatorAddr;
    address policyRegistryAddr;
    address timelockControllerAddr;

    // v5.5.0 xPNTs v2 stack (deployed in Step 3b, written to config under NEW keys)
    V55Stack v55;

    function setUp() public {
        // System / External Infrastructure (Remains in ENV)
        entryPointAddr = vm.envAddress("ENTRY_POINT");
        priceFeedAddr = vm.envAddress("ETH_USD_FEED");
        simpleAccountFactory = vm.envAddress("SIMPLE_ACCOUNT_FACTORY");

        // Resolve Deployer Address
        // 1. Try DEPLOYER_ADDRESS (if set by wrapper script)
        // 2. Fallback to msg.sender (only for Anvil/Private Key mode)
        deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (deployer == address(0)) deployer = msg.sender;
    }

    error DeployerHasCode(address account);

    function _requireUndelegatedDeployer() internal view {
        if (deployer.code.length != 0) revert DeployerHasCode(deployer);
    }

    function run() external {
        deploymentStartBlock = block.number;
        popStartNonce = vm.getNonce(deployer);
        // EVM BLOCKHASH cannot read the current block: pin the parent hash explicitly.
        popStartBlockHash = block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
        popRequestOut = _popRequestPath();
        if (bytes(popRequestOut).length != 0) require(!_popBroadcastContext(), "STOP pop_request_broadcast");
        // SP_COMMIT names the source commit: required for a PoP request and for every production run,
        // where it is written to config.commit (the post-deploy checker compares it with git HEAD).
        if (bytes(popRequestOut).length != 0 || _production()) {
            popCommit = _popRequestCommit();
            bytes memory commit = bytes(popCommit);
            require(commit.length == 40, "STOP pop_request_commit");
            for (uint256 i; i < commit.length; ++i)
                require((commit[i] >= 0x30 && commit[i] <= 0x39) || (commit[i] >= 0x61 && commit[i] <= 0x66), "STOP pop_request_commit");
        }
        if (_production()) _requireUndelegatedDeployer();
        _stopBeforeBootstrap(); // Validate the rehearsal flag before any broadcast.
        // Use the configured account from CLI (--account or --private-key)
        _loadProductionInputs(deployer);
        if (_production()) _validateInfrastructure(entryPointAddr, priceFeedAddr, simpleAccountFactory);
        if (_production()) _assertCreationPins(vm.envString("CREATION_PINS"));
        vm.startBroadcast();

        console.log("Deployer:", deployer);

        console.log("=== Step 1: Deploy Foundation (Scheme B - UUPS Proxy) ===");

        // Deploy Registry as UUPS proxy first (no deps)
        // T-4: EVERY contract below is deployed from its profile.default artifact by explicit
        // path (DefaultArtifacts._deployDefault) and asserted equal to it right after creation;
        // _assertAllDefaultArtifacts() re-checks the whole set at the end. This file imports
        // Registry.sol, so a plain `new` would ship the runs=200 registry-size build.
        Registry regImpl = Registry(_deployDefault("Registry", ""));
        registryImplAddr = address(regImpl); // capture for config write (UUPS upgrade support)
        bytes memory regInit = abi.encodeCall(Registry.initialize, (deployer, address(0), address(0)));
        registry = Registry(_deployDefault("ERC1967Proxy", abi.encode(address(regImpl), regInit)));

        // Deploy xPNTsFactory early — GTokenAuthorization needs factory address (immutable)
        xpntsFactory = xPNTsFactory(_deployDefault("xPNTsFactory", abi.encode(address(0), address(registry)))); // SP not deployed yet

        // Deploy GTokenAuthorization (replaces plain GToken)
        gtoken = GTokenAuthorization(
            _deployDefault("GTokenAuthorization", abi.encode(uint256(21_000_000 * 1e18), address(xpntsFactory)))
        );

        // Deploy Staking and MySBT with immutable Registry + GToken references
        staking =
            GTokenStaking(_deployDefault("GTokenStaking", abi.encode(address(gtoken), deployer, address(registry))));
        if (_production()) {
            staking.setTreasury(safeInput);
            treasuryGTokenBefore = gtoken.balanceOf(safeInput);
        }
        mysbt =
            MySBT(_deployDefault("MySBT", abi.encode(address(gtoken), address(staking), address(registry), deployer)));

        // Wire staking and MySBT into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));
        // Wire MySBT into GTokenAuthorization (one-time, locks RC-2 SBT path)
        gtoken.setMySBT(address(mysbt));
        // Sync exit fees for ALL operator roles (minStake > 0).
        // ⚠ When adding new operator roles in Registry.initialize(), add them here too.
        bytes32[] memory exitFeeRoles = new bytes32[](5);
        exitFeeRoles[0] = ROLE_PAYMASTER_AOA;
        exitFeeRoles[1] = ROLE_PAYMASTER_SUPER;
        exitFeeRoles[2] = ROLE_DVT;
        exitFeeRoles[3] = ROLE_ANODE;
        exitFeeRoles[4] = ROLE_KMS;
        registry.syncExitFees(exitFeeRoles);

        // CRITICAL: Must register COMMUNITY and deploy aPNTs BEFORE SuperPaymaster
        // so aPNTs address can be passed to initialize() — avoids 7-day setAPNTsToken timelock.
        console.log("=== Step 2: Pre-register AAStar COMMUNITY + Deploy aPNTs ===");
        _mintGToken(2000 ether);
        gtoken.approve(address(staking), 2000 ether);
        Registry.CommunityRoleData memory aaStarData =
            Registry.CommunityRoleData({name: _production() ? "Deployment bootstrap" : "AAStar", ensName: _production() ? "" : "aastar.eth", stakeAmount: _production() ? 0 : 30 ether});
        if (_production()) _recordRegistration(deployer, ROLE_COMMUNITY);
        registry.registerRole(ROLE_COMMUNITY, deployer, abi.encode(aaStarData));

        // xPNTsFactory already deployed in Step 1
        address apntsAddr =
            _production() ? _deployDefault("APNTsCapped", abi.encode("AAStar PNTs", "aPNTs", capInput, deployer, safeInput, safeInput))
                : xpntsFactory.deployxPNTsToken("AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0));
        apnts = xPNTsToken(apntsAddr);
        console.log("  aPNTs Deployed at:", apntsAddr);

        console.log("=== Step 3: Deploy SuperPaymaster (UUPS Proxy) ===");
        // AUD-4: explicit profile.default artifact (this file imports Registry.sol, so a plain
        // `new` would ship the runs=200 registry-size build).
        SuperPaymaster spImpl = SuperPaymaster(
            payable(_deployDefault("SuperPaymaster", abi.encode(entryPointAddr, address(registry), priceFeedAddr)))
        );
        spImplAddr = address(spImpl); // capture for config write
        bytes memory spInit = abi.encodeCall(SuperPaymaster.initialize, (deployer, address(apnts), deployer, 4200));
        superPaymaster = SuperPaymaster(payable(_deployDefault("ERC1967Proxy", abi.encode(address(spImpl), spInit))));
        if (_production()) superPaymaster.setTreasury(safeInput);

        console.log("=== Step 3b: Deploy xPNTs v2 stack (runbook step 4) ===");
        v55 = _ensureV55Stack(v55, address(superPaymaster), address(registry), deployer);

        console.log("=== Step 4: Deploy Modules ===");
        repSystem = ReputationSystem(_deployDefault("ReputationSystem", abi.encode(address(registry))));
        dvt = DVTValidator(
            _deployDefault(
                "DVTValidator",
                abi.encode(address(registry), uint256(1), new bytes32[](0), new address[](0))
            )
        );
        aggregator = BLSAggregator(
            _deployDefault("BLSAggregator", abi.encode(address(registry), address(superPaymaster), address(dvt)))
        );
        if (bytes(popRequestOut).length != 0) {
            vm.stopBroadcast();
            _writePopRequest();
            console.log("STOP: PoP request written; simulation ends before guardian registration:", popRequestOut);
            return;
        }
        microPaymentCh = MicroPaymentChannel(_deployDefault("MicroPaymentChannel", abi.encode(deployer)));

        pmFactory = PaymasterFactory(_deployDefault("PaymasterFactory", ""));
        pmV4Impl = Paymaster(payable(_deployDefault("Paymaster", abi.encode(address(registry)))));

        console.log("=== Step 5: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 6: Role Orchestration (Jason / AAStar) ===");
        if (_production()) _registerProductionGuardians();
        else _orchestrateRolesJason();

        console.log("=== Step 7: Mycelium Community (Anni) ===");
        // On mainnet (no PRIVATE_KEY_ANNI), skip in-script Mycelium setup.
        // Run InitializeMyceliumPrep.s.sol + InitializeMycelium.s.sol separately.
        if (!_production() && vm.envOr("PRIVATE_KEY_ANNI", uint256(0)) != 0) {
            _setupMyceliumCommunity();
        } else {
            console.log("  PRIVATE_KEY_ANNI not set - skipping Mycelium setup.");
            console.log("  Run InitializeMyceliumPrep + InitializeMycelium scripts after deploy.");
        }

        console.log("=== Step 8: v5.4 god-split (X402Facilitator + Timelock + PolicyRegistry) ===");
        gtoken.approve(address(staking), 0);
        _deployV54Stack();
        if (_stopBeforeBootstrap()) {
            vm.stopBroadcast();
            _generateConfig();
            return;
        }

        console.log("=== Wiring Integrity Check (D-H4) ===");
        _assertWiring();

        // CC-48 round-6 HIGH-1: hand the DISARM AUTHORITY to governance as the very last
        // owner-gated action, then refuse to finish if it is still an EOA anywhere it
        // matters. `emergencyDisarmFraudProofVerifier()` is immediate and unannounced, so
        // an EOA-owned aggregator means one hot key can censor every future guardian-slash
        // accusation by front-running it out of the mempool -- and no Timelock can cover
        // that path. DVT ownership moves to the same boundary because its validator-removal
        // route must not remain with the deployer. Everything above still runs deployer-owned.
        if (!_production()) {
            _settleAggregatorGovernance();
            _settleTokenGovernance();
        } else _assertHandover();

        vm.stopBroadcast();
        if (!_production()) {
        GovernanceOwnerGate.requireGovernanceOwner(address(aggregator), aggregator.owner(), "BLSAggregator");
        require(dvt.owner() == aggregator.owner(), "DeployLive: DVT owner != BLS owner");
        // Not wrapped in a `declaredGovernanceOwner() != 0` check, and the aggregator's
        // is not either. With the variable unset the gate REFUSES rather than passing,
        // even when the owner is already a Safe -- it proves "this is the Safe the
        // operator declared", not "this is a Safe" (pinned by
        // test_SafeOwnedSubjectIsStillRefusedWhenNothingWasDeclared). So a guard here
        // was redundant, and leaving it in meant the three subjects were gated by two
        // different rules for no reason. Raised by pr-daemon on #404.
        GovernanceOwnerGate.requireGovernanceOwner(address(apnts), apnts.communityOwner(), "aPNTs");
        GovernanceOwnerGate.requireGovernanceOwner(address(xpntsFactory), xpntsFactory.owner(), "xPNTsFactory");
        // The v2 factory and the AOA allowlist hold the same class of power (factory: SP pointer,
        // tier source and CC-28 inputs for every v2 token; registry: which SP / spender / tier
        // source a token may ever activate), so they are gated by the same rule.
        GovernanceOwnerGate.requireGovernanceOwner(v55.factory, xPNTsFactoryV2Owner(), "xPNTsFactoryV2");
        GovernanceOwnerGate.requireGovernanceOwner(v55.aoaRegistry, aoaRegistryOwner(), "AOAProtocolRegistry");

        }

        // v5.5.0 read-back (runbook steps 4 / 6 / 7a). View-only.
        _verifyV55Stack(v55, address(superPaymaster), address(registry));
        _verifySPFactory(address(superPaymaster), v55.factory);
        require(_strEq(superPaymaster.version(), SP_V55_VERSION), "DeployLive: SP is not 5.5.0");
        require(_implOf(address(superPaymaster)) == spImplAddr, "DeployLive: SP proxy impl != deployed impl");
        _requireDefaultArtifact(spImplAddr, "SuperPaymaster"); // AUD-4
        if (pntsAddr != address(0)) {
            address anni = vm.addr(vm.envUint("PRIVATE_KEY_ANNI"));
            _verifyV2Token(pntsAddr, v55.factory, anni, address(superPaymaster));
            _verifyOperatorV2(address(superPaymaster), anni, pntsAddr, anni);
        }
        _assertAllDefaultArtifacts();
        _generateConfig();
    }

    /// @notice T-4 closing check: every contract this script created — directly, through a
    ///         proxy, or as a factory clone — runs the profile.default bytes. View-only.
    function _assertAllDefaultArtifacts() internal view {
        console.log("=== T-4: all contracts == profile.default artifact ===");
        _requireDefaultProxy(address(registry), "Registry");
        _requireDefaultProxy(address(superPaymaster), "SuperPaymaster");
        _requireDefaultArtifact(address(xpntsFactory), "xPNTsFactory");
        if (_production()) _requireDefaultArtifact(address(apnts), "APNTsCapped");
        else require(
            _requireDefaultClone(address(apnts), "xPNTsToken") == xpntsFactory.implementation(),
            "T-4: aPNTs not a clone of the factory template"
        );
        _requireDefaultArtifact(address(gtoken), "GTokenAuthorization");
        _requireDefaultArtifact(address(staking), "GTokenStaking");
        _requireDefaultArtifact(address(mysbt), "MySBT");
        _requireDefaultArtifact(address(repSystem), "ReputationSystem");
        _requireDefaultArtifact(address(dvt), "DVTValidator");
        _requireDefaultArtifact(address(aggregator), "BLSAggregator");
        _requireDefaultArtifact(address(microPaymentCh), "MicroPaymentChannel");
        _requireDefaultArtifact(address(pmFactory), "PaymasterFactory");
        _requireDefaultArtifact(address(pmV4Impl), "Paymaster");
        address pmProxy = pmFactory.getPaymasterByOperator(deployer);
        if (pmProxy != address(0)) {
            require(
                _requireDefaultClone(pmProxy, "Paymaster") == address(pmV4Impl), "T-4: V4 proxy not a clone of pmV4Impl"
            );
            require(pmFactory.implementations("v4.2") == address(pmV4Impl), "T-4: factory v4.2 != pmV4Impl");
        }
        _requireDefaultArtifact(x402FacilitatorAddr, "X402Facilitator");
        _requireDefaultArtifact(policyRegistryAddr, "PolicyRegistry");
        _requireDefaultArtifact(timelockControllerAddr, "TimelockController");
        _verifyV55Stack(v55, address(superPaymaster), address(registry)); // the 7 v5.5.0 contracts
        if (pntsAddr != address(0)) {
            require(
                _requireDefaultClone(pntsAddr, "xPNTsTokenV2") == v55.impl, "T-4: PNTs not a clone of the v2 template"
            );
        }
    }

    function xPNTsFactoryV2Owner() internal view returns (address) {
        return Ownable(v55.factory).owner();
    }

    function aoaRegistryOwner() internal view returns (address) {
        return Ownable(v55.aoaRegistry).owner();
    }

    /// @dev Transfers BLSAggregator and DVTValidator ownership to the same
    ///      `GOVERNANCE_OWNER`. DVT rotation remains immediate: it adds no power beyond
    ///      the owner's direct verifyAndExecute route, and DVT paths still require a BLS
    ///      quorum. Verifier rotation keeps its contract-enforced delay. Unset is the
    ///      normal local path and is refused on a production chain by the governance gate.
    /// @dev The governance owner to hand BLSAggregator + DVTValidator to. Reads the
    ///      GOVERNANCE_OWNER gate; virtual only so a test harness can supply it without
    ///      mutating the process environment (vm.setEnv races other suites under parallel forge).
    function _governanceOwner() internal view virtual returns (address) {
        return GovernanceOwnerGate.declaredGovernanceOwner();
    }

    function _settleAggregatorGovernance() internal {
        address gov = _governanceOwner();
        if (gov == address(0)) return;
        aggregator.transferOwnership(gov);
        dvt.transferOwnership(gov);
        require(dvt.owner() == aggregator.owner(), "DeployLive: DVT owner != BLS owner");
        console.log("  BLSAggregator + DVTValidator ownership transferred to governance:", gov);
    }

    /// @dev Hands aPNTs and the xPNTsFactory to governance, with the same gate the
    ///      aggregator uses above. The token owners decide how much of the community
    ///      token can exist and what it is worth:
    ///
    ///        aPNTs.communityOwner   mint() is onlyFactoryOrOwner with NO cap check.
    ///                               issuanceCap is a view for DVT, not a mint gate,
    ///                               and stays unset until setIssuanceCap is called.
    ///        xPNTsFactory.owner     updateAPNTsPrice, setIndustryScaleUSD,
    ///                               setCapRatioBps and setTokenCategory are every
    ///                               input isOverIssued() reads.
    ///
    ///      So an EOA left here both mints without bound and grades its own
    ///      over-issuance. Both live examples came out of this path: OP mainnet aPNTs
    ///      0x0B41C780 (communityOwner 0x51Ac6949, an EOA, 1e24 mint simulates fine
    ///      against a 140,000 supply) and Sepolia aPNTs 0x696A7370 (communityOwner
    ///      0x51C00187, also an EOA).
    ///
    ///      Runs after the mint and all wiring, so nothing above becomes a governance
    ///      transaction. Unset GOVERNANCE_OWNER is the local path and a no-op, as for
    ///      the aggregator.
    function _settleTokenGovernance() internal {
        address gov = GovernanceOwnerGate.declaredGovernanceOwner();
        if (gov == address(0)) return;
        apnts.transferCommunityOwnership(gov);
        xpntsFactory.transferOwnership(gov);
        console.log("  aPNTs communityOwner transferred to governance:", gov);
        console.log("  xPNTsFactory ownership transferred to governance:", gov);
        // v5.5.0: the AOA registry is already sealed (step 4), so governance inherits only the
        // 48 h addition path and immediate revocation.
        Ownable(v55.factory).transferOwnership(gov);
        Ownable(v55.aoaRegistry).transferOwnership(gov);
        console.log("  xPNTsFactoryV2 + AOAProtocolRegistry ownership transferred to governance:", gov);
    }

    /// @dev Fresh timelock with governor proposer/executor/canceller and no external admin.
    function _deployPhase1Timelock(address governor, address guardian) internal returns (address) {
        address[] memory principals = new address[](1);
        principals[0] = governor;
        TimelockController timelock = TimelockController(payable(_deployDefault(
            "TimelockController", abi.encode(TIMELOCK_MIN_DELAY, principals, principals, address(0))
        )));
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "phase1: timelock self admin");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), governor), "phase1: governor is admin");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), guardian), "phase1: guardian is admin");
        return address(timelock);
    }

    /// @dev Deploy the three NEW v5.4 contracts and wire X402Facilitator on the
    ///      deployer-owned xPNTs tokens. Runs under the deployer broadcast (Step 8,
    ///      after all factory tokens exist). On a fresh GA deploy the deployer-owned
    ///      aPNTs clone is new-bytecode so the cap-setter wiring succeeds; community
    ///      operator tokens (Anni's PNTs) are skipped+logged and wired by prepare-test.
    function _deployV54Stack() internal {
        address governor = governorInput;
        address guardian = guardianInput;
        if (!_production()) (governor, guardian) = _resolveGovernance(deployer);
        // Production v5.4 is complete BEFORE the interruptible handover region.
        // Three v5.4 transactions, then four transfers precede CREATE TL.
        uint64 beforeV54 = vm.getNonce(deployer);
        uint64 expectedTimelockNonce = beforeV54 + 7;
        address timelock = _production() ? vm.computeCreateAddress(deployer, expectedTimelockNonce)
            : _deployPhase1Timelock(governor, guardian);
        if (_production()) _resolveOwnerChoices(timelock);
        V54Addresses memory v54 = _deployV54Contracts(
            address(registry),
            address(superPaymaster),
            address(xpntsFactory),
            _production() ? resolvedOwners[1] : governor,
            guardian,
            timelock // fresh, self-administered timelock
        );
        x402FacilitatorAddr = v54.facilitator;
        policyRegistryAddr = v54.policyRegistry;
        timelockControllerAddr = v54.timelock;

        if (_production()) {
            require(vm.getNonce(deployer) == beforeV54 + 3, "handover: v54 nonce");
            require(_handoverProduction(expectedTimelockNonce, timelock) == timelock, "handover: predicted timelock");
        } else _wireFacilitator(address(xpntsFactory), x402FacilitatorAddr, deployer);
    }

    /// @notice Asserts every critical contract wiring link is intact.
    ///         Called at the end of run() — after all steps including Step 6
    ///         (aPNTs wired) and before vm.stopBroadcast() — so any silently
    ///         no-op setter reverts the entire deploy script rather than writing
    ///         broken addresses to the config file.  (Security fix: D-H4 / Issue #255 S3)
    /// @dev    All reads are view-only; no transactions are broadcast.
    function _assertWiring() internal view {
        // ── Step 1: Registry ↔ GTokenStaking ↔ MySBT ──────────────────────────
        require(address(registry.GTOKEN_STAKING()) == address(staking), "wire: registry.setStaking");
        require(address(registry.MYSBT()) == address(mysbt), "wire: registry.setMySBT");
        require(address(gtoken.mySBT()) == address(mysbt), "wire: gtoken.setMySBT");

        // ── Step 5: Registry ↔ core modules ────────────────────────────────────
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "wire: registry.setSuperPaymaster");
        _assertReputationSources();
        require(registry.blsAggregator() == address(aggregator), "wire: registry.setBLSAggregator");

        // ── Step 5: DVT / BLS cross-wiring ─────────────────────────────────────
        require(aggregator.DVT_VALIDATOR() == address(dvt), "wire: aggregator.setDVTValidator");
        require(dvt.BLS_AGGREGATOR() == address(aggregator), "wire: dvt.setBLSAggregator");
        // 5.5.0 ships an empty evidence allowlist: no slash-shape proposal can pass DVTValidator.
        require(dvt.categoryCount() == 0, "wire: dvt evidence allowlist must be empty in 5.5.0");

        // ── Step 5: PaymasterFactory implementation registration ────────────────
        require(address(pmFactory.registry()) == address(registry), "wire: factory.setRegistry");
        require(pmFactory.implementations("v4.2") == address(pmV4Impl), "wire: factory.addImplementation v4.2");

        // ── Step 5: SuperPaymaster ↔ xPNTsFactoryV2 (5.5.0) / 3.x factory ──────
        require(superPaymaster.xpntsFactory() == v55.factory, "wire: sp.setXPNTsFactory(factoryV2)");
        require(xpntsFactory.SUPERPAYMASTER() == address(superPaymaster), "wire: factory.setSuperPaymaster");

        // ── Step 5: Slasher authorization ───────────────────────────────────────
        // 5.5.0 is disclosure-only: the aggregator's only GToken-stake slash (guardian slash,
        // BLSAggregator.executeGuardianSlash) is unreachable while fraudProofVerifier == 0, so
        // the aggregator holds NO slasher role. Granting it is a 5.5.x enablement step that
        // must ship in the same timelock batch as proposeFraudProofVerifier.
        require(!staking.authorizedSlashers(address(aggregator)), "wire: aggregator must not be a staking slasher");

        // ── Step 5: SuperPaymaster BLS_AGGREGATOR ───────────────────────────────
        require(superPaymaster.BLS_AGGREGATOR() == address(aggregator), "wire: sp.initBLSAggregator");

        // ── Step 5: Price feed immutable (baked into SP implementation) ─────────
        require(address(superPaymaster.ETH_USD_PRICE_FEED()) == priceFeedAddr, "wire: sp.priceFeed");

        // ── Step 6: aPNTs ↔ SuperPaymaster ─────────────────────────────────────
        if (_production()) require(address(superPaymaster.APNTS_TOKEN()) == address(apnts), "wire: capped apnts binding");
        else require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "wire: apnts.setSuperPaymaster");
    }

    /// @dev Reputation sources are exactly ReputationSystem and the aggregator. The aggregator's
    ///      verifyAndExecute reputation branch (floor-checked) needs the role; the generic path can no
    ///      longer reach batchUpdateGlobalReputation (H-1 denylist). Registry.initialize makes its
    ///      owner (the deployer) a source (Registry.sol:172), so that grant is revoked here.
    function _wireReputationSources() internal {
        registry.setReputationSource(address(repSystem), true);
        registry.setReputationSource(address(aggregator), true);
        registry.setReputationSource(deployer, false);
    }

    /// @dev Same expectation as the Sepolia manifest (step 13): ReputationSystem and the aggregator are
    ///      sources; the deployer and every other address this script deploys or wires are not.
    function _assertReputationSources() internal view {
        require(registry.isReputationSource(address(repSystem)), "wire: registry.setReputationSource(repSystem)");
        require(registry.isReputationSource(address(aggregator)), "wire: registry.setReputationSource(aggregator)");
        address[22] memory notSources = [
            deployer, address(superPaymaster), spImplAddr, address(dvt), address(staking), address(mysbt),
            address(gtoken), address(xpntsFactory), address(registry), registryImplAddr, address(apnts),
            address(pmFactory), address(pmV4Impl), address(microPaymentCh), x402FacilitatorAddr,
            policyRegistryAddr, v55.factory, v55.impl, v55.ext, v55.lens, v55.tierSource, v55.aoaRegistry
        ];
        for (uint256 i; i < notSources.length; ++i) {
            if (notSources[i] == address(0)) continue;
            require(!registry.isReputationSource(notSources[i]), "wire: unexpected reputation source");
        }
    }

    function _executeWiring() internal {
        registry.setSuperPaymaster(address(superPaymaster));
        _wireReputationSources();
        registry.setBLSAggregator(address(aggregator));
        dvt.setBLSAggregator(address(aggregator));
        aggregator.setDVTValidator(address(dvt));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        if (_production()) pmFactory.setRegistry(address(registry));
        // 5.5.0 (runbook step 6): SP binds operators to tokens issued by xPNTsFactoryV2.
        _wireSPFactory(address(superPaymaster), v55.factory);
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));
        // Wire aPNTs (deployed before SP in Step 2, so SP address must be set retroactively).
        // setSuperPaymasterAddress also sets autoApprovedSpenders[SP] = true.
        if (!_production()) apnts.setSuperPaymasterAddress(address(superPaymaster));

        // Wire BLSAggregator into SuperPaymaster (Tier 1 slash authorization).
        // Uses initBLSAggregator() — a one-time setter that bypasses the 24h timelock
        // because BLS_AGGREGATOR is address(0) on a fresh deployment (no governance asset to protect).
        superPaymaster.initBLSAggregator(address(aggregator));

        // Integrity assertions moved to _assertWiring(), called at end of run()
        // before vm.stopBroadcast() — see D-H4 fix.

        // ERC-8004 official agent registry addresses (CREATE2, deterministic across all EVM chains).
        // Mainnet chains: Ethereum, OP, Base, Arbitrum, Polygon, etc.
        // Testnet chains:  Sepolia, OP Sepolia, Base Sepolia, Arbitrum Sepolia, Polygon Amoy.
        // Override via AGENT_IDENTITY_REGISTRY / AGENT_REPUTATION_REGISTRY env vars if needed.
        address erc8004Identity;
        address erc8004Reputation;
        uint256 cid = block.chainid;
        bool isMainnet =
            (cid == 1 || cid == 10 || cid == 137 || cid == 8453 || cid == 42161 || cid == 43114 || cid == 56
                || cid == 534352);
        bool isTestnet = (cid == 11155111 || cid == 11155420 || cid == 84532 || cid == 421614 || cid == 80002);
        if (isMainnet) {
            erc8004Identity = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
            erc8004Reputation = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
            erc8004Validation = 0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58;
        } else if (isTestnet) {
            erc8004Identity = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
            erc8004Reputation = 0x8004B663056A597Dffe9eCcC1965A193B7388713;
            erc8004Validation = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;
        }
        if (_production()) {
            string memory deps = _externalDependencies();
            bool enabled;
            (enabled, erc8004Identity, erc8004Reputation) = _agentRegistryInputs();
            console.log("  ENABLE_AGENT_REGISTRIES:", enabled);
            console.log("  AGENT_IDENTITY_REGISTRY:", erc8004Identity);
            console.log("  AGENT_REPUTATION_REGISTRY:", erc8004Reputation);
            erc8004Validation = enabled ? vm.parseJsonAddress(deps, ".agentValidationRegistry") : address(0);
        } else {
        // Local legacy path only.
        erc8004Identity = vm.envOr("AGENT_IDENTITY_REGISTRY", erc8004Identity);
        erc8004Reputation = vm.envOr("AGENT_REPUTATION_REGISTRY", erc8004Reputation);
        erc8004Validation = vm.envOr("AGENT_VALIDATION_REGISTRY", erc8004Validation);
        }
        if (erc8004Identity != address(0) && erc8004Reputation != address(0)) {
            superPaymaster.setAgentRegistries(erc8004Identity, erc8004Reputation);
            console.log("  Agent registries wired (explicit production opt-in)");
            console.log("    identity:   ", erc8004Identity);
            console.log("    reputation: ", erc8004Reputation);
            console.log("    validation: ", erc8004Validation, " (recorded, not wired to SP yet)");
        } else {
            console.log("  Agent registries disabled (a=0)");
        }

        // Oracle Init
        if (_production()) superPaymaster.updatePrice();
        else try AggregatorV3Interface(priceFeedAddr).latestRoundData() returns (
            uint80, int256 price, uint256, uint256, uint80
        ) {
            try SuperPaymasterAdmin(address(superPaymaster)).updatePriceDVT(price, block.timestamp, "", 0) { // D5b: extension function
                console.log("  Cache Price Force-Initialized");
            } catch {
                superPaymaster.updatePrice();
            }
        } catch {}

        // Step 24 & 25: 0.1 ETH
        if (!_production()) {
            superPaymaster.deposit{value: 0.1 ether}();
            superPaymaster.addStake{value: 0.1 ether}(1 days);
        }
    }

    function _orchestrateRolesJason() internal {
        // COMMUNITY registration and aPNTs deployment already done in Step 2 of run().
        // aPNTs is wired to SuperPaymaster in _executeWiring().
        console.log("  aPNTs:", address(apnts), "SP:", address(superPaymaster));
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "Deploy: aPNTs SP wiring failed!");

        // Step 31-36: AOA Paymaster
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)",
            entryPointAddr,
            deployer,
            deployer,
            priceFeedAddr,
            100,
            1 ether,
            4200
        );
        address pmProxy = pmFactory.deployPaymaster("v4.2", init);
        Paymaster(payable(pmProxy)).addStake{value: 0.1 ether}(86400); // Increased to 0.1 ETH as requested
        Paymaster(payable(pmProxy)).updatePrice();
        // Step 34: $0.02
        Paymaster(payable(pmProxy)).setTokenPrice(address(apnts), 2_000_000);

        gtoken.approve(address(staking), 33 ether);
        registry.registerRole(ROLE_PAYMASTER_AOA, deployer, abi.encode(uint256(30 ether)));
        pmFactory.setRegistry(address(registry));

        // Step 37: 0.05 ETH
        IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxy);

        // Step 38: Mint 20,000 aPNTs
        apnts.mint(deployer, 20_000 ether);
    }

    function _setupMyceliumCommunity() internal {
        uint256 anniPK = vm.envUint("PRIVATE_KEY_ANNI");
        address anni = vm.addr(anniPK);
        console.log("  Anni (Mycelium Admin):", anni);

        // --- Deployer prepares Anni (safeMintForRole = deployer pays stake) ---

        // 6a. Register Mycelium as COMMUNITY (deployer pays 30 stake + burn)
        if (!registry.hasRole(ROLE_COMMUNITY, anni)) {
            gtoken.approve(address(staking), 34 ether);
            Registry.CommunityRoleData memory mycData = Registry.CommunityRoleData({
                name: "Mycelium Community", ensName: "mushroom.box", stakeAmount: 30 ether
            });
            registry.safeMintForRole(ROLE_COMMUNITY, anni, abi.encode(mycData));
            console.log("  Mycelium Community Registered");
        } else {
            console.log("  Mycelium Community (skip - already registered)");
        }

        // 6b. Register as PAYMASTER_SUPER (deployer pays 50 stake + burn)
        if (!registry.hasRole(ROLE_PAYMASTER_SUPER, anni)) {
            gtoken.approve(address(staking), 56 ether);
            registry.safeMintForRole(ROLE_PAYMASTER_SUPER, anni, "");
            console.log("  Mycelium PAYMASTER_SUPER Registered");
        } else {
            console.log("  Mycelium PAYMASTER_SUPER (skip - already registered)");
        }

        // 6c. Fund Anni with aPNTs for SuperPaymaster deposit
        if (apnts.balanceOf(anni) < 1000 ether) {
            apnts.transfer(anni, 1000 ether);
            console.log("  1000 aPNTs transferred to Anni");
        } else {
            console.log("  Anni aPNTs (skip - sufficient balance)");
        }

        // --- Switch to Anni broadcast for operator-specific calls ---
        vm.stopBroadcast();
        vm.startBroadcast(anniPK);

        // 6d. Deploy PNTs (Mycelium community token — special token name).
        //     5.5.0: an xPNTs v2 token from xPNTsFactoryV2 (SP rejects 3.x tokens).
        pntsAddr = _issueV2Token(v55.factory, anni, "Mycelium PNTs", "PNTs", "Mycelium Community", "mushroom.box", 1e18);

        // 6e. Configure Anni as SuperPaymaster operator (idempotent; re-binds a stale token)
        _configureOperatorV2(address(superPaymaster), pntsAddr, anni, anni);
        console.log("  Operator Configured (PNTs v2 -> SuperPaymaster)");

        // 6f. Deposit aPNTs into SuperPaymaster (gasless sponsorship fund)
        (uint128 bal,,,,,,,,) = superPaymaster.operators(anni);
        if (bal < 100 ether) {
            apnts.approve(address(superPaymaster), 1000 ether);
            superPaymaster.deposit(1000 ether);
            console.log("  1000 aPNTs Deposited to SuperPaymaster");
        } else {
            console.log("  SuperPaymaster deposit (skip - sufficient balance)");
        }

        // 6g. Mint PNTs for test users
        if (IxPNTsV2Script(pntsAddr).balanceOf(anni) < 500 ether) {
            IxPNTsV2Script(pntsAddr).mint(anni, 500 ether); // v2: mint is served by the extension
            console.log("  500 PNTs Minted to Anni");
        } else {
            console.log("  Anni PNTs (skip - sufficient balance)");
        }

        // --- Switch back to deployer ---
        vm.stopBroadcast();
        vm.startBroadcast();
    }

    function _mintGToken(uint256 amount) internal {
        mintRecipients.push(deployer); mintAmounts.push(amount);
        gtoken.mint(deployer, amount);
    }
    function _recordRegistration(address account, bytes32 role) internal {
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(role);
        stakeAccounts.push(account); stakeRoles.push(role); stakeAmounts.push(cfg.minStake);
        ticketAmounts.push(cfg.ticketPrice); ticketTreasuries.push(staking.treasury());
    }
    function _registerProductionGuardians() internal {
        _mintGToken(nInput * 33 ether + 100 ether);
        gtoken.approve(address(staking), type(uint256).max);
        _recordRegistration(genesisInput, ROLE_COMMUNITY);
        registry.safeMintForRole(ROLE_COMMUNITY, genesisInput,
            abi.encode(Registry.CommunityRoleData("AAStar", "aastar.eth", 0)));
        _recordRegistration(genesisInput, ROLE_PAYMASTER_SUPER);
        registry.safeMintForRole(ROLE_PAYMASTER_SUPER, genesisInput, "");
        for (uint256 i; i < guardiansInput.length; ++i) {
            GuardianInput memory g = guardiansInput[i];
            _recordRegistration(g.account, ROLE_DVT);
            registry.safeMintForRole(ROLE_DVT, g.account, "");
            dvt.addValidator(g.account);
            dvt.registerBLSPublicKey(g.account, g.key, uint8(i + 1), g.pop);
        }
        // Lower min first, raise default first: respect min <= default throughout.
        if (minInput < aggregator.minThreshold()) aggregator.setMinThreshold(minInput);
        aggregator.setDefaultThreshold(defaultInput);
        aggregator.setMinThreshold(minInput);
        for (uint8 i; i < 3; ++i) aggregator.setSlashThreshold(i, uint8(slashInput[i]));
        registry.exitRole(ROLE_COMMUNITY);
    }

    function _popRequestCommit() internal view virtual returns (string memory) {
        return vm.envOr("SP_COMMIT", string(""));
    }

    function _popBroadcastContext() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _writePopRequest() internal {
        vm.serializeAddress("pop-addresses", "BLSAggregator", address(aggregator));
        vm.serializeAddress("pop-addresses", "DVTValidator", address(dvt));
        string memory addresses = vm.serializeAddress("pop-addresses", "Registry", address(registry));
        vm.serializeAddress("pop-deployer", "address", deployer);
        string memory sender = vm.serializeUint("pop-deployer", "nonce", popStartNonce);
        string memory senders = vm.serializeString("pop-senders", "deployer", sender);
        // pin.block and pin.blockHash name the SAME block: the parent of the simulated block (EVM
        // BLOCKHASH cannot read the current one). The deployer nonce is the one at run() entry; if the
        // deployer sent a transaction in the latest block, DVT's nonce-at-pin check refuses (fail-closed).
        vm.serializeUint("pop-pin", "block", deploymentStartBlock == 0 ? 0 : deploymentStartBlock - 1);
        vm.serializeBytes32("pop-pin", "blockHash", popStartBlockHash);
        string memory pin = vm.serializeString("pop-pin", "senders", senders);
        vm.serializeString("pop-request", "schema", "deploylive-pop-request/1");
        vm.serializeUint("pop-request", "chainId", block.chainid);
        vm.serializeString("pop-request", "spCommit", popCommit);
        vm.serializeString("pop-request", "addresses", addresses);
        vm.serializeString("pop-request", "pin", pin);
        vm.writeJson(vm.serializeUint("pop-request", "guardianCount", _requiredUint("GUARDIAN_N")), popRequestOut);
    }

    function _twoStepTargets() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = address(registry); a[1] = address(superPaymaster); a[2] = address(apnts);
    }

    function _singleStepTargets() internal view returns (address[10] memory) {
        return [address(staking), address(repSystem), address(aggregator), address(dvt), address(xpntsFactory),
            address(pmFactory), address(pmV4Impl), address(microPaymentCh), v55.factory, v55.aoaRegistry];
    }

    function _singleStepOwners(address tl) internal view returns (address[10] memory) {
        return [tl, resolvedOwners[2], safeInput, safeInput, safeInput,
            resolvedOwners[4], resolvedOwners[4], resolvedOwners[3], safeInput, safeInput];
    }

    function _fixedHandoverCalls(address tl) internal view returns (address[] memory targets, bytes[] memory data) {
        bytes32[7] memory roles = [ROLE_COMMUNITY, ROLE_ENDUSER, ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER, ROLE_DVT, ROLE_ANODE, ROLE_KMS];
        address[10] memory singles = _singleStepTargets();
        address[10] memory owners = _singleStepOwners(tl);
        address[] memory nominations = _twoStepTargets();
        targets = new address[](roles.length + singles.length + 1 + nominations.length);
        data = new bytes[](targets.length);
        uint256 n;
        for (uint256 i; i < roles.length; ++i) {
            IRegistry.RoleConfig memory cfg = registry.getRoleConfig(roles[i]);
            cfg.owner = tl;
            targets[n] = address(registry); data[n++] = abi.encodeCall(registry.configureRole, (roles[i], cfg));
        }
        targets[n] = address(aggregator); data[n++] = abi.encodeCall(aggregator.setSlashPolicyAdmin, (resolvedOwners[0]));
        for (uint256 i; i < singles.length; ++i) {
            targets[n] = singles[i]; data[n++] = abi.encodeWithSignature("transferOwnership(address)", owners[i]);
        }
        for (uint256 i; i < nominations.length; ++i) {
            targets[n] = nominations[i]; data[n++] = abi.encodeWithSignature("transferOwnership(address)", tl);
        }
        assert(n == targets.length);
    }

    function _handoverProduction(uint64 expectedNonce, address expectedAddress) internal returns (address) {
        superPaymaster.setGuardian(spGuardianInput);
        mysbt.setDAOMultisig(safeInput);
        gtoken.transferOwnership(safeInput);
        ticketsToTreasury = gtoken.balanceOf(safeInput) - treasuryGTokenBefore;
        gtokenRecipientBefore = gtoken.balanceOf(gtokenRecipient);
        gtokenTransferred = gtoken.balanceOf(deployer);
        require(gtoken.transfer(gtokenRecipient, gtokenTransferred), "handover: GToken transfer");
        uint64 tlNonce = vm.getNonce(deployer);
        require(tlNonce == expectedNonce, "handover: timelock nonce");
        address tl = vm.computeCreateAddress(deployer, tlNonce);
        require(tl == expectedAddress, "handover: predicted timelock before CREATE");
        _resolveOwnerChoices(tl);
        (address[] memory targets, bytes[] memory data) = _fixedHandoverCalls(tl);
        bootstrapNonce = uint256(tlNonce) + 1 + targets.length;
        bootstrapAddr = vm.computeCreateAddress(deployer, bootstrapNonce);
        address[] memory principals = new address[](1);
        principals[0] = bootstrapAddr;
        _requireUndelegatedDeployer();
        TimelockController t = TimelockController(payable(_deployDefault(
            "TimelockController", abi.encode(uint256(0), principals, principals, address(0)))));
        require(address(t) == tl, "handover: timelock address");
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory reason) = targets[i].call(data[i]);
            if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
        }
        observedBootstrapNonce = vm.getNonce(deployer);
        require(observedBootstrapNonce == bootstrapNonce, "handover: bootstrap nonce");
        require(vm.computeCreateAddress(deployer, observedBootstrapNonce) == bootstrapAddr, "handover: predicted H before CREATE");
        if (!_stopBeforeBootstrap()) {
            _requireUndelegatedDeployer();
            require(address(new TimelockHandoverBootstrap(t, _twoStepTargets(), safeInput)) == bootstrapAddr, "handover: bootstrap address");
        }
        timelockControllerAddr = tl;
        return tl;
    }

    function _handoverSubjects() internal view returns (address[] memory subjects) {
        subjects = new address[](guardiansInput.length + 6);
        subjects[0] = deployer; subjects[1] = bootstrapAddr; subjects[2] = governorInput;
        subjects[3] = guardianInput; subjects[4] = spGuardianInput; subjects[5] = genesisInput;
        for (uint256 i; i < guardiansInput.length; ++i) subjects[i + 6] = guardiansInput[i].account;
    }

    function _assertHandover() internal view {
        require(mysbt.balanceOf(deployer) == 0, "handover: deployer SBT balance");
        require(!registry.pendingSBTBurn(deployer), "handover: pending SBT burn");
        require(PolicyRegistry(policyRegistryAddr).timelock() == timelockControllerAddr, "handover: policy timelock");
        require(PolicyRegistry(policyRegistryAddr).guardian() == guardianInput, "handover: policy guardian");
        TimelockHandover.assertFinal(TimelockController(payable(timelockControllerAddr)), _twoStepTargets(), safeInput, _handoverSubjects());
        _validateSafe(deployer);
        require(gtoken.allowance(deployer, address(staking)) == 0, "handover: deployer allowance");
        require(bootstrapAddr.codehash == keccak256(type(TimelockHandoverBootstrap).runtimeCode), "handover: callable bootstrap");
        require(Ownable(x402FacilitatorAddr).owner() == resolvedOwners[1], "handover: facilitator owner");
        address[10] memory singles = _singleStepTargets();
        address[10] memory owners = _singleStepOwners(timelockControllerAddr);
        for (uint256 i; i < singles.length; ++i) require(Ownable(singles[i]).owner() == owners[i], "handover: single owner");
        address[5] memory gated = [address(aggregator), address(dvt), address(xpntsFactory), v55.factory, v55.aoaRegistry];
        for (uint256 i; i < gated.length; ++i) {
            address owner = Ownable(gated[i]).owner();
            (bool ok,,) = GovernanceOwnerGate.readMofN(owner);
            require(owner == safeInput && ok && owner.code.length > 0 && bytes3(owner.code) != 0xef0100, "handover: Safe owner gate");
        }
        uint256 minted;
        for (uint256 i; i < mintAmounts.length; ++i) minted += mintAmounts[i];
        require(gtoken.totalSupply() == minted, "handover: mint accounting");
        uint256 locked;
        uint256 tickets;
        for (uint256 i; i < stakeAccounts.length; ++i) {
            require(staking.getLockedStake(stakeAccounts[i], stakeRoles[i]) == stakeAmounts[i], "handover: stake accounting");
            require(ticketTreasuries[i] == safeInput, "handover: ticket treasury");
            locked += stakeAmounts[i];
            tickets += ticketAmounts[i];
        }
        require(gtoken.balanceOf(address(staking)) == locked && minted == locked + ticketsToTreasury + gtokenTransferred, "handover: GToken conservation");
        require(ticketsToTreasury == tickets && gtoken.balanceOf(safeInput) == treasuryGTokenBefore + ticketsToTreasury + (gtokenRecipient == safeInput ? gtokenTransferred : 0), "handover: treasury tickets");
        require(gtoken.balanceOf(deployer) == 0, "handover: deployer GToken balance");
        require(gtoken.balanceOf(gtokenRecipient) == gtokenRecipientBefore + gtokenTransferred, "handover: recipient GToken delta");
        bytes32[7] memory roles = [ROLE_COMMUNITY, ROLE_ENDUSER, ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER, ROLE_DVT, ROLE_ANODE, ROLE_KMS];
        for (uint256 i; i < roles.length; ++i) {
            require(registry.getRoleConfig(roles[i]).owner == timelockControllerAddr, "handover: role owner");
            require(!registry.hasRole(roles[i], deployer), "handover: deployer registry role");
        }
        require(registry.getUserRoles(deployer).length == 0, "handover: deployer roles");
        require(!dvt.isValidator(deployer) && !registry.isReputationSource(deployer), "handover: deployer privilege");
        require(gtoken.owner() == safeInput && mysbt.daoMultisig() == safeInput, "handover: safe ownership");
        require(superPaymaster.treasury() == safeInput && staking.treasury() == safeInput, "handover: treasury");
        require(superPaymaster.guardian() == spGuardianInput, "handover: SP guardian");
        require(aggregator.slashPolicyAdmin() == resolvedOwners[0], "handover: slash admin");
        require(aggregator.minThreshold() == minInput && aggregator.defaultThreshold() == defaultInput, "handover: thresholds");
        for (uint8 i; i < 3; ++i) require(aggregator.slashThresholds(i) == slashInput[i], "handover: slash thresholds");
        for (uint256 i; i < nInput; ++i) require(aggregator.validatorAtSlot(uint8(i + 1)) == guardiansInput[i].account, "handover: guardian slot");
        require(APNTsCapped(address(apnts)).cap() == capInput, "handover: cap");
        require(APNTsCapped(address(apnts)).minter() == safeInput && APNTsCapped(address(apnts)).capGuardian() == safeInput, "handover: cap roles");
        require(superPaymaster.priceStalenessThreshold() == 4200, "handover: staleness");
        (, bool configured,,,,,,,) = superPaymaster.operators(genesisInput);
        require(!configured && registry.hasRole(ROLE_PAYMASTER_SUPER, genesisInput) && registry.hasRole(ROLE_COMMUNITY, genesisInput), "handover: genesis operator");
    }

    function _recordImplementationOwner(string memory object, string memory key, address implementation) internal {
        (bool ok, bytes memory value) = implementation.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && value.length == 32) vm.serializeAddress(object, key, abi.decode(value, (address)));
        else vm.serializeString(object, key, "N/A: no owner() getter");
    }

    function _configPath(string memory network) internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
    }

    function _generateConfig() internal {
        string memory network = vm.envString("ENV");
        string memory finalPath = _configPath(network);
        string memory jsonObj = "json";
        vm.serializeString(jsonObj, "artifactDirectory", vm.envOr("DEFAULT_ARTIFACTS_OUT", string("out")));
        vm.serializeString(jsonObj, "executionEvmVersion", vm.envOr("DEPLOYLIVE_EVM_VERSION", string("cancun")));
        vm.serializeBytes(jsonObj, "handoverCreationCode", abi.encodePacked(type(TimelockHandoverBootstrap).creationCode,
            abi.encode(TimelockController(payable(timelockControllerAddr)), _twoStepTargets(), safeInput)));
        vm.serializeUint(jsonObj, "deploymentStartBlock", deploymentStartBlock);
        vm.serializeAddress(jsonObj, "deployer", deployer);
        vm.serializeUint(jsonObj, "deployerCodeLength", deployer.code.length);
        if (_production()) vm.serializeString(jsonObj, "artifactCompileSettings", _artifactCompileSettings());
        vm.serializeAddress(jsonObj, "governanceOwner", safeInput);
        vm.serializeUint(jsonObj, "gTokenMintCount", mintAmounts.length);
        vm.serializeAddress(jsonObj, "gTokenMintRecipients", mintRecipients);
        vm.serializeUint(jsonObj, "gTokenMintAmounts", mintAmounts);
        vm.serializeUint(jsonObj, "gTokenTotalSupply", gtoken.totalSupply());
        vm.serializeAddress(jsonObj, "stakeAccounts", stakeAccounts);
        vm.serializeBytes32(jsonObj, "stakeRoles", stakeRoles);
        vm.serializeUint(jsonObj, "stakeAmounts", stakeAmounts);
        vm.serializeUint(jsonObj, "ticketAmounts", ticketAmounts);
        vm.serializeAddress(jsonObj, "ticketTreasuries", ticketTreasuries);
        if (_production()) vm.serializeBytes32(jsonObj, "creationPinsSha256", sha256(bytes(vm.readFile(vm.envString("CREATION_PINS")))));
        vm.serializeUint(jsonObj, "deployerGTokenBalance", gtoken.balanceOf(deployer));
        vm.serializeUint(jsonObj, "deployerGTokenAllowance", gtoken.allowance(deployer, address(staking)));
        vm.serializeUint(jsonObj, "deployerSBTBalance", mysbt.balanceOf(deployer));
        vm.serializeBool(jsonObj, "genesisIsConfigured", false);
        if (!_production()) vm.serializeAddress(jsonObj, "expectedGovernor", governorInput);
        for (uint256 i; i < 5; ++i) vm.serializeAddress(jsonObj, _ownerKey(i), resolvedOwners[i]);
        vm.serializeAddress(jsonObj, "deployerGTokenRecipient", gtokenRecipient);
        vm.serializeUint(jsonObj, "deployerGTokenTransferred", gtokenTransferred);
        vm.serializeUint(jsonObj, "deployerRemainderToRecipient", gtokenTransferred);
        vm.serializeUint(jsonObj, "ticketsToTreasury", ticketsToTreasury);
        vm.serializeUint(jsonObj, "treasuryGTokenBefore", treasuryGTokenBefore);
        vm.serializeUint(jsonObj, "deployerGTokenRecipientBefore", gtokenRecipientBefore);
        vm.serializeUint(jsonObj, "observedBootstrapNonce", observedBootstrapNonce);
        vm.serializeAddress(jsonObj, "registryImplOwner", Ownable(registryImplAddr).owner());
        vm.serializeAddress(jsonObj, "spImplOwner", Ownable(spImplAddr).owner());
        vm.serializeAddress(jsonObj, "paymasterV4ImplOwner", pmV4Impl.owner());
        vm.serializeAddress(jsonObj, "xPNTsTokenV1Impl", xpntsFactory.implementation());
        vm.serializeAddress(jsonObj, "spAdminImpl", superPaymaster.EXTENSION());
        _recordImplementationOwner(jsonObj, "spAdminImplOwner", superPaymaster.EXTENSION());
        _recordImplementationOwner(jsonObj, "xPNTsTokenV1ImplOwner", xpntsFactory.implementation());
        _recordImplementationOwner(jsonObj, "xPNTsTokenV2ImplOwner", v55.impl);
        _recordImplementationOwner(jsonObj, "xPNTsTokenV2ExtOwner", v55.ext);
        vm.serializeAddress(jsonObj, "expectedGuardian", guardianInput);
        vm.serializeAddress(jsonObj, "expectedSPGuardian", spGuardianInput);
        vm.serializeAddress(jsonObj, "genesisOperator", genesisInput);
        vm.serializeUint(jsonObj, "expectedCap", capInput);
        vm.serializeUint(jsonObj, "guardianN", nInput);
        vm.serializeUint(jsonObj, "minThreshold", minInput);
        vm.serializeUint(jsonObj, "defaultThreshold", defaultInput);
        for (uint256 i; i < 3; ++i) vm.serializeUint(jsonObj, string.concat("slashThreshold", vm.toString(i)), slashInput[i]);
        address[] memory gs = new address[](guardiansInput.length);
        for (uint256 i; i < gs.length; ++i) gs[i] = guardiansInput[i].account;
        vm.serializeAddress(jsonObj, "guardians", gs);
        vm.serializeAddress(jsonObj, "handoverBootstrap", bootstrapAddr);
        vm.serializeUint(jsonObj, "handoverBootstrapNonce", bootstrapNonce);
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(superPaymaster));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(pmFactory));
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        vm.serializeAddress(jsonObj, "simpleAccountFactory", simpleAccountFactory);
        vm.serializeAddress(jsonObj, "pnts", pntsAddr);
        // T-4 (Codex stop-review MEDIUM-7): the deployer's V4 (AOA) paymaster clone created in
        // _orchestrateRolesJason is a deployed contract too — record it so CheckDefaultArtifacts
        // verifies it (same key TestAccountPrepare writes).
        vm.serializeAddress(jsonObj, "aPNTsPaymasterV4", pmFactory.getPaymasterByOperator(deployer));
        // Record the production opt-in and the actual SP pointers.
        vm.serializeBool(jsonObj, "enableAgentRegistries", _production()
            ? _uintInput("ENABLE_AGENT_REGISTRIES") == 1
            : superPaymaster.agentIdentityRegistry() != address(0));
        // identity + reputation are wired into SuperPaymaster; validation is recorded for future use.
        vm.serializeAddress(
            jsonObj, "agentIdentityRegistry", SuperPaymaster(payable(address(superPaymaster))).agentIdentityRegistry()
        );
        vm.serializeAddress(
            jsonObj,
            "agentReputationRegistry",
            SuperPaymaster(payable(address(superPaymaster))).agentReputationRegistry()
        );
        vm.serializeAddress(jsonObj, "agentValidationRegistry", erc8004Validation);
        // UUPS implementation addresses — required for future upgrades via upgradeToAndCall()
        // and for audit-core's ERC-1967 implementation-slot verification.
        vm.serializeAddress(jsonObj, "spImpl", spImplAddr);
        vm.serializeAddress(jsonObj, "registryImpl", registryImplAddr);
        // MicroPaymentChannel — deployed in Step 4
        vm.serializeAddress(jsonObj, "microPaymentChannel", address(microPaymentCh));
        // v5.4 god-split contracts — deployed in Step 8
        vm.serializeAddress(jsonObj, "x402Facilitator", x402FacilitatorAddr);
        vm.serializeAddress(jsonObj, "policyRegistry", policyRegistryAddr);
        vm.serializeAddress(jsonObj, "timelockController", timelockControllerAddr);
        // v5.5.0 xPNTs v2 stack (NEW keys; "xPNTsFactory"/"aPNTs" keep their 3.x meaning)
        vm.serializeAddress(jsonObj, "aoaProtocolRegistry", v55.aoaRegistry);
        vm.serializeAddress(jsonObj, "globalTierSource", v55.tierSource);
        vm.serializeAddress(jsonObj, "xPNTsTokenV2Ext", v55.ext);
        vm.serializeAddress(jsonObj, "xPNTsTokenV2Impl", v55.impl);
        vm.serializeAddress(jsonObj, "xPNTsFactoryV2", v55.factory);
        vm.serializeAddress(jsonObj, "superPaymasterLens", v55.lens);
        // srcHash intentionally written as "" — deploy-core commits the real hash after audit-core passes.
        vm.serializeString(jsonObj, "srcHash", string(""));
        vm.serializeString(jsonObj, "commit", popCommit);
        vm.serializeString(jsonObj, "updateTime", vm.envOr("DEPLOY_TIME", string("N/A")));
        vm.serializeAddress(jsonObj, "priceFeed", priceFeedAddr);
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Live Phase 1 Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}
