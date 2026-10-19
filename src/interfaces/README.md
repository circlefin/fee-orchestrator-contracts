# Usage example

## Paying fees with a signed quote

`FeeManager` is a UUPS proxy: deploy the implementation and proxy, then call `initialize(owner)` once on the **proxy** (see `script/deploy/DeployFeeManager.s.sol`). That sets `Ownable` ownership and grants `owner` `DEFAULT_ADMIN_ROLE`. `ALLOWED_CALLER_ROLE` is administered by `CALLER_ADMIN_ROLE` (see `src/constants/Roles.sol`). The deploy script may grant `CALLER_ADMIN_ROLE` / `SIGNER_ADMIN_ROLE` when `FEE_MANAGER_CALLER_ADMIN` / `FEE_MANAGER_SIGNER_ADMIN` are set; otherwise the owner assigns those roles later. Optional `FEE_MANAGER_TRUSTED_SIGNER` / `FEE_MANAGER_PAUSER` are also configured in that script. Use the proxy address as `feeManager` below.

```solidity
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "../constants/Roles.sol";
import {IWithTrustedQuoteSigners} from "../interfaces/IWithTrustedQuoteSigners.sol";

// 1. Register allowed caller (requires CALLER_ADMIN_ROLE on msg.sender)
IAccessControl(feeManager).grantRole(Roles.ALLOWED_CALLER_ROLE, caller);

// 1b. Register trusted quote signer (requires SIGNER_ADMIN_ROLE)
IWithTrustedQuoteSigners(feeManager).setTrustedQuoteSigner(quoteSignerAddress, true);

// 2. Build requests (from caller)
IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](4);

requests[0].quoteType = "FORWARD";
requests[0].quoteArgs = new string[](4);
requests[0].quoteArgs[0] = destinationDomain;
requests[0].quoteArgs[1] = messageTransmitterAddress;
requests[0].quoteArgs[2] = "receiveMessage";
requests[0].quoteArgs[3] = messageRecipientAddress;
requests[0].required = false;

requests[1].quoteType = "PRE_FINALITY";
requests[1].quoteArgs = new string[](2);
requests[1].quoteArgs[0] = messageValueAsset;
requests[1].quoteArgs[1] = messageValueAmount;
requests[1].required = false;

requests[2].quoteType = "PROTOCOL";
requests[2].quoteArgs = new string[](1);
requests[2].quoteArgs[0] = tokenID;
requests[2].required = true;

requests[3].quoteType = "ISSUER";
requests[3].quoteArgs = new string[](1);
requests[3].quoteArgs[0] = tokenID;
requests[3].required = true;

// 3. Prepare fee payment for an assumed-valid quote by summing the quote types this caller may collect.
string[] memory quoteTypes = new string[](4);
quoteTypes[0] = "FORWARD";
quoteTypes[1] = "PRE_FINALITY";
quoteTypes[2] = "PROTOCOL";
quoteTypes[3] = "ISSUER";
(uint256 totalFee, address feeToken) = IFeeManager(feeManager).sumFees(signedQuote, quoteTypes);
// If feeToken == address(0), send totalFee as msg.value. Otherwise approve totalFee to FeeManager.
// collectFeesWithQuote performs the full quote-argument, signature, expiry, and payment validation.

// 4. Collect fees
IFeeManager(feeManager).collectFeesWithQuote(
   keccak256(message), // correlationHash
   requests,
   IFeeManager.QuoteClaim({
       signedQuote: signedQuote,
       refundAddress: payable(endUser) // refund attribution, if any, is recorded here
   })
);
```
