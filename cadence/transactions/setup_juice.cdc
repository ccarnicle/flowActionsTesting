import "aiSportsJuice"
import "FungibleToken" 
import "MetadataViews"
import "FungibleTokenMetadataViews"

transaction() {
  prepare(user: auth(Storage, Capabilities) &Account) {
    let vaultData = aiSportsJuice.resolveContractView(
      resourceType: nil, 
      viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
    ) as! FungibleTokenMetadataViews.FTVaultData

    if user.storage.borrow<&aiSportsJuice.Vault>(from: vaultData.storagePath) == nil {
      user.storage.save(
        <- aiSportsJuice.createEmptyVault(vaultType: Type<@aiSportsJuice.Vault>()), 
        to: vaultData.storagePath
      )

      // Issue a capability with the correct interface
      let receiverCap = user.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultData.storagePath)

      user.capabilities.publish(receiverCap, at: vaultData.receiverPath)
    }
  }
}