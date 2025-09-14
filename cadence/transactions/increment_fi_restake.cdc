import "FungibleToken"
import "DeFiActions"
import "SwapConnectors"
import "IncrementFiStakingConnectors"
import "IncrementFiPoolLiquidityConnectors"
import "Staking"

/// ---------------------------------------------
/// Flow Actions Tutorial — IncrementFi Restake
/// ---------------------------------------------
/// Pattern: Source → Swap → Sink
/// - Source: Claims rewards from the staking pool (`PoolRewardsSource`)
/// - Swap: Converts reward token to LP via zapper (`Zapper` used through `SwapSource`)
/// - Sink: Stakes resulting LP tokens back into the farm (`PoolSink`)
///
/// Why this works:
/// - Flow Actions exposes Sources/Sink/Swappers as composable interfaces.
/// - We create each component explicitly and compose them into a single flow.
/// - The flow is executed atomically within one transaction.
///
/// Imports (string-based, per Flow Actions guidance):
/// - "FungibleToken": Standard FT interface for vault types and capability types.
/// - "DeFiActions": Core framework (e.g. UniqueIdentifier, interfaces, helpers).
/// - "SwapConnectors": Adapter that wraps a swapper + a source to produce a new source.
/// - "IncrementFiStakingConnectors": Connectors for staking pools (source/sink/helpers).
/// - "IncrementFiPoolLiquidityConnectors": Zapper that mints LP from a single input.
/// - "Staking": IncrementFi staking primitives, including `Staking.UserCertificate`.
///
/// Safety invariants to notice while reading:
/// - Prepare → Post → Execute order for reviewability.
/// - Size withdraws by sink capacity: `withdrawAvailable(maxAmount: sink.minimumCapacity())`.
/// - Calculate an expected minimum and check it in post-conditions.
/// - Assert zero residuals after depositing to avoid token dust.
///
/// Reference Tutorial: Flow Actions Transaction (IncrementFi restake)
/// See: https://developers.flow.com/blockchain-development-tutorials/flow-actions/flow-actions-transaction
/// ---------------------------------------------
///
/// Claims farm rewards from IncrementFi and restakes them into the same pool
/// This transaction follows the Claim → Zap → Stake workflow pattern
transaction(
    pid: UInt64
) {
    /// Transaction-scoped properties (computed in `prepare`, used in `post`/`execute`):
    /// - `userCertificateCap`: Capability to the caller's `Staking.UserCertificate` for auth.
    /// - `pool`: Public interface to the staking pool for validation and reads.
    /// - `startingStake`: Snapshot used to validate the staking amount increased.
    /// - `swapSource`: A composed Source that outputs LP tokens (claim → zap).
    /// - `expectedStakeIncrease`: Minimum expected LP stake increase for safety.
    /// - `operationID`: A unique identifier used across all connectors for traceability.
    let userCertificateCap: Capability<&Staking.UserCertificate>
    let pool: &{Staking.PoolPublic}
    let startingStake: UFix64
    let swapSource: SwapConnectors.SwapSource
    let expectedStakeIncrease: UFix64
    let operationID: DeFiActions.UniqueIdentifier

    prepare(acct: auth(BorrowValue, SaveValue, IssueStorageCapabilityController) &Account) {
        // --- prepare: setup, validation, configuration (no token movement yet) ---
        // 1) Validate pool access and record a reference for later reads.
        // Get pool reference and validate it exists
        self.pool = IncrementFiStakingConnectors.borrowPool(pid: pid)
            ?? panic("Pool with ID \(pid) not found or not accessible")
        
        // 2) Record starting stake for post-condition safety check (must increase).
        // Get starting stake amount for post-condition validation
        self.startingStake = self.pool.getUserInfo(address: acct.address)?.stakingAmount
            ?? panic("No user info for address \(acct.address)")
        
        // 3) Create a capability to the caller's private `UserCertificate`.
        //    This proves identity for IncrementFi staking operations (e.g. claim rewards).
        // Issue capability for user certificate
        self.userCertificateCap = acct.capabilities.storage
            .issue<&Staking.UserCertificate>(Staking.UserCertificateStoragePath)

        // 4) Create a single UniqueIdentifier and reuse it across all connectors.
        //    This enables cross-component tracing/analytics for this composed action.
        // Create unique identifier for tracing this composed operation
        self.operationID = DeFiActions.createUniqueIdentifier()

        // 5) Discover token configuration from the pool pair.
        //    - Determines the vault `Type`s used by the pair (token0/token1)
        //    - Tells us whether the pair is StableSwap or volatile (AMM) to configure zapper
        // Get pair info to determine token types and stable mode
        let pair = IncrementFiStakingConnectors.borrowPairPublicByPid(pid: pid)
            ?? panic("Pair with ID \(pid) not found or not accessible")

        // Derive token types from the pair
        let token0Type = IncrementFiStakingConnectors.tokenTypeIdentifierToVaultType(pair.getPairInfoStruct().token0Key)
        let token1Type = IncrementFiStakingConnectors.tokenTypeIdentifierToVaultType(pair.getPairInfoStruct().token1Key)
        
        // 6) Construct the Source that claims rewards from the farm.
        //    This does not move tokens immediately; it defines a source of reward vaults.
        // Create rewards source to claim staking rewards
        let rewardsSource = IncrementFiStakingConnectors.PoolRewardsSource(
            userCertificate: self.userCertificateCap,
            pid: pid,
            uniqueID: self.operationID
        )
        
        // 7) If the reward token order differs from the pair's `token0`, set `reverse`.
        //    The zapper expects the input as `token0Type`. Reversing ensures reward → LP works
        //    regardless of how the pair is ordered on-chain.
        // Check if we need to reverse token order: if reward token doesn't match token0, we reverse
        // so that the reward token becomes token0 (the input token to the zapper)
        let reverse = rewardsSource.getSourceType() != token0Type
        
        // 8) Create a Zapper which turns a single input token into LP:
        //    - If needed, it swaps part of the input into the other side of the pair
        //    - Then it mints LP tokens for the pair
        //    - `stableMode` toggles StableSwap math when applicable
        //    Details (from `IncrementFiPoolLiquidityConnectors.Zapper`):
        //    - Implements `DeFiActions.Swapper`.
        //    - `inType()` == token0Type; `outType()` == lpType (discovered from the pair's public ref).
        //    - Constructor derives the pair address using `SwapFactory` (volatile) or `StableSwapFactory` (stable)
        //      by slicing the token type identifiers; then it borrows `{SwapInterfaces.PairPublic}` to get `lpType`.
        //    - `quoteOut(forProvided, reverse: false)` estimates LP out for a given token0 input; if `reverse: true`,
        //      it estimates token0 returned for a given LP input (used for reverse operations).
        //    - `swap(quote, inVault)` executes the zap: withdraw zapped portion of token0 → swap to token1 →
        //      add liquidity with remaining token0 + token1 → return LP vault.
        //    - `swapBack(quote, residual)` removes LP → obtains token0/token1 → swaps token1 → token0 → returns token0.
        //    - `stableMode` influences the math used for reserve/amount calculations.
        //    - We flipped the token order above via `reverse` so that the reward token aligns to `inType()` (token0).
        // Create zapper to convert rewards to LP tokens
        let zapper = IncrementFiPoolLiquidityConnectors.Zapper(
            token0Type: reverse ? token1Type : token0Type,  // input token (reward token)
            token1Type: reverse ? token0Type : token1Type,  // other pair token (zapper outputs token0:token1 LP)
            stableMode: pair.getPairInfoStruct().isStableswap,
            uniqueID: self.operationID
        )
        
        // 9) Compose the flow: rewardsSource → zapper => lpSource (a Source that outputs LP)
        //    `SwapSource` wraps a swapper with a source, producing a new source of the swapper's
        //    output type. Nothing is executed yet; composition is declarative until withdraw.
        //    Details (from `SwapConnectors.SwapSource`):
        //    - Precondition: `source.getSourceType() == swapper.inType()` (ensured via the `reverse` logic above).
        //    - `getSourceType()` returns `swapper.outType()` → the composed source now provides LP vaults.
        //    - `minimumAvailable()` asks the inner source for its minimum available (rewards), then calls
        //      `swapper.quoteOut` to estimate how many LP tokens those rewards convert to.
        //    - `withdrawAvailable(maxAmount)` computes a quote (quoteOut or quoteIn depending on `maxAmount`),
        //      pulls the necessary rewards from the inner source, calls `swapper.swap` (zaps to LP), and returns
        //      the LP vault. The chain is only executed at this moment.
        //    - No residual management is needed here for forward swap; the resulting vault is already LP type.
        // Wrap rewards source with zapper to convert rewards to LP tokens
        let lpSource = SwapConnectors.SwapSource(
            swapper: zapper,
            source: rewardsSource,
            uniqueID: self.operationID
        )

        // Keep a reference to the composed LP source for use in `execute`.
        self.swapSource = lpSource
        
        // 10) Quote the expected LP output for the minimum available input.
        //     We record this as the minimum acceptable stake increase for post-conditions.
        //     Note: The actual withdraw in `execute` is sized by the sink's capacity, but we
        //     use the source's `minimumAvailable()` for a conservative expectation.
        // Calculate expected stake increase for post-condition
        self.expectedStakeIncrease = zapper.quoteOut(
            forProvided: lpSource.minimumAvailable(),
            reverse: false
        ).outAmount
    }

    post {
        // --- post: safety check (runs before `execute` commits effects) ---
        // Ensures the final staked amount increased by at least our expected minimum.
        // Verify that staking amount increased by at least the expected amount
        self.pool.getUserInfo(address: self.userCertificateCap.address)!.stakingAmount
            >= self.startingStake + self.expectedStakeIncrease:
            "Restake below expected amount"
    }

    execute {
        // --- execute: perform the atomic flow ---
        // Construct the Sink that accepts LP tokens and stakes them to the pool.
        // Create pool sink to receive LP tokens for staking
        let poolSink = IncrementFiStakingConnectors.PoolSink(
            pid: pid,
            staker: self.userCertificateCap.address,
            uniqueID: self.operationID
        )

        // Trigger the flow by withdrawing from the source, sized by the sink's capacity.
        // This drives: claim rewards → zap to LP → produce an LP vault sized to deposit.
        // Withdraw LP tokens from swap source (sized by sink capacity)
        let vault <- self.swapSource.withdrawAvailable(maxAmount: poolSink.minimumCapacity())
        
        // Deposit all produced LP into the staking pool sink.
        // Deposit LP tokens into pool for staking
        poolSink.depositCapacity(from: &vault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
        
        // Safety: ensure no dust remains and clean up the temporary vault.
        // Ensure no residual tokens remain
        assert(vault.balance == 0.0, message: "Residual after deposit")
        destroy vault
    }
} 