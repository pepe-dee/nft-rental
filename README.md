# NFT Rental Protocol

A secure and flexible NFT rental protocol built on Stacks blockchain using Clarity 2.0.

## Overview

This smart contract enables NFT owners to safely rent out their NFTs while maintaining custody through an escrow system. The protocol supports daily pricing, flexible rental durations, and extension capabilities.

## Features

- 🔒 **Secure Escrow**: NFTs remain safely held by the contract
- 💰 **Flexible Pricing**: Set daily rates in STX
- ⏱️ **Customizable Duration**: Configure maximum rental periods
- 🔄 **Extendable Rentals**: Renters can extend active rentals
- 💸 **Automated Payments**: Direct earnings distribution to NFT owners
- 🛡️ **Re-entrancy Protection**: Secure withdrawal mechanisms

## Contract Functions

### Core Operations

```clarity
(create-listing (nft <sip009-nft-standard>) (token-id uint) (daily-price uint) (max-days uint))
(rent (id uint) (days uint))
(extend (id uint) (extra-days uint))
(delist (nft <sip009-nft-standard>) (id uint))
```

### View Functions

```clarity
(get-listing (id uint))
(get-rental (id uint))
(is-active-renter (nft principal) (token-id uint) (who principal))
```

### Financial Operations

```clarity
(withdraw-earnings)
(get-earnings (who principal))
```

## Security Features

- Validation checks on all inputs
- Safe map operations with proper error handling
- Re-entrancy protection on financial operations
- Emergency deactivation capability

## Requirements

- Stacks 2.0 compatible wallet
- SIP-009 compliant NFTs
- STX for rental payments and gas fees

## Usage Example

1. NFT owner creates listing with daily rate and maximum duration
2. Renter pays STX to rent NFT for specified period
3. Contract tracks rental period and manages access rights
4. Owner can withdraw accumulated earnings at any time

## Error Codes

- `ERR-NOT-FOUND (404)`: Resource not found
- `ERR-UNAUTHORIZED (401)`: Unauthorized access
- `ERR-BAD-ARGS (400)`: Invalid arguments
- `ERR-ACTIVE-RENTAL (409)`: Rental already active
- `ERR-NOT-ACTIVE (410)`: Listing not active
- `ERR-INSUFFICIENT (402)`: Insufficient funds

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License

[MIT](https://choosealicense.com/licenses/mit/)
