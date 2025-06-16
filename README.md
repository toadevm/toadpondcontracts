# ToadPond Games

A collection of decentralized blockchain games leveraging Chainlink's advanced oracle infrastructure for secure and fair gameplay.

## Projects

### 1. Cross-Chain Lottery
A sophisticated decentralized cross-chain lottery system using Chainlink's CCIP (Cross-Chain Interoperability Protocol) and VRF (Verifiable Random Function) for secure, fair, and cross-chain lottery operations.

#### Game Logic
- Multi-player lottery with up to 4 players per round (expandable to 10)
- Points system (5 points per entry)
- Cross-chain participation via CCIP
- Automatic ETH-to-BONE conversion
- Local and cross-chain prize distribution

#### Fee Distribution
- Winners: 60% of the prize pool
- Development: 5% of fees
- Funding Pool: 30% of fees distributed equally among 5 donor addresses
- Token Burning: 5% of fees sent to dead address

### 2. CoinFlip
A high-performance, gas-efficient coin flip game with automated token pricing and sophisticated security measures:

#### Game Logic & Requirements
- NFT Gating: Must own at least 1 Frog Soup NFT to create or join games
- Creator chooses Heads or Tails and sets bet amount
- MEV protection prevents same-block multiple games
- VRF-powered random outcome generation
- Supports both single and batch game creation
- Dynamic token pricing via TWAP oracles

#### Fee Distribution
- Platform Fee: 5% of each game
  - Distributed equally among 6 donor addresses
  - Donors can withdraw their share at any time
- Winner's Prize: 95% of the game pool

- **Gas-Efficient Design**:
  - Optimized token rate updates using TWAP
  - 5-minute rate caching to minimize oracle calls
  - Gas abstraction support for multi-token betting
  - Packed structs for minimal storage costs

- **Advanced Security**:
  - Chainlink VRF V2+ for verifiable randomness
  - Circuit breaker for price volatility protection
  - Liquidity-based manipulation prevention
  - TWAP oracle for flash loan resistance
  - Full reentrancy protection

- **Features**:
  - Single and batch game creation
  - Multi-token support with dynamic pricing
  - Gas abstraction for better UX
  - Automated winner resolution

## Technical Overview

### Automatic Pricing System
The lottery implements an advanced auto-pricing mechanism that ensures optimal entry fees and token swaps:

- **Chainlink Price Feeds**: Uses ETH/USD price feed for real-time market data
- **Uniswap V4 Integration**: 
  - Direct pool price observation via `sqrtPriceX96`
  - Optimized swap calculations with price bounds
  - Dynamic slippage adjustment (10%-60% range)
  - Gas-efficient price calculations using bit shifting

### Smart Contract Architecture

#### Core Contracts
- `VRFLottery.sol` (Main Contract):
  - Chainlink VRF V2+ for randomness
  - Advanced ETH-to-BONE swap mechanism
  - Automatic entry fee calculation
  - Cross-chain winner distribution
  - Gas-optimized with packed structs
  - Adaptive slippage based on market conditions
  - Safety bounds for token ratios (10-100M BONE/ETH)

- `CrossChainLotteryEntry.sol`:
  - CCIP-based cross-chain messaging
  - Self-sustaining fee model
  - User-paid cross-chain verification

#### Key Features

**1. Cross-Chain Infrastructure**
- Chainlink CCIP for trustless cross-chain communication
- Verifiable message passing between chains
- Cross-chain prize distribution system

**2. Randomness & Fairness**
- Chainlink VRF V2+ for verifiable random numbers
- Multi-word random number support
- Configurable confirmations (default: 3)

**3. Price Management**
- Real-time ETH/USD price feeds
- Automated price validation and staleness checks
- Dynamic slippage adjustment:
  - Base: 25% (for low TVL pools)
  - Range: 10% to 60%
  - Auto-adjusts based on swap success/failure

**4. Economic Model**
- Prize distribution:
  - Winners: 60%
  - Development: 5%
  - Funding: 30%
  - Token burning: 5%
- Points system (5 points per entry)
- Configurable maximum players per round

**5. Security Features**
- ReentrancyGuard for all entry functions
- Pausable contract functionality
- Cross-chain message verification
- Gas-optimized struct packing
- Price bounds validation
- Emergency withdrawal systems
- Minimum/maximum entry amount checks

## Dependencies

- Chainlink Contracts (VRF V2+, CCIP, Price Feeds)
- OpenZeppelin Contracts (Security, Token Standards)
- Uniswap V4 Core & Periphery
- Permit2 & Universal Router
- Foundry Development Suite

## Development

This project uses Foundry for development, testing, and deployment.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/downloads)

### Setup

1. Clone the repository
2. Install dependencies:
   ```shell
   forge install
   ```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Deploy

For VRF Lottery:
```shell
forge script script/DeployVRFLottery.s.sol:DeployVRFLottery --rpc-url <your_rpc_url> --private-key <your_private_key>
```

For Cross-Chain Lottery:
```shell
forge script script/DeployCrossChainLottery.s.sol:DeployCrossChainLottery --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Interact with Deployed Contracts

Enter VRF Lottery:
```shell
forge script script/EnterWithETH.s.sol:EnterWithETH --rpc-url <your_rpc_url> --private-key <your_private_key>
```

Enter Cross-Chain Lottery:
```shell
forge script script/EnterCrossChainLottery.s.sol:EnterCrossChainLottery --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## Security

> Note: This is a private repository containing proprietary smart contract code. Please ensure proper security measures when handling the code.

## License

MIT
