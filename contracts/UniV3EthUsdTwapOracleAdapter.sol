// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOutcomeOracle} from "./interfaces/IOutcomeOracle.sol";

/**
 * @title UniV3EthUsdTwapOracleAdapter
 * @author Hemi Prediction Markets
 * @notice Oracle adapter for binary ETH/USD price threshold questions using Uniswap V3 TWAP
 * @dev Reads Time-Weighted Average Price from Uniswap V3 compatible pools and resolves
 *      "ETH above/below threshold at time X" type prediction market questions
 * 
 * Hemi Chain Deployment Addresses:
 * - ETH/USDC.e V3 Pool: 0x9580d4519c9f27642e21085e763e761a74ef3735
 * - WETH:               0x4200000000000000000000000000000000000006
 * - USDC.e:             0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA
 * 
 * Architecture:
 * - Permissionless question registration
 * - Permissionless resolution once time conditions are met
 * - Uses Uniswap V3 pool.observe() for manipulation-resistant TWAP calculation
 * - Implements IOutcomeOracle interface for seamless MarketCore integration
 * 
 * Question Types Supported:
 * - "Will ETH be above $X at time T?" (greaterThan = true)
 * - "Will ETH be below $X at time T?" (greaterThan = false)
 * 
 * Security Model:
 * - No admin, owner, or governance functions
 * - Immutable question parameters after registration
 * - Time-locked resolution (must wait until evalTime + twapWindow)
 * - TWAP provides manipulation resistance vs spot price
 * - Deterministic question IDs prevent duplicates
 * 
 * Gas Optimizations:
 * - Packed struct storage (4 slots per question)
 * - O(1) all operations
 * - Minimal external calls during resolution
 * - Inline TickMath for sqrt price calculation
 */
