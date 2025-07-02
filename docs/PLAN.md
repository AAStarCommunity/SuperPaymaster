# Super-Relay Development Plan

This document breaks down the features from `FEATURES.md` into a sequential development plan. We will follow these steps to build and integrate the `super-relay` functionality.

## Version 0.1.0

### Milestone 1: Project Scaffolding and Basic Integration

**Objective:** Set up the foundational structure of our `paymaster-relay` crate and integrate it into the `rundler` build process.

-   **Task 1.1: Create `paymaster-relay` Crate:**
    -   Inside `rundler/crates/`, create a new library crate named `paymaster-relay`.
    -   Add it to the main `rundler` workspace in `rundler/Cargo.toml`.
    -   Create the basic module files: `lib.rs`, `rpc.rs`, `service.rs`, `policy.rs`, `signer.rs`, `error.rs`.

-   **Task 1.2: Add CLI Configuration:**
    -   Modify `rundler/bin/rundler/src/cli/mod.rs`.
    -   Add a new `PaymasterOpts` struct with arguments like `--paymaster.enabled` and `--paymaster.policy-file`.
    -   Integrate `PaymasterOpts` into the main `RundlerOpts` struct.

-   **Task 1.3: Initial Integration into `main.rs`:**
    -   Modify `rundler/bin/rundler/src/main.rs`.
    -   Add placeholder logic: if `paymaster.enabled` is true, print a log message like "Paymaster Relay service is enabled."
    -   **Goal:** Ensure the new crate compiles and the new CLI flag is recognized without altering any behavior yet.

### Milestone 2: Implement Core Signing and RPC Logic

**Objective:** Implement the end-to-end flow for receiving, signing, and submitting a UserOperation.

-   **Task 2.1: Implement `SignerManager`:**
    -   In `paymaster-relay/src/signer.rs`, create the `SignerManager`.
    -   Implement logic to load a private key from an environment variable (e.g., `PAYMASTER_PRIVATE_KEY`).
    -   Implement the `sign_user_op_hash` method.

-   **Task 2.2: Implement `PaymasterRelayApi` Trait:**
    -   In `paymaster-relay/src/rpc.rs`, define the `PaymasterRelayApi` trait using `jsonrpsee::proc_macros::rpc`.
    -   Define the `pm_sponsorUserOperation` method signature.

-   **Task 2.3: Implement `PaymasterRelayService`:**
    -   In `paymaster-relay/src/service.rs`, create the `PaymasterRelayService` struct. It will hold instances of the `SignerManager` and (later) the `PolicyEngine`.
    -   Implement the `sponsor_user_operation` business logic. For now, it will:
        1.  Accept a `UserOperation`.
        2.  (Skip policy check for now).
        3.  Calculate the `userOpHash`.
        4.  Call the `SignerManager` to get a signature.
        5.  Construct the `paymasterAndData` field.
        6.  Return the modified `UserOperation`.

-   **Task 2.4: Integrate RPC into `rundler`:**
    -   Implement the `PaymasterRelayApiServer` trait for the `PaymasterRelayService`.
    -   In `rundler/crates/rpc/src/lib.rs`, add the `PaymasterRelayApiServer` to the `ApiSet` and merge it into the `jsonrpsee` module.
    -   In `rundler/bin/rundler/src/main.rs`, instantiate and launch the service.
    -   **Goal:** At this point, we should be able to call `pm_sponsorUserOperation` via an RPC client and receive back a signed UserOperation.

### Milestone 3: Policy Engine and Mempool Submission

**Objective:** Add rule-based sponsorship control and submit the sponsored UserOperation to the mempool.

-   **Task 3.1: Implement `PolicyEngine`:**
    -   In `paymaster-relay/src/policy.rs`, define the structs for `Policy` and `PolicyConfig` (deserializable from TOML).
    -   Implement the `PolicyEngine` to load policies from the file specified in `PaymasterOpts`.
    -   Implement the `check_policy` method which, for now, checks the `sender` address against an allowlist.

-   **Task 3.2: Integrate `PolicyEngine` into `PaymasterRelayService`:**
    -   Update `PaymasterRelayService` to include the `PolicyEngine`.
    -   In the `sponsor_user_operation` logic, call `policy_engine.check_policy()` before signing. If it fails, return an error.

-   **Task 3.3: Internal Mempool Submission:**
    -   Modify the `PaymasterRelayService::sponsor_user_operation` method.
    -   Instead of returning the signed `UserOperation`, it should now call the `rundler` `Pool` task to add the UO to the mempool.
    -   This requires passing a channel/handle for the `Pool` task to the `PaymasterRelayService`.
    -   The RPC method will now return the `userOpHash` upon successful submission to the pool.

### Milestone 4: API Documentation and Final Touches

**Objective:** Add developer-friendly API documentation.

-   **Task 4.1: Add `utoipa` Dependencies:**
    -   Add `utoipa`, `utoipa-swagger-ui`, and `axum` to the `paymaster-relay` `Cargo.toml`.

-   **Task 4.2: Annotate Code:**
    -   Create `api_docs.rs` or similar.
    -   Define request/response structs and annotate them with `#[derive(ToSchema)]`.
    -   Create the main `ApiDoc` struct with `#[derive(OpenApi)]`.

-   **Task 4.3: Create and Launch Swagger Service:**
    -   Implement the `serve_swagger_ui` function using `axum`.
    -   In `rundler/bin/rundler/src/main.rs`, spawn the `serve_swagger_ui` function as a new `tokio` task if paymaster support is enabled.
    -   **Goal:** Verify that a Swagger UI is available on `http://127.0.0.1:9000` when `rundler` is running.

### Milestone 5: Testing and Validation

-   **Task 5.1:** Write unit tests for `SignerManager` and `PolicyEngine`.
-   **Task 5.2:** Write integration tests that call the `pm_sponsorUserOperation` RPC endpoint and verify that a sponsored transaction is correctly added to the mempool.
-   **Task 5.3:** Manually test the full flow with a sample dApp/script.
-   **Task 5.4:** Run `forge build` and `forge test` on the `SuperPaymaster-Contract` to ensure contract validity.
-   **Task 5.5:** Update `docs/Changes.md` and `docs/DEPLOY.md`. 