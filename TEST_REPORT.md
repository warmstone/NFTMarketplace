# Test Report

## Summary

- Date: 2026-04-29
- Command: `forge test -vvv`
- Compiler: Solc 0.8.34
- Result: Passed
- Test suites: 2
- Total tests: 37
- Passed: 37
- Failed: 0
- Skipped: 0

## Test Suites

### `test/PandaNFTTest.t.sol:PandaNFTTest`

- Result: Passed
- Tests: 24 passed, 0 failed, 0 skipped
- Suite time: 12.92ms

Covered behavior:

- Deployment metadata, owner, mint price, total supply, and pause state
- Minting success path, token URI storage, event emission, and token id increments
- Mint payment validation for insufficient and excessive ETH
- Empty token URI rejection
- Mint price updates and access control
- Owner withdrawals and empty-balance rejection
- Pause and unpause behavior
- Default and token-specific ERC2981 royalty configuration
- ERC721 metadata and ERC2981 interface support

### `test/NFTMarketplaceTest.t.sol:NFTMarketplaceTest`

- Result: Passed
- Tests: 13 passed, 0 failed, 0 skipped
- Suite time: 12.90ms

Covered behavior:

- Marketplace constructor initialization
- Fixed-price listing escrow and event emission
- Price updates
- Exact-payment purchase validation
- NFT transfer, royalty payout, platform fee payout, and seller proceeds
- Delisting and escrow return
- Auction creation and escrow
- Auction settlement with and without bids
- Outbid bidder refunds through pending returns
- Fee recipient and platform fee updates
- Duplicate order prevention for escrowed tokens
- Reversion when royalty plus fee exceeds sale price

## Full Result

```text
Ran 24 tests for test/PandaNFTTest.t.sol:PandaNFTTest
Suite result: ok. 24 passed; 0 failed; 0 skipped; finished in 12.92ms (6.90ms CPU time)

Ran 13 tests for test/NFTMarketplaceTest.t.sol:NFTMarketplaceTest
Suite result: ok. 13 passed; 0 failed; 0 skipped; finished in 12.90ms (20.41ms CPU time)

Ran 2 test suites in 88.85ms (25.82ms CPU time): 37 tests passed, 0 failed, 0 skipped (37 total tests)
```
