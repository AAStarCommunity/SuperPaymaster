// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IEntryPoint} from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {SimpleAccount} from "@account-abstraction-v7/samples/SimpleAccount.sol";
import {SimpleAccountFactory} from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import {MessageHashUtils} from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

import {V55Bootstrap, IxPNTsV2Script} from "./V55Bootstrap.sol";

interface IRegistryL4 {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external returns (uint256);
}

interface IGTokenL4 {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ISPL4 {
    function version() external view returns (string memory);
    function updatePrice() external;
    function sbtHolders(address) external view returns (bool);
    function protocolRevenue() external view returns (uint256);
    function inflightOf(bytes32 opHash) external view returns (address operator, uint256 a0);
    function operators(address operator) external view returns (
        uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken,
        uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored
    );
}

interface ILensL4 {
    function dryRunValidation(address sp, PackedUserOperation calldata userOp, uint256 maxCost)
        external view returns (bool ok, bytes32 reasonCode);
}

/**
 * @title L4GaslessTest
 * @notice One REAL gasless balance-mode UserOperation through the EntryPoint against a deployed
 *         SuperPaymaster 5.5.0 stack, with the 5.5.0 paymasterAndData layout
 *         [pm 20][verifGas 16][postOpGas 16][operator 20][maxRate 32][token 20][flags 1],
 *         then READ BACK the settlement:
 *           - the user's xPNTs balance fell (burned > 0),
 *           - lockedOf(user) == 0 (escrow fully released by settleLocked),
 *           - operator aPNTsBalance decrease == protocolRevenue increase (> 0) (R10-M1b),
 *           - usedOpHashes[opHash] == true and SP's in-flight record is cleared.
 *
 *         Rewritten for D5.2: the previous version targeted OP mainnet (config.op-mainnet.json
 *         with a `.contracts.*` shape that no longer exists), built the 5.4 paymasterAndData
 *         without the token/flags fields, and swallowed every failure in try/catch. Scenario T3
 *         (gasless SBT mint through SP) is dropped: an account without an SBT is not eligible for
 *         sponsorship, so that op can never validate.
 *
 * Config: deployments/config.<ENV>.json (ENV default "anvil"): entryPoint, superPaymaster,
 *         registry, gToken, staking, simpleAccountFactory, pnts (the operator's v2 token),
 *         superPaymasterLens (optional — used for a pre-flight dryRun).
 * Keys:   PRIVATE_KEY (bundler/beneficiary; anvil #0 default), PRIVATE_KEY_ANNI (operator +
 *         community; anvil #1 default), L4_USER_KEY (AA owner; anvil #3 default). Non-anvil
 *         networks must set all three explicitly.
 *
 * Run (anvil):
 *   ENV=anvil forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest \
 *     --rpc-url http://127.0.0.1:8545 --broadcast --slow --gas-estimate-multiplier 400 -vv
 *   The multiplier is REQUIRED: forge sizes the handleOps transaction from the gas the
 *   simulation used (~0.5M), but EntryPoint v0.7 innerHandleOp demands gasleft >= callGasLimit +
 *   paymasterPostOpGasLimit + overhead before executing, so an estimate-sized tx fails on chain
 *   with AA95 out of gas while the simulation passed. A bundler sizes it from the op's limits.
 *   # then re-read the result from chain state (no broadcast):
 *   ENV=anvil forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest \
 *     --sig "verify()" --rpc-url http://127.0.0.1:8545 -vv
 */
contract L4GaslessTest is V55Bootstrap {
    bytes32 internal constant ROLE_ENDUSER_L4 = keccak256("ENDUSER");
    uint256 internal constant ANVIL_DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_ANNI_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ANVIL_USER_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    struct Cfg {
        address entryPoint;
        address sp;
        address registry;
        address gToken;
        address staking;
        address accountFactory;
        address token;
        address lens;
    }

    struct Snap {
        uint256 userBal;
        uint256 locked;
        uint256 opBal;
        uint256 revenue;
        uint256 nonce;
    }

    function _cfg() internal view returns (Cfg memory c, string memory network) {
        network = vm.envOr("ENV", string("anvil"));
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", network, ".json"));
        c.entryPoint = vm.parseJsonAddress(json, ".entryPoint");
        c.sp = vm.parseJsonAddress(json, ".superPaymaster");
        c.registry = vm.parseJsonAddress(json, ".registry");
        c.gToken = vm.parseJsonAddress(json, ".gToken");
        c.staking = vm.parseJsonAddress(json, ".staking");
        c.accountFactory = vm.parseJsonAddress(json, ".simpleAccountFactory");
        c.token = vm.parseJsonAddress(json, ".pnts");
        c.lens = _optAddrV55(json, ".superPaymasterLens");
    }

    function _keys(string memory network) internal view returns (uint256 bundlerPk, uint256 anniPk, uint256 userPk) {
        bool isAnvil = _strEq(network, "anvil");
        if (!isAnvil) {
            require(
                vm.envOr("PRIVATE_KEY", uint256(0)) != 0 && vm.envOr("PRIVATE_KEY_ANNI", uint256(0)) != 0
                    && vm.envOr("L4_USER_KEY", uint256(0)) != 0,
                "L4: set PRIVATE_KEY, PRIVATE_KEY_ANNI and L4_USER_KEY for non-anvil networks"
            );
        }
        bundlerPk = vm.envOr("PRIVATE_KEY", ANVIL_DEPLOYER_PK);
        anniPk = vm.envOr("PRIVATE_KEY_ANNI", ANVIL_ANNI_PK);
        userPk = vm.envOr("L4_USER_KEY", ANVIL_USER_PK);
    }

    function _outPath(string memory network) internal view returns (string memory) {
        return vm.envOr("L4_OUT", string.concat(vm.projectRoot(), "/cache/l4-gasless.", network, ".json"));
    }

    function run() external {
        (Cfg memory c, string memory network) = _cfg();
        (uint256 bundlerPk, uint256 anniPk, uint256 userPk) = _keys(network);
        address anni = vm.addr(anniPk);
        address bundler = vm.addr(bundlerPk);

        console.log("-----------------------------------------");
        console.log("L4 Gasless (balance mode) on", network);
        console.log("-----------------------------------------");
        require(_strEq(ISPL4(c.sp).version(), SP_V55_VERSION), "L4: SP is not 5.5.0");
        (,,, address opToken,,,,,) = ISPL4(c.sp).operators(anni);
        require(opToken == c.token, "L4: config.pnts is not the operator's configured token");
        require(IxPNTsV2Script(c.token).BALANCE_MODE_VERSION() == 1, "L4: operator token is not v2");

        // --- 1. AA account (idempotent) ---
        address account = SimpleAccountFactory(c.accountFactory).getAddress(vm.addr(userPk), 0);
        vm.startBroadcast(bundlerPk);
        if (account.code.length == 0) SimpleAccountFactory(c.accountFactory).createAccount(vm.addr(userPk), 0);
        if (IGTokenL4(c.gToken).balanceOf(anni) < 5 ether) {
            // anvil: the deployer owns GToken. Elsewhere Anni must already be funded.
            IGTokenL4(c.gToken).mint(anni, 10 ether);
        }
        ISPL4(c.sp).updatePrice(); // DSR D3 §8(a): fresh cache before validation
        vm.stopBroadcast();
        console.log("  AA account:", account);

        // --- 2. Eligibility (ENDUSER SBT) + funding in the operator's v2 token ---
        vm.startBroadcast(anniPk);
        if (!IRegistryL4(c.registry).hasRole(ROLE_ENDUSER_L4, account)) {
            IGTokenL4(c.gToken).approve(c.staking, 1 ether);
            IRegistryL4(c.registry).safeMintForRole(ROLE_ENDUSER_L4, account, abi.encode(anni, uint256(0.3 ether)));
        }
        if (IxPNTsV2Script(c.token).balanceOf(account) < 1000 ether) IxPNTsV2Script(c.token).mint(account, 1000 ether);
        vm.stopBroadcast();
        require(ISPL4(c.sp).sbtHolders(account), "L4: account is not an SBT holder after ENDUSER registration");

        // --- 3. Build + sign the UserOperation ---
        PackedUserOperation memory op;
        op.sender = account;
        op.nonce = IEntryPoint(c.entryPoint).getNonce(account, 0);
        // A zero-value call to Anni: the op's own execution never touches the xPNTs balance, so
        // the balance delta is exactly the settlement burn.
        op.callData = abi.encodeCall(SimpleAccount.execute, (anni, 0, ""));
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(300_000), uint128(100_000))); // verif | call
        op.preVerificationGas = 60_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(3 gwei))); // priority | max
        uint256 maxRate = IxPNTsV2Script(c.token).exchangeRate();
        op.paymasterAndData = _pmdV55(c.sp, 300_000, 300_000, anni, maxRate, c.token, 0);
        bytes32 opHash = IEntryPoint(c.entryPoint).getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, MessageHashUtils.toEthSignedMessageHash(opHash));
        op.signature = abi.encodePacked(r, s, v);

        if (c.lens != address(0)) {
            uint256 maxCost = (300_000 + 100_000 + 60_000 + 300_000 + 300_000) * 3 gwei;
            (bool ok, bytes32 reason) = ILensL4(c.lens).dryRunValidation(c.sp, op, maxCost);
            console.log("  lens.dryRunValidation ok:", ok);
            require(ok, string.concat("L4: lens dryRun rejected: ", string(abi.encodePacked(reason))));
        }

        // --- 4. Pre-snapshot, execute, read back ---
        Snap memory pre = _snap(c, anni, account);
        vm.startBroadcast(bundlerPk);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        IEntryPoint(c.entryPoint).handleOps(ops, payable(bundler));
        vm.stopBroadcast();
        Snap memory post = _snap(c, anni, account);

        _assertSettled(c, pre, post, account, opHash);
        _logSnap(pre, post);

        // Persist for verify(): the simulated outcome above is re-checked against live chain state.
        string memory k = "l4";
        vm.serializeAddress(k, "account", account);
        vm.serializeAddress(k, "operator", anni);
        vm.serializeAddress(k, "token", c.token);
        vm.serializeBytes32(k, "opHash", opHash);
        vm.serializeUint(k, "preUserBal", pre.userBal);
        vm.serializeUint(k, "preOpBal", pre.opBal);
        vm.serializeUint(k, "preRevenue", pre.revenue);
        vm.serializeUint(k, "preNonce", pre.nonce);
        vm.serializeUint(k, "postUserBal", post.userBal);
        vm.serializeUint(k, "postOpBal", post.opBal);
        string memory out = vm.serializeUint(k, "postRevenue", post.revenue);
        vm.writeJson(out, _outPath(network));
        console.log("  snapshot written:", _outPath(network));
    }

    /// @notice Re-read the settlement from LIVE chain state (run without --broadcast after run()).
    function verify() external view {
        (Cfg memory c, string memory network) = _cfg();
        string memory j = vm.readFile(_outPath(network));
        address account = vm.parseJsonAddress(j, ".account");
        address operator = vm.parseJsonAddress(j, ".operator");
        bytes32 opHash = vm.parseJsonBytes32(j, ".opHash");
        Snap memory pre = Snap({
            userBal: vm.parseJsonUint(j, ".preUserBal"),
            locked: 0,
            opBal: vm.parseJsonUint(j, ".preOpBal"),
            revenue: vm.parseJsonUint(j, ".preRevenue"),
            nonce: vm.parseJsonUint(j, ".preNonce")
        });
        Snap memory post = _snap(c, operator, account);
        // The pre-op state is deterministic, but the CHARGE is not: it is priced from the fee
        // EntryPoint actually charges (base fee at inclusion), which differs from the simulated
        // block. So the invariants are re-checked against the recorded pre-state on live chain
        // data, and the simulated figures are only logged for comparison.
        _assertSettled(c, pre, post, account, opHash);
        _logSnap(pre, post);
        console.log("  (simulated burn was", pre.userBal - vm.parseJsonUint(j, ".postUserBal"), ")");
        console.log("  L4 verify: settlement read back from chain state OK");
    }

    function _snap(Cfg memory c, address operator, address account) internal view returns (Snap memory s) {
        s.userBal = IxPNTsV2Script(c.token).balanceOf(account);
        s.locked = IxPNTsV2Script(c.token).lockedOf(account);
        (uint128 bal,,,,,,,,) = ISPL4(c.sp).operators(operator);
        s.opBal = bal;
        s.revenue = ISPL4(c.sp).protocolRevenue();
        s.nonce = IEntryPoint(c.entryPoint).getNonce(account, 0);
    }

    function _assertSettled(Cfg memory c, Snap memory pre, Snap memory post, address account, bytes32 opHash)
        internal
        view
    {
        require(post.nonce == pre.nonce + 1, "L4: UserOperation not executed (nonce unchanged)");
        require(post.userBal < pre.userBal, "L4: user xPNTs not burned");
        require(post.locked == 0, "L4: lockedOf(user) != 0 after settlement");
        require(IxPNTsV2Script(c.token).creditReservedOf(account) == 0, "L4: credit reservation left behind");
        require(post.opBal < pre.opBal, "L4: operator balance did not decrease");
        uint256 opDelta = pre.opBal - post.opBal;
        uint256 revDelta = post.revenue - pre.revenue;
        require(opDelta == revDelta, "L4: operator decrease != protocolRevenue increase");
        require(revDelta > 0, "L4: zero charge");
        require(IxPNTsV2Script(c.token).usedOpHashes(opHash), "L4: token did not mark the opHash settled");
        (address inflightOp, uint256 inflightA0) = ISPL4(c.sp).inflightOf(opHash);
        require(inflightOp == address(0) && inflightA0 == 0, "L4: SP in-flight record not cleared");
    }

    function _logSnap(Snap memory pre, Snap memory post) internal pure {
        console.log("  user xPNTs burned      :", pre.userBal - post.userBal);
        console.log("  lockedOf(user) after   :", post.locked);
        console.log("  operator aPNTs decrease:", pre.opBal - post.opBal);
        console.log("  protocolRevenue delta  :", post.revenue - pre.revenue);
    }
}
