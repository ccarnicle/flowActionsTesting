import "FungibleToken"
import "FlowToken"
import "IncrementFiSwapConnectors"
import "aiSportsJuice"

/// ------------------------------------------------------
/// Simple swap: FLOW -> JUICE using IncrementFi SwapRouter
/// ------------------------------------------------------
/// Composition preference: Option B (swap and deposit)
/// - We withdraw exactly 0.1 FLOW from the signer
/// - Use IncrementFiSwapConnectors.Swapper with path [FLOW -> stFLOW -> JUICE]
/// - Deposit JUICE back to the signer via their JUICE receiver
///
/// Note on types: While generic interface types exist, IncrementFiSwapConnectors.Swapper
/// validates `inVault` and `outVault` against the path (address/contractName). Therefore,
/// we pass concrete token-specific vault types (`Type<@FlowToken.Vault>`, `Type<@aiSportsJuice.Vault>`)
/// rather than `Type<@{FungibleToken.Vault}>` to satisfy on-chain checks.
///
/// Option A (alternative, not implemented here):
/// - Compose a Source (VaultSource(FLOW)) → SwapSource(JUICE) → VaultSink(JUICE)
/// - Useful if you need the swapped output as a Source to fan-out or further transform

transaction() {
    /// Amount of FLOW to swap (fixed for auditability)
    let amountInFlow: UFix64

    /// Temporary FLOW vault withdrawn from signer
    let flowVault: @{FungibleToken.Vault}

    /// Router path for IncrementFi (FLOW -> stFLOW -> JUICE)
    let path: [String]

    /// Keep signer address for deposit step
    let signerAddress: Address

    prepare(acct: auth(BorrowValue, Storage) &Account) {
        self.signerAddress = acct.address
        self.amountInFlow = 0.1

        // Withdraw FLOW from the signer's FlowToken vault
        let flowVaultRef = acct.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Missing FlowToken vault at /storage/flowTokenVault")
        self.flowVault <- flowVaultRef.withdraw(amount: self.amountInFlow)

        // Define the swap path using IncrementFi token key identifiers
        // FLOW (A.1654653399040a61.FlowToken) -> stFLOW (A.d6f80565193ad727.stFlowToken) -> JUICE (A.9db94c9564243ba7.aiSportsJuice)
        self.path = [
            "A.1654653399040a61.FlowToken",
            "A.d6f80565193ad727.stFlowToken",
            "A.9db94c9564243ba7.aiSportsJuice"
        ]
    }

    execute {
        // Build the IncrementFi swapper (FLOW -> JUICE via stFLOW)
        // Provide concrete token vault types for validation against the path
        let swapper = IncrementFiSwapConnectors.Swapper(
            path: self.path,
            inVault: Type<@FlowToken.Vault>(),
            outVault: Type<@aiSportsJuice.Vault>(),
            uniqueID: nil
        )

        // Perform the swap; the swapper internally quotes amountOutMin
        let juiceVault <- swapper.swap(quote: nil, inVault: <-self.flowVault)

        // Deposit JUICE into the signer's JUICE receiver
        let juiceReceiver = getAccount(self.signerAddress)
            .capabilities
            .get<&{FungibleToken.Receiver}>(/public/aiSportsJuiceReceiver)
            .borrow()
            ?? panic("Missing /public/aiSportsJuiceReceiver capability on signer")

        juiceReceiver.deposit(from: <-juiceVault)
    }
}


