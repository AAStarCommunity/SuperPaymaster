# Super-Relay Core Features

This document outlines the core features of the `super-relay` service, derived from the `Design.md`. It serves as a high-level overview for product and development purposes.

## Version 0.1.0

### Feature 1: Paymaster Sponsorship RPC Endpoint

-   **User Story:** As a dApp developer, I want to submit a UserOperation to a single RPC endpoint (`pm_sponsorUserOperation`) so that `super-relay` can validate it, apply a gas sponsorship, sign it with the Paymaster's key, and submit it to the bundler's mempool in one atomic step.

-   **Product Design:**
    -   Provide a new JSON-RPC method: `pm_sponsorUserOperation`.
    -   Inputs: `userOperation`, `entryPointAddress`.
    -   The service handles the entire lifecycle: validation, policy check, signing, and internal submission to the mempool.
    -   Output: Returns the `userOpHash` of the successfully submitted UserOperation, or a descriptive error if any step fails.

-   **Technical Implementation:**
    -   Implement a new `PaymasterRelayApi` using `jsonrpsee` in the `paymaster-relay` crate.
    -   Integrate this new API into the main `rundler` RPC server task.
    -   The API implementation will orchestrate calls to the validation, policy, signing, and mempool submission services.

### Feature 2: Basic Sponsorship Policy Engine

-   **User Story:** As a relay operator, I want to define a simple set of rules in a configuration file to control which UserOperations are eligible for sponsorship, so that I can manage my costs and prevent abuse.

-   **Product Design:**
    -   Support a configuration file (e.g., `policies.toml`).
    -   Initial policies should support filtering based on:
        -   The `sender` of the UserOperation.
        -   The target contract `address` in the UserOperation's `callData`.
    -   The service should load these policies at startup.

-   **Technical Implementation:**
    -   Create a `PolicyEngine` struct in `paymaster-relay/src/policy.rs`.
    -   Define data structures for policies that can be deserialized from a TOML file.
    -   The `PaymasterRelayService` will use the `PolicyEngine` to check for eligibility before signing.

### Feature 3: Local Private Key Signer

-   **User Story:** As a relay operator, I need the service to securely access a private key for signing Paymaster data, so that sponsored transactions can be validated on-chain.

-   **Product Design:**
    -   The service must be able to load a private key for the Paymaster.
    -   For the initial version, loading from an environment variable is sufficient and secure.
    -   The design should be modular to allow for more advanced KMS (Key Management Service) integrations in the future.

-   **Technical Implementation:**
    -   Create a `SignerManager` in `paymaster-relay/src/signer.rs`.
    -   It will be initialized with a private key loaded from a specified environment variable.
    -   It will expose a method like `sign_user_op_hash(&self, hash: H256) -> Signature`.

### Feature 4: Automatic API Documentation (Swagger UI)

-   **User Story:** As a developer consuming the `super-relay` API, I want to access an interactive Swagger/OpenAPI documentation page, so that I can easily understand the available endpoints, parameters, and data models.

-   **Product Design:**
    -   When `rundler` is running, a Swagger UI page should be accessible on a separate HTTP port (e.g., 9000).
    -   The documentation should automatically reflect the `pm_sponsorUserOperation` method and its associated data structures.

-   **Technical Implementation:**
    -   Integrate `utoipa` and `utoipa-swagger-ui` into the `paymaster-relay` crate.
    -   Annotate API-related data structures and create a "dummy" path function for documentation generation.
    -   Create a new async function to serve the Swagger UI using `axum`.
    -   Launch this function as a separate `tokio::task` from the main `rundler` startup logic. 