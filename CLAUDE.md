# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hemi Prediction Markets - A fully decentralized, permissionless LMSR (Logarithmic Market Scoring Rule) prediction market protocol for the Hemi blockchain. The protocol has no admin keys, no pause functions, and no upgrade mechanisms by design.

## Build & Test Commands

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Run single test file
npx hardhat test test/<filename>.ts

# Gas report
REPORT_GAS=true npx hardhat test

# Coverage
npx hardhat coverage
```

## Project Structure

```
contracts/
├── interfaces/
│   └── IOutcomeOracle.sol          # Oracle interface
├── OutcomeToken1155.sol            # ERC-1155 outcome tokens
├── MarketCore.sol                  # Market registry & resolution
├── FpmmAMM.sol                     # LMSR automated market maker
├── UniV3EthUsdTwapOracleAdapter.sol # Uniswap V3 TWAP oracle
├── PredictionMarketDeployer.sol    # Atomic deployment helper
└── SimpleRouter.sol                # User-friendly router
test/                               # Test files
scripts/                            # Deployment scripts
```

## Architecture

The system consists of 6 Solidity contracts with clear separation of concerns:

### Core Contracts

**OutcomeToken1155.sol** - Single ERC-1155 contract for all outcome tokens across all markets
- Token IDs encode market identity: `tokenId = (uint256(marketId) << 8) | outcomeIndex`
- Minters are immutable (set at deployment) - typically MarketCore and FpmmAMM
- Custom implementation avoiding OpenZeppelin overhead

**MarketCore.sol** - Market registry, collateral vault, and resolution coordinator
- Holds all collateral for all markets
- Deterministic market IDs: `keccak256(abi.encode(params))`
- Lifecycle: Open → Resolvable → Resolved
- Coordinates with oracle contracts for resolution

**FpmmAMM.sol** - LMSR automated market maker
- Implements Hanson's cost function: `C(q) = b × ln(Σ exp(qᵢ / b))`
- Contains pure Solidity implementations of `exp()` and `ln()` for fixed-point math (18 decimals)
- Uses binary search to calculate buy amounts
- Parameter `b` (liquidityParameterB) controls liquidity depth

### Oracle System

**UniV3EthUsdTwapOracleAdapter.sol** - Oracle for ETH/USD price threshold questions
- Uses Uniswap V3 TWAP for manipulation resistance
- Implements `IOutcomeOracle` interface
- Hardcoded Hemi chain addresses for ETH/USDC.e pool

### Convenience Contracts

**PredictionMarketDeployer.sol** - Atomic market deployment helper
- Single transaction for oracle question + market + FPMM registration
- Hemi-specific convenience functions

**SimpleRouter.sol** - User-friendly wrapper
- Generic multi-outcome functions: `buyOutcome(marketId, outcomeIndex, ...)`, `sellOutcome(...)`
- Auto-detect winning outcome for redemption
- View functions for prices, balances, and estimates across all outcomes

## Key Design Patterns

- **Packed Structs**: MarketParams fits in 3 storage slots for gas efficiency
- **No Admin/Governance**: All parameters are immutable after deployment
- **O(n) Operations**: Where n = number of outcomes (max 8)
- **ReentrancyGuard**: On all state-changing operations with external calls
- **SafeERC20**: For all ERC-20 operations

## Deployment Order

Contracts must be deployed in this order due to constructor dependencies:
1. OutcomeToken1155 (needs minters[] = [MarketCore, FpmmAMM])
2. MarketCore (needs outcomeToken1155)
3. FpmmAMM (needs marketCore, outcomeToken1155)
4. UniV3EthUsdTwapOracleAdapter (standalone)
5. PredictionMarketDeployer (needs marketCore, fpmmAMM, outcomeToken1155)
6. SimpleRouter (needs marketCore, fpmmAMM, outcomeToken1155)

Note: OutcomeToken1155 minters are immutable, so it may need redeployment with correct addresses.

## Configuration Flags

Markets support config flags (bitfield):
- `FLAG_EARLY_RESOLUTION (0x01)` - Allow resolution before deadline
- `FLAG_INVALID_REFUND (0x02)` - Refund all outcomes if market resolves as invalid

## Oracle Interface

New oracles must implement `IOutcomeOracle`. The interface uses a multi-outcome pattern that supports both binary (Yes/No) markets and markets with more than 2 outcomes (up to 8):

```solidity
interface IOutcomeOracle {
    function requestResolution(bytes32 questionId) external;
    function getOutcome(bytes32 questionId) external view returns (
        uint8 winningOutcomeIndex,  // 0 to (numOutcomes-1)
        bool isInvalid,             // true if question cannot be resolved
        bool resolved,              // true once resolution is complete
        uint64 resolutionTime       // timestamp of resolution
    );
}
```

**Multi-Outcome Design:**
- `winningOutcomeIndex`: For binary markets, 0 = No, 1 = Yes (standard boolean convention)
- For multi-outcome markets: indices 0, 1, 2, ... N-1 correspond to each possible outcome
- `isInvalid`: Set to true when the question cannot be resolved (ambiguous, cancelled, etc.)
- When `isInvalid` is true, `winningOutcomeIndex` should be ignored