contract UniV3EthUsdTwapOracleAdapter is IOutcomeOracle {
    // ============ Errors ============
    
    /// @notice Question with this ID already exists
    error QuestionAlreadyExists();
    
    /// @notice No question found with this ID
    error QuestionNotFound();
    
    /// @notice Question has already been resolved
    error QuestionAlreadyResolved();
    
    /// @notice Cannot resolve yet - must wait until evalTime + twapWindow
    error ResolutionTooEarly();
    
    /// @notice Pool address cannot be zero
    error InvalidPool();
    
    /// @notice Evaluation time must be in the future
    error InvalidEvalTime();
    
    /// @notice TWAP window must be greater than zero
    error InvalidTwapWindow();
    
    /// @notice Pool observe() call failed
    error PoolObserveFailed();
    
    /// @notice Tick out of valid range
    error TickOutOfRange();

    // ============ Constants ============
    
    /// @notice Maximum valid tick value for Uniswap V3
    int24 private constant MAX_TICK = 887272;
    
    /// @notice Minimum valid tick value for Uniswap V3
    int24 private constant MIN_TICK = -887272;

    // ============ Hemi Chain Reference Addresses ============
    
    /// @notice Default ETH/USDC.e V3 pool on Hemi
    address public constant HEMI_ETH_USDC_POOL = 0x9580D4519C9F27642e21085E763E761a74eF3735;
    
    /// @notice WETH address on Hemi
    address public constant HEMI_WETH = 0x4200000000000000000000000000000000000006;
    
    /// @notice USDC.e address on Hemi (via Stargate/LayerZero)
    address public constant HEMI_USDC = 0xad11a8BEb98bbf61dbb1aa0F6d6F2ECD87b35afA;

    // ============ Types ============
    
    /**
     * @notice Configuration and state for a threshold question
     * @dev Packed for storage efficiency across 4 storage slots
     *      This is a binary oracle: outcome index 0 = No, index 1 = Yes
     *
     * Slot 1 (32 bytes):
     * - pool: 20 bytes
     * - twapWindow: 4 bytes
     * - evalTime: 8 bytes
     *
     * Slot 2 (24 bytes used):
     * - baseToken: 20 bytes
     * - greaterThan: 1 byte
     * - exists: 1 byte
     * - resolved: 1 byte
     * - winningOutcomeIndex: 1 byte (0 = No, 1 = Yes)
     *
     * Slot 3 (28 bytes used):
     * - quoteToken: 20 bytes
     * - resolutionTime: 8 bytes
     *
     * Slot 4 (32 bytes):
     * - threshold: 32 bytes
     */
    struct ThresholdQuestion {
        address pool;           // Uniswap V3 pool address
        uint32 twapWindow;      // TWAP window in seconds (e.g., 1800 for 30 min)
        uint64 evalTime;        // Unix timestamp for price evaluation
        address baseToken;      // Base token (WETH) - the asset being priced
        bool greaterThan;       // true: YES if price >= threshold
        bool exists;            // Question has been registered
        bool resolved;          // Question has been resolved
        uint8 winningOutcomeIndex; // 0 = Yes, 1 = No (binary market convention)
        address quoteToken;     // Quote token (USDC) - the denomination
        uint64 resolutionTime;  // Unix timestamp when resolved
        uint256 threshold;      // Price threshold in quote token decimals
    }

    // ============ Storage ============
    
    /// @notice All registered questions indexed by deterministic ID
    mapping(bytes32 => ThresholdQuestion) public questions;

    // ============ Events ============
    
    /**
     * @notice Emitted when a new threshold question is registered
     * @param questionId Deterministic question identifier
     * @param pool Uniswap V3 pool used for price
     * @param baseToken Base token being priced (WETH)
     * @param quoteToken Quote token denomination (USDC)
     * @param threshold Price threshold in quote decimals
     * @param twapWindow TWAP window in seconds
     * @param evalTime Unix timestamp for evaluation
     * @param greaterThan Comparison direction
     */
    event ThresholdQuestionRegistered(
        bytes32 indexed questionId,
        address indexed pool,
        address baseToken,
        address quoteToken,
        uint256 threshold,
        uint32 twapWindow,
        uint64 evalTime,
        bool greaterThan
    );
    
    /**
     * @notice Emitted when a question is resolved
     * @param questionId The resolved question
     * @param winningOutcomeIndex Index of winning outcome (0=No, 1=Yes for binary)
     * @param price Actual TWAP price at resolution
     * @param resolutionTime Unix timestamp of resolution
     */
    event ThresholdQuestionResolved(
        bytes32 indexed questionId,
        uint8 winningOutcomeIndex,
        uint256 price,
        uint64 resolutionTime
    );

    // ============ Question Registration ============
    
    /**
     * @notice Register a new ETH/USD threshold question
     * @param pool Uniswap V3 pool address (use HEMI_ETH_USDC_POOL for default)
     * @param baseToken Base token address (use HEMI_WETH for ETH)
     * @param quoteToken Quote token address (use HEMI_USDC for USD)
     * @param threshold Price threshold in quote token decimals
     *        Example: 3000 * 1e6 = 3000000000 for "$3000" with 6-decimal USDC
     * @param twapWindow TWAP window in seconds
     *        Recommended: 1800 (30 min) for manipulation resistance
     * @param evalTime Unix timestamp when price should be evaluated
     *        Must be in the future at registration time
     * @param greaterThan Comparison direction:
     *        true = YES if TWAP price >= threshold
     *        false = YES if TWAP price <= threshold
     * @return questionId Deterministic identifier for this question
     * @dev Permissionless - anyone can register questions
     *      Question ID = keccak256(pool, baseToken, quoteToken, threshold, twapWindow, evalTime, greaterThan)
     */
    function registerThresholdQuestion(
        address pool,
        address baseToken,
        address quoteToken,
        uint256 threshold,
        uint32 twapWindow,
        uint64 evalTime,
        bool greaterThan
    ) external returns (bytes32 questionId) {
        // Validate inputs
        if (pool == address(0)) revert InvalidPool();
        if (evalTime <= block.timestamp) revert InvalidEvalTime();
        if (twapWindow == 0) revert InvalidTwapWindow();
        
        // Compute deterministic question ID
        questionId = keccak256(abi.encode(
            pool,
            baseToken,
            quoteToken,
            threshold,
            twapWindow,
            evalTime,
            greaterThan
        ));
        
        // Prevent duplicate questions
        if (questions[questionId].exists) revert QuestionAlreadyExists();
        
        // Store question configuration
        questions[questionId] = ThresholdQuestion({
            pool: pool,
            baseToken: baseToken,
            quoteToken: quoteToken,
            threshold: threshold,
            twapWindow: twapWindow,
            evalTime: evalTime,
            greaterThan: greaterThan,
            exists: true,
            resolved: false,
            winningOutcomeIndex: 0,
            resolutionTime: 0
        });
        
        emit ThresholdQuestionRegistered(
            questionId,
            pool,
            baseToken,
            quoteToken,
            threshold,
            twapWindow,
            evalTime,
            greaterThan
        );
    }
    
    /**
     * @notice Convenience function to register question with Hemi default addresses
     * @param threshold Price threshold in USDC decimals (6 decimals)
     * @param twapWindow TWAP window in seconds
     * @param evalTime Evaluation timestamp
     * @param greaterThan true for "above threshold", false for "below"
     * @return questionId The question identifier
     */
    function registerHemiEthUsdQuestion(
        uint256 threshold,
        uint32 twapWindow,
        uint64 evalTime,
        bool greaterThan
    ) external returns (bytes32 questionId) {
        if (evalTime <= block.timestamp) revert InvalidEvalTime();
        if (twapWindow == 0) revert InvalidTwapWindow();
        
        questionId = keccak256(abi.encode(
            HEMI_ETH_USDC_POOL,
            HEMI_WETH,
            HEMI_USDC,
            threshold,
            twapWindow,
            evalTime,
            greaterThan
        ));
        
        if (questions[questionId].exists) revert QuestionAlreadyExists();

        questions[questionId] = ThresholdQuestion({
            pool: HEMI_ETH_USDC_POOL,
            baseToken: HEMI_WETH,
            quoteToken: HEMI_USDC,
            threshold: threshold,
            twapWindow: twapWindow,
            evalTime: evalTime,
            greaterThan: greaterThan,
            exists: true,
            resolved: false,
            winningOutcomeIndex: 0,
            resolutionTime: 0
        });
        
        emit ThresholdQuestionRegistered(
            questionId,
            HEMI_ETH_USDC_POOL,
            HEMI_WETH,
            HEMI_USDC,
            threshold,
            twapWindow,
            evalTime,
            greaterThan
        );
    }

    // ============ IOutcomeOracle Implementation ============
    
    /**
     * @notice Request resolution of a threshold question
     * @param questionId The question to resolve
     * @dev Anyone can call after evalTime + twapWindow has passed
     *      Reads TWAP from the Uniswap V3 pool and compares to threshold
     *      Resolution is permanent - cannot be changed once set
     */
    function requestResolution(bytes32 questionId) external override {
        ThresholdQuestion storage q = questions[questionId];
        
        if (!q.exists) revert QuestionNotFound();
        if (q.resolved) revert QuestionAlreadyResolved();
        
        // Must wait until evaluation time + TWAP window has fully elapsed
        // This ensures the oracle has accumulated enough observations
        if (block.timestamp < uint256(q.evalTime) + uint256(q.twapWindow)) {
            revert ResolutionTooEarly();
        }
        
        // Calculate TWAP price from the pool
        uint256 twapPrice = _getTwapPrice(
            q.pool,
            q.baseToken,
            q.quoteToken,
            q.twapWindow
        );

        // Determine winning outcome based on threshold comparison
        // Binary market convention: 0 = No, 1 = Yes (standard boolean)
        uint8 winningIndex;
        if (q.greaterThan) {
            // Question: "Will ETH be >= threshold?"
            winningIndex = twapPrice >= q.threshold ? 1 : 0; // 1=Yes, 0=No
        } else {
            // Question: "Will ETH be <= threshold?"
            winningIndex = twapPrice <= q.threshold ? 1 : 0; // 1=Yes, 0=No
        }

        // Store resolution (permanent)
        q.resolved = true;
        q.winningOutcomeIndex = winningIndex;
        q.resolutionTime = uint64(block.timestamp);

        emit ThresholdQuestionResolved(
            questionId,
            winningIndex,
            twapPrice,
            q.resolutionTime
        );
    }
    
    /**
     * @notice Get the outcome for a question
     * @param questionId The question to query
     * @return winningOutcomeIndex Index of winning outcome (0=No, 1=Yes for binary)
     * @return isInvalid True if resolved as invalid (always false for this oracle)
     * @return resolved Whether the question has been resolved
     * @return resolutionTime Unix timestamp when resolution occurred (0 if not resolved)
     */
    function getOutcome(bytes32 questionId) external view override returns (
        uint8 winningOutcomeIndex,
        bool isInvalid,
        bool resolved,
        uint64 resolutionTime
    ) {
        ThresholdQuestion storage q = questions[questionId];

        if (!q.exists) revert QuestionNotFound();

        // This oracle never returns invalid - it always resolves to Yes or No
        // based on the TWAP price comparison
        return (q.winningOutcomeIndex, false, q.resolved, q.resolutionTime);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get full question configuration
     * @param questionId The question to query
     * @return pool The Uniswap V3 pool address
     * @return baseToken The base token (WETH)
     * @return quoteToken The quote token (USDC)
     * @return threshold The price threshold
     * @return twapWindow The TWAP window in seconds
     * @return evalTime The evaluation timestamp
     * @return greaterThan The comparison direction
     */
    function getQuestionConfig(bytes32 questionId) external view returns (
        address pool,
        address baseToken,
        address quoteToken,
        uint256 threshold,
        uint32 twapWindow,
        uint64 evalTime,
        bool greaterThan
    ) {
        ThresholdQuestion storage q = questions[questionId];
        
        if (!q.exists) revert QuestionNotFound();
        
        return (
            q.pool,
            q.baseToken,
            q.quoteToken,
            q.threshold,
            q.twapWindow,
            q.evalTime,
            q.greaterThan
        );
    }
    
    /**
     * @notice Compute question ID for given parameters (off-chain helper)
     * @dev Use this to predict question ID before registration
     */
    function computeQuestionId(
        address pool,
        address baseToken,
        address quoteToken,
        uint256 threshold,
        uint32 twapWindow,
        uint64 evalTime,
        bool greaterThan
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(
            pool,
            baseToken,
            quoteToken,
            threshold,
            twapWindow,
            evalTime,
            greaterThan
        ));
    }
    
    /**
     * @notice Compute question ID using Hemi default addresses
     * @dev Convenience function for Hemi-specific questions
     */
    function computeHemiQuestionId(
        uint256 threshold,
        uint32 twapWindow,
        uint64 evalTime,
        bool greaterThan
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(
            HEMI_ETH_USDC_POOL,
            HEMI_WETH,
            HEMI_USDC,
            threshold,
            twapWindow,
            evalTime,
            greaterThan
        ));
    }
    
    /**
     * @notice Check if a question can be resolved now
     * @param questionId The question to check
     * @return canResolve True if requestResolution() can be called successfully
     */
    function canResolve(bytes32 questionId) external view returns (bool) {
        ThresholdQuestion storage q = questions[questionId];
        
        if (!q.exists || q.resolved) return false;
        
        return block.timestamp >= uint256(q.evalTime) + uint256(q.twapWindow);
    }
    
    /**
     * @notice Get time remaining until resolution is available
     * @param questionId The question to check
     * @return secondsRemaining Seconds until canResolve() returns true (0 if already resolvable)
     */
    function timeUntilResolution(bytes32 questionId) external view returns (uint256 secondsRemaining) {
        ThresholdQuestion storage q = questions[questionId];
        
        if (!q.exists) revert QuestionNotFound();
        if (q.resolved) return 0;
        
        uint256 resolutionTime = uint256(q.evalTime) + uint256(q.twapWindow);
        if (block.timestamp >= resolutionTime) return 0;
        
        return resolutionTime - block.timestamp;
    }
    
    /**
     * @notice Get current TWAP price for a pool (for testing/monitoring)
     * @param pool The Uniswap V3 pool
     * @param baseToken The base token
     * @param quoteToken The quote token
     * @param twapWindow The TWAP window in seconds
     * @return price The TWAP price in quote token decimals
     */
    function getCurrentTwapPrice(
        address pool,
        address baseToken,
        address quoteToken,
        uint32 twapWindow
    ) external view returns (uint256) {
        return _getTwapPrice(pool, baseToken, quoteToken, twapWindow);
    }
    
    /**
     * @notice Get current ETH/USD TWAP on Hemi using default addresses
     * @param twapWindow The TWAP window in seconds
     * @return price ETH price in USDC (6 decimals)
     */
    function getHemiEthUsdPrice(uint32 twapWindow) external view returns (uint256) {
        return _getTwapPrice(HEMI_ETH_USDC_POOL, HEMI_WETH, HEMI_USDC, twapWindow);
    }

    // ============ Internal Functions ============
    
    /**
     * @dev Get TWAP price from Uniswap V3 pool
     * @param pool The pool address
     * @param baseToken The base token (asset being priced)
     * @param quoteToken The quote token (denomination)
     * @param twapWindow Seconds to look back for TWAP
     * @return price Price of baseToken in quoteToken decimals
     */
    function _getTwapPrice(
        address pool,
        address baseToken,
        address quoteToken,
        uint32 twapWindow
    ) internal view returns (uint256) {
        // Prepare observation query - [twapWindow seconds ago, now]
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        
        // Query pool for tick cumulatives
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        
        // Calculate time-weighted average tick
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapWindow)));
        
        // Always round towards negative infinity (Uniswap convention)
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(twapWindow)) != 0)) {
            arithmeticMeanTick--;
        }
        
        // Get pool token ordering
        address token0 = IUniswapV3Pool(pool).token0();
        
        // Get token decimals for price scaling
        uint8 baseDecimals = IERC20Metadata(baseToken).decimals();
        uint8 quoteDecimals = IERC20Metadata(quoteToken).decimals();
        
        // Convert tick to sqrtPriceX96
        uint160 sqrtPriceX96 = _getSqrtRatioAtTick(arithmeticMeanTick);
        
        // Convert sqrtPriceX96 to actual price
        // sqrtPriceX96 = sqrt(price) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        // This gives price of token1 in terms of token0
        
        uint256 price;
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        
        if (baseToken == token0) {
            // Pool price is token1/token0, we want token0/token1 (invert)
            // price = 1 / (sqrtPriceX96^2 / 2^192) = 2^192 / sqrtPriceX96^2
            // Scale to quote decimals
            price = (uint256(1) << 192) * (10 ** quoteDecimals) / (sqrtPrice * sqrtPrice);
            // Adjust for base token decimals
            if (baseDecimals > 0) {
                price = price / (10 ** baseDecimals);
            }
        } else {
            // Pool price is token1/token0, baseToken is token1, so price is correct direction
            // price = sqrtPriceX96^2 / 2^192
            price = (sqrtPrice * sqrtPrice) >> 192;
            // Scale for decimals
            price = price * (10 ** quoteDecimals);
            if (baseDecimals > quoteDecimals) {
                price = price / (10 ** (baseDecimals - quoteDecimals));
            }
        }
        
        return price;
    }
    
    /**
     * @dev Calculate sqrt(1.0001^tick) * 2^96
     *      Ported from Uniswap V3 TickMath library
     *      Uses binary representation of tick for efficient computation
     * @param tick The tick value
     * @return sqrtPriceX96 The sqrt price in Q64.96 format
     */
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange();

        // Binary decomposition of tick for efficient sqrt(1.0001^tick) computation
        // Each bit position corresponds to a precomputed sqrt(1.0001^(2^i))
        uint256 ratio = absTick & 0x1 != 0 
            ? 0xfffcb933bd6fad37aa2d162d1a594001 
            : 0x100000000000000000000000000000000;
            
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        // For positive ticks, we computed 1/sqrt(price), so invert
        if (tick > 0) ratio = type(uint256).max / ratio;

        // Round up to nearest uint160
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

// ============ External Interfaces ============

/**
 * @title IUniswapV3Pool
 * @notice Minimal interface for Uniswap V3 pool TWAP queries
 */
interface IUniswapV3Pool {
    /// @notice Returns the address of token0
    function token0() external view returns (address);
    
    /// @notice Returns the address of token1
    function token1() external view returns (address);
    
    /// @notice Returns tick cumulative values for TWAP calculation
    /// @param secondsAgos Array of seconds in the past to query
    /// @return tickCumulatives Cumulative tick values at each timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity
    function observe(uint32[] calldata secondsAgos) 
        external 
        view 
        returns (
            int56[] memory tickCumulatives, 
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
}

/**
 * @title IERC20Metadata
 * @notice Minimal interface for ERC20 decimals query
 */
interface IERC20Metadata {
    /// @notice Returns the number of decimals for the token
    function decimals() external view returns (uint8);
}
