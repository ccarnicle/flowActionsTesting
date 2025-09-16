import "FungibleToken"
import "FlowToken"

transaction(recipient: Address, amount: UFix64) {

	let temporaryVault: @{FungibleToken.Vault}

	prepare(signer: auth(BorrowValue, Storage) &Account) {
		let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
			?? panic("Sender has no FlowToken vault at /storage/flowTokenVault")

		self.temporaryVault <- vaultRef.withdraw(amount: amount)
	}

	execute {
		let receiver = getAccount(recipient)
			.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
			.borrow()
			?? panic("Recipient is missing /public/flowTokenReceiver capability")

		receiver.deposit(from: <-self.temporaryVault)
	}
}


