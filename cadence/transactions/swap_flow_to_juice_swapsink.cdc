import "FungibleToken"
import "FlowToken"
import "IncrementFiSwapConnectors"
import "FungibleTokenConnectors"
import "aiSportsJuice"

/// ------------------------------------------------------
/// Swap FLOW -> JUICE using SwapSink composition (Option B)
/// ------------------------------------------------------
/// - Source: VaultSource(FLOW) withdrawing exactly 0.1 FLOW
/// - Swapper: IncrementFiSwapConnectors.Swapper with path [FLOW -> stFLOW -> JUICE]
/// - Inner Sink: VaultSink(JUICE) depositing to signer's JUICE vault
/// - Composed Sink: SwapConnectors.SwapSink(swapper, sink)
///
/// Note: This version uses the connectors explicitly rather than calling the swapper
/// directly. It’s more declarative and mirrors the Source→Swapper→Sink model.

transaction() {
    let amountInFlow: UFix64

    // Connectors
    let source: FungibleTokenConnectors.VaultSource
    let innerSink: FungibleTokenConnectors.VaultSink
    let swapper: IncrementFiSwapConnectors.Swapper

    // Temporary vault for the withdrawal amount
    let flowVault: @{FungibleToken.Vault}

    // Path and signer
    let path: [String]
    let signerAddress: Address

    prepare(acct: auth(BorrowValue, Storage, IssueStorageCapabilityController) &Account) {
        self.signerAddress = acct.address
        self.amountInFlow = 0.1

        // Build the Source from the signer's FlowToken vault capability
        let flowWithdrawCap = acct.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        self.source = FungibleTokenConnectors.VaultSource(
            min: nil,
            withdrawVault: flowWithdrawCap,
            uniqueID: nil
        )

        // Build the inner Sink for JUICE deposits
        let juiceReceiverCap = acct.capabilities
            .get<&{FungibleToken.Vault}>(/public/aiSportsJuiceReceiver)
        self.innerSink = FungibleTokenConnectors.VaultSink(
            max: nil,
            depositVault: juiceReceiverCap,
            uniqueID: nil
        )

        // Define router path FLOW -> stFLOW -> JUICE
        self.path = [
            "A.1654653399040a61.FlowToken",
            "A.d6f80565193ad727.stFlowToken",
            "A.9db94c9564243ba7.aiSportsJuice"
        ]

        // Swapper for FLOW -> JUICE
        self.swapper = IncrementFiSwapConnectors.Swapper(
            path: self.path,
            inVault: Type<@FlowToken.Vault>(),
            outVault: Type<@aiSportsJuice.Vault>(),
            uniqueID: nil
        )

        // Withdraw exactly 0.1 FLOW from Source
        self.flowVault <- self.source.withdrawAvailable(maxAmount: self.amountInFlow)
    }

    execute {
        // Compose SwapSink on the fly and deposit
        let swapSink = SwapConnectors.SwapSink(
            swapper: self.swapper,
            sink: self.innerSink,
            uniqueID: nil
        )

        // Deposit 0.1 FLOW into swap sink (will swap to JUICE and deposit)
        swapSink.depositCapacity(from: &self.flowVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})

        // Ensure no residuals remain in the temp vault
        assert(self.flowVault.balance == 0.0, message: "Residual after swap sink deposit")
        destroy self.flowVault
    }
}


