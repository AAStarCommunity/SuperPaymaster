# Agent Commerce — Competitive Analysis & Strategic Bets

**Date**: 2026-06
**Status**: Internal strategy memo
**Subject**: AAStar (SuperPaymaster + AirAccount) vs. Alchemy AgentPay, and where durable value accrues in the emerging agent-commerce stack.

---

## 1. Executive summary

Alchemy's AgentPay is a **protocol-agnostic payment router** for AI agents. Crucially, it **holds no funds, does not settle, and punts on agent identity + authorization** — it routes a payment intent to whatever rail (x402, card, stablecoin) the merchant accepts. Its own published stack diagram names **SuperPaymaster at the gas layer and ERC-4337 Account Abstraction at the account layer** — i.e. it concedes the layer we occupy.

That concession is the whole memo. Routing is being commoditized; the wire-format war (x402) and the settlement-asset war (USDC) are effectively decided. The durable value is sinking to the **account + authorization layer** — exactly where AAStar sits. This memo argues for three strategic bets built on that thesis.

---

## 2. What AgentPay is (and is not)

| Dimension | AgentPay | Implication |
|-----------|----------|-------------|
| **Custody** | Holds no funds | Not a settlement party; cannot be the trust anchor for spend |
| **Settlement** | Does not settle | Delegates to rails (x402 / card / stablecoin) |
| **Agent identity** | Punts | No native answer to "which agent, acting for whom, under what mandate" |
| **Authorization** | Punts | No native answer to "is this spend authorized, and by whom" |
| **Core function** | Protocol-agnostic router | Maps a payment intent → an accepted rail |
| **Stated stack** | Names **SuperPaymaster** (gas) + **ERC-4337 AA** (account) | Concedes the account/gas layer to our category |

A router that holds no funds and refuses identity/authorization is a **thin, substitutable layer**. Its margin compresses as rails standardize. It is not a competitor to the account+authority layer — it is a **consumer** of one.

---

## 3. Our moats

1. **DVT threshold co-sign as decentralized spend-authority.**
   Spend authorization is enforced by a distributed-validator (DVT) threshold co-signature, not a single centralized signer. This is the decentralized analogue of the centralized spend authorities (Stripe / Visa) that today gate card rails — but without a single point of trust or censorship. "What a node enforced == what is punished" is encoded on-chain (see `PolicyRegistry` + slash path).

2. **Self-custody Account Abstraction.**
   The human owner retains custody; the agent operates under a **constrained session key** (target / selector / velocity / quota / recovery limits) at the account layer (AirAccount). The agent never holds the keys to the vault — it holds a leash. This is structurally safer than custodial agent wallets and is the credible answer to "what is this agent allowed to spend."

3. **PolicyRegistry — shared, on-chain, governance-gated spend policy.**
   A single on-chain source of truth for sender-keyed spend policy that staked consumers (SuperPaymaster, AirAccount) read during validation and that DVT nodes / the slash path reference. Policy evolves through governance (TimelockController + guardian), not opaque code upgrades. This makes authorization **portable across consumers** and **auditable**.

---

## 4. Industry convergence: the four-layer stack

The agent-commerce industry is converging on four layers:

1. **Identity** — which agent, acting for which principal.
2. **Verifiable spend authority** — is this spend authorized, by whom, under what mandate, enforceable + punishable.
3. **Settlement** — moving value.
4. **Reputation** — was the counterparty good; feed it back.

Where each layer is heading:

- **x402 won the wire-format.** Argue about headers no longer; build on it.
- **USDC won settlement.** The settlement-asset question is largely decided.
- **Routing commoditizes.** Thin, substitutable, margin-compressing (this is AgentPay).
- **Value sinks to the account + authority layer** — layers (1) and (2) — **where we sit.**

The strategic reading: do not fight the won wars (wire-format, settlement asset) and do not fight in the commoditizing layer (routing). Concentrate on the layer accruing value: account + verifiable spend authority, plus the reputation loop that closes it.

---

## 5. Three strategic bets

### Bet 1 — Own the "verifiable decentralized spend authority" category *(highest conviction)*

Make AAStar synonymous with **verifiable, decentralized, enforceable spend authority** for agents: DVT threshold co-sign + on-chain PolicyRegistry + slash-backed enforcement. This is the layer everyone else punts on (AgentPay explicitly) and the layer where centralized incumbents (Stripe/Visa) are structurally unable to be decentralized. This is the category to own.

### Bet 2 — Be the account + authorization layer routers plug into (don't compete as a router)

Do **not** build a competing router. Be the account+authorization substrate that AgentPay-style routers route *into*. Routers want a trustworthy, standards-aligned account layer with built-in spend constraints; provide it (AirAccount + SuperPaymaster + PolicyRegistry) and let the routers commoditize each other on top. Their own stack diagram already names us — lean into being the named layer.

### Bet 3 — Ship the first real on-chain ERC-8004 agent identity + reputation loop

Close the loop with a **production** ERC-8004 agent identity + reputation feedback cycle: registered agent identity → sponsored / settled action → on-chain reputation feedback → reputation-gated policy. Being first with a *real* (not whitepaper) loop establishes layers (1) and (4) of the convergence stack and compounds the moat: reputation feeds policy, policy gates authority, authority is what routers depend on.

---

## 6. One-line thesis

**Routing commoditizes; x402 and USDC settled the wire-format and settlement-asset wars; the durable value sinks to the account + verifiable-spend-authority layer — and that is the layer AAStar already occupies and competitors concede.**
