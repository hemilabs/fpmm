// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title FpmmAMM
 * @author Hemi Prediction Markets
 * @notice LMSR/FPMM-style Automated Market Maker for prediction markets
 * @dev Implements Hanson's Logarithmic Market Scoring Rule (LMSR) for multi-outcome markets
 * 
 * Architecture:
 * - Single contract manages AMM state for ALL markets (no per-market deployments)
 * - Each market has independent liquidity pool and pricing state
 * - Uses fixed-point math (18 decimals) for LMSR cost calculations
 * - Integrates with MarketCore for market validation and OutcomeToken1155 for tokens
 * 
 * LMSR Mathematics:
 * - Cost function: C(q) = b * ln(Σ exp(q_i / b))
 * - Price for outcome i: p_i = exp(q_i / b) / Σ exp(q_j / b)
 * - Buy cost: C(q + Δ*e_i) - C(q) where e_i is unit vector for outcome i
 * - Sell return: C(q) - C(q - Δ*e_i)
 * - Parameter b controls liquidity depth (higher = more liquid, less price impact)
 * 
 * Security Model:
 * - Permissionless market registration and trading
 * - No admin functions, pause mechanisms, or governance
 * - ReentrancyGuard on all state-changing operations
 * - Slippage protection via min/max parameters on all trades
 * - Validates against MarketCore to ensure market exists and is open
 * 
 * Gas Optimizations:
 * - O(n) operations where n = numOutcomes (typically 2-4, max 8)
 * - Packed storage structs
 * - Storage pointers to minimize SLOAD
 * - Unchecked arithmetic where overflow impossible
 * - Binary search for buy amount calculation
 */
contract FpmmAMM is ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    
    /// @notice FPMM market already registered for this marketId
    error MarketAlreadyRegistered();
    
    /// @notice No FPMM market registered for this marketId
    error MarketNotRegistered();
    
    /// @notice Underlying market is not open for trading
    error MarketNotOpen();
    
    /// @notice Outcome index exceeds number of outcomes
    error InvalidOutcomeIndex();
    
    /// @notice Number of outcomes outside valid range
    error InvalidNumOutcomes();
    
    /// @notice Liquidity parameter b cannot be zero
    error InvalidLiquidityParameter();
    
    /// @notice AMM has insufficient collateral for this operation
    error InsufficientCollateral();
    
    /// @notice User has insufficient outcome tokens
    error InsufficientOutcomeTokens();
    
    /// @notice Trade output is below minimum specified (slippage protection)
    error SlippageExceeded();
    
    /// @notice Amount cannot be zero
    error ZeroAmount();
    
    /// @notice Array lengths do not match
    error ArrayLengthMismatch();
    
    /// @notice Market has no liquidity - must add liquidity first
    error NoLiquidity();
    
    /// @notice User has insufficient LP shares
    error InsufficientLpShares();
    
    /// @notice Market parameters don't match MarketCore
    error MarketCoreMismatch();
    
    /// @notice Invalid market ID
    error InvalidMarketId();

    // ============ Constants ============
    
    /// @notice Fixed-point precision (18 decimals, matching most ERC-20 tokens)
    uint256 private constant PRECISION = 1e18;
    
    /// @notice Maximum safe input for exp() to prevent overflow (~e^130)
    int256 private constant MAX_EXP_INPUT = 130 * 1e18;
    
    /// @notice Minimum safe input for exp() (~e^-41 ≈ 0)
    int256 private constant MIN_EXP_INPUT = -41 * 1e18;
    
    /// @notice Initial LP shares minted to first liquidity provider
    /// @dev Arbitrary but reasonable starting point for share accounting
    uint256 private constant INITIAL_LP_SHARES = 1000 * 1e18;

    // ============ Types ============
    
    /**
     * @notice FPMM market configuration (immutable after registration)
     * @dev Cached from MarketCore for gas efficiency
     */
    struct FpmmMarketConfig {
        address collateralToken;     // ERC-20 collateral token
        uint8 numOutcomes;           // Number of outcomes (2-8)
        uint256 liquidityParameterB; // LMSR "b" parameter (liquidity depth)
    }
    
    /**
     * @notice FPMM market mutable state
     */
    struct FpmmMarketState {
        uint256 collateralBalance;   // Total collateral held by AMM for this market
        uint256 lpShareSupply;       // Total LP shares outstanding
    }

    // ============ Storage ============
    
    /// @notice MarketCore contract reference (immutable)
    address public immutable marketCore;
    
    /// @notice OutcomeToken1155 contract reference (immutable)
    address public immutable outcomeToken1155;
    
    /// @notice Market configurations indexed by marketId
    mapping(bytes32 => FpmmMarketConfig) private _configs;
    
    /// @notice Market states indexed by marketId
    mapping(bytes32 => FpmmMarketState) private _states;
    
    /// @notice Net outcome tokens sold per outcome
    /// @dev marketId => outcomeIndex => net tokens sold
    ///      Positive = AMM has sold tokens (users hold them)
    ///      Negative = AMM has bought back tokens (AMM holds excess)
    mapping(bytes32 => mapping(uint8 => int256)) public netOutcomeTokensSold;
    
    /// @notice LP share balances per market per provider
    /// @dev marketId => provider => share balance
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    
    /// @notice Quick check if FPMM market is registered
    mapping(bytes32 => bool) public isRegistered;

    // ============ Events ============
    
    /**
     * @notice Emitted when FPMM market is registered
     * @param marketId The MarketCore market identifier
     * @param collateralToken ERC-20 collateral token
     * @param numOutcomes Number of possible outcomes
     * @param liquidityParameterB LMSR liquidity parameter
     */
    event FpmmMarketRegistered(
        bytes32 indexed marketId,
        address collateralToken,
        uint8 numOutcomes,
        uint256 liquidityParameterB
    );
    
    /**
     * @notice Emitted when user buys outcome tokens
     * @param marketId The market traded in
     * @param buyer Address of buyer
     * @param outcomeIndex Which outcome was bought
     * @param collateralIn Collateral spent
     * @param outcomeTokensOut Outcome tokens received
     */
    event OutcomeBought(
        bytes32 indexed marketId,
        address indexed buyer,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 outcomeTokensOut
    );
    
    /**
     * @notice Emitted when user sells outcome tokens
     * @param marketId The market traded in
     * @param seller Address of seller
     * @param outcomeIndex Which outcome was sold
     * @param outcomeTokensIn Outcome tokens sold
     * @param collateralOut Collateral received
     */
    event OutcomeSold(
        bytes32 indexed marketId,
        address indexed seller,
        uint8 outcomeIndex,
        uint256 outcomeTokensIn,
        uint256 collateralOut
    );
    
    /**
     * @notice Emitted when liquidity is added
     * @param marketId The market receiving liquidity
     * @param provider Address of liquidity provider
     * @param collateralAmount Collateral deposited
     * @param lpSharesMinted LP shares received
     */
    event LiquidityAdded(
        bytes32 indexed marketId,
        address indexed provider,
        uint256 collateralAmount,
        uint256 lpSharesMinted
    );
    
    /**
     * @notice Emitted when liquidity is removed
     * @param marketId The market losing liquidity
     * @param provider Address of liquidity provider
     * @param lpSharesBurned LP shares burned
     * @param collateralOut Collateral withdrawn
     * @param outcomeTokensOut Outcome tokens withdrawn (per outcome)
     */
    event LiquidityRemoved(
        bytes32 indexed marketId,
        address indexed provider,
        uint256 lpSharesBurned,
        uint256 collateralOut,
        uint256[] outcomeTokensOut
    );

    // ============ Constructor ============
    
    /**
     * @notice Deploy FpmmAMM with references to core contracts
     * @param _marketCore Address of MarketCore contract
     * @param _outcomeToken1155 Address of OutcomeToken1155 contract
     * @dev OutcomeToken1155 must list this contract as an authorized minter
     */
    constructor(address _marketCore, address _outcomeToken1155) {
        marketCore = _marketCore;
        outcomeToken1155 = _outcomeToken1155;
    }

    // ============ Market Registration ============
    
    /**
     * @notice Register an FPMM market for an existing MarketCore market
     * @param marketId The MarketCore market identifier
     * @param liquidityParameterB The LMSR "b" parameter
     * @dev Permissionless - validates market exists in MarketCore
     *      Higher b = more liquidity depth, less price impact per trade
     *      Typical b values: 100-10000 * 1e18 depending on expected volume
     */
    function registerFpmmMarket(
        bytes32 marketId,
        uint256 liquidityParameterB
    ) external {
        if (isRegistered[marketId]) revert MarketAlreadyRegistered();
        if (liquidityParameterB == 0) revert InvalidLiquidityParameter();
        
        // Fetch and validate market params from MarketCore
        IMarketCore.MarketParams memory params = IMarketCore(marketCore).getMarketParams(marketId);
        
        if (params.numOutcomes < 2 || params.numOutcomes > 8) {
            revert InvalidNumOutcomes();
        }
        
        // Store configuration
        isRegistered[marketId] = true;
        
        _configs[marketId] = FpmmMarketConfig({
            collateralToken: params.collateralToken,
            numOutcomes: params.numOutcomes,
            liquidityParameterB: liquidityParameterB
        });
        
        // Initialize state (collateralBalance and lpShareSupply start at 0)
        _states[marketId] = FpmmMarketState({
            collateralBalance: 0,
            lpShareSupply: 0
        });
        
        // netOutcomeTokensSold[marketId][i] implicitly starts at 0 for all outcomes
        
        emit FpmmMarketRegistered(
            marketId,
            params.collateralToken,
            params.numOutcomes,
            liquidityParameterB
        );
    }

    // ============ Trading Functions ============
    
    /**
     * @notice Buy outcome tokens using collateral
     * @param marketId The market to trade in
     * @param outcomeIndex Which outcome to buy (0 to numOutcomes-1)
     * @param collateralIn Amount of collateral to spend
     * @param minOutcomeOut Minimum outcome tokens to receive (slippage protection)
     * @return outcomeOut Actual outcome tokens received
     * @dev Caller must have approved this contract to spend collateralIn
     *      Uses LMSR to calculate fair price based on current market state
     */
    function buyOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 minOutcomeOut
    ) external nonReentrant returns (uint256 outcomeOut) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        if (collateralIn == 0) revert ZeroAmount();
        
        FpmmMarketConfig storage config = _configs[marketId];
        FpmmMarketState storage state = _states[marketId];
        
        if (outcomeIndex >= config.numOutcomes) revert InvalidOutcomeIndex();
        if (state.lpShareSupply == 0) revert NoLiquidity();
        
        // Verify market is still open in MarketCore
        if (!IMarketCore(marketCore).isMarketOpen(marketId)) {
            revert MarketNotOpen();
        }
        
        // Calculate outcome tokens using LMSR
        outcomeOut = _calcBuyAmount(marketId, outcomeIndex, collateralIn);
        
        // Slippage check
        if (outcomeOut < minOutcomeOut) revert SlippageExceeded();
        
        // Transfer collateral from buyer to AMM
        IERC20(config.collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralIn
        );
        
        // Update AMM state
        state.collateralBalance += collateralIn;
        netOutcomeTokensSold[marketId][outcomeIndex] += int256(outcomeOut);
        
        // Mint outcome tokens to buyer
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        IOutcomeToken1155(outcomeToken1155).mint(msg.sender, tokenId, outcomeOut, "");
        
        emit OutcomeBought(marketId, msg.sender, outcomeIndex, collateralIn, outcomeOut);
    }
    
    /**
     * @notice Sell outcome tokens for collateral
     * @param marketId The market to trade in
     * @param outcomeIndex Which outcome to sell (0 to numOutcomes-1)
     * @param outcomeIn Amount of outcome tokens to sell
     * @param minCollateralOut Minimum collateral to receive (slippage protection)
     * @return collateralOut Actual collateral received
     * @dev Caller must have approved this contract (via OutcomeToken1155) to burn tokens
     *      Uses LMSR to calculate fair price based on current market state
     */
    function sellOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 outcomeIn,
        uint256 minCollateralOut
    ) external nonReentrant returns (uint256 collateralOut) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        if (outcomeIn == 0) revert ZeroAmount();
        
        FpmmMarketConfig storage config = _configs[marketId];
        FpmmMarketState storage state = _states[marketId];
        
        if (outcomeIndex >= config.numOutcomes) revert InvalidOutcomeIndex();
        if (state.lpShareSupply == 0) revert NoLiquidity();
        
        // Verify market is still open in MarketCore
        if (!IMarketCore(marketCore).isMarketOpen(marketId)) {
            revert MarketNotOpen();
        }
        
        // Calculate collateral return using LMSR
        collateralOut = _calcSellReturn(marketId, outcomeIndex, outcomeIn);
        
        // Slippage and solvency checks
        if (collateralOut < minCollateralOut) revert SlippageExceeded();
        if (collateralOut > state.collateralBalance) revert InsufficientCollateral();
        
        // Burn outcome tokens from seller (requires approval)
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        IOutcomeToken1155(outcomeToken1155).burn(msg.sender, tokenId, outcomeIn);
        
        // Update AMM state
        state.collateralBalance -= collateralOut;
        netOutcomeTokensSold[marketId][outcomeIndex] -= int256(outcomeIn);
        
        // Transfer collateral to seller
        IERC20(config.collateralToken).safeTransfer(msg.sender, collateralOut);
        
        emit OutcomeSold(marketId, msg.sender, outcomeIndex, outcomeIn, collateralOut);
    }

    // ============ Liquidity Functions ============
    
    /**
     * @notice Add liquidity to an FPMM market
     * @param marketId The market to provide liquidity to
     * @param collateralAmount Amount of collateral to deposit
     * @param minLpSharesOut Minimum LP shares to receive (slippage protection)
     * @return lpSharesOut LP shares minted to provider
     * @dev First LP sets initial state, subsequent LPs get proportional shares
     *      Caller must have approved this contract to spend collateral
     */
    /**
     * @notice Add liquidity to an FPMM market
     * @param marketId The market to provide liquidity to
     * @param collateralAmount Amount of collateral to deposit
     * @param minLpSharesOut Minimum LP shares to receive (slippage protection)
     * @param receiver The address to receive the LP shares
     * @return lpSharesOut LP shares minted to provider
     * @dev First LP sets initial state, subsequent LPs get proportional shares
     *      Caller must have approved this contract to spend collateral
     */
    function addLiquidity(
        bytes32 marketId,
        uint256 collateralAmount,
        uint256 minLpSharesOut,
        address receiver
    ) external nonReentrant returns (uint256 lpSharesOut) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        if (collateralAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAmount(); // Reuse ZeroAmount for ZeroAddress to save space/gas? Or separate error? stick to standard checks if available or just logic.
        
        // Verify market is still open
        if (!IMarketCore(marketCore).isMarketOpen(marketId)) {
            revert MarketNotOpen();
        }
        
        FpmmMarketConfig storage config = _configs[marketId];
        FpmmMarketState storage state = _states[marketId];
        
        // Transfer collateral from LP (msg.sender) to AMM
        // Note: msg.sender provides the collateral, receiver gets the shares
        IERC20(config.collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        
        if (state.lpShareSupply == 0) {
            // First LP - mint initial shares (sets baseline)
            lpSharesOut = INITIAL_LP_SHARES;
        } else {
            // Subsequent LPs - proportional to existing pool
            lpSharesOut = (collateralAmount * state.lpShareSupply) / state.collateralBalance;
        }
        
        // Slippage check
        if (lpSharesOut < minLpSharesOut) revert SlippageExceeded();
        
        // Update state
        state.collateralBalance += collateralAmount;
        state.lpShareSupply += lpSharesOut;
        lpShares[marketId][receiver] += lpSharesOut; // Credit ONLY the receiver
        
        // Event should reflect the receiver as the provider of liquidity in terms of ownership
        // But maybe we want to know who paid? Ideally receiver is what matters for "Who Added Liquidity" in UI if we use this event.
        emit LiquidityAdded(marketId, receiver, collateralAmount, lpSharesOut);
    }
    
    /**
     * @notice Remove liquidity from an FPMM market
     * @param marketId The market to withdraw from
     * @param lpSharesIn LP shares to burn
     * @param minCollateralOut Minimum collateral to receive
     * @param minOutcomeAmounts Minimum amount per outcome token (array length = numOutcomes)
     * @return collateralOut Collateral withdrawn
     * @return outcomeTokensOut Outcome tokens withdrawn (per outcome index)
     * @dev LP receives pro-rata share of collateral and any excess outcome tokens held by AMM
     *      Can be called even after market closes to retrieve funds
     */
    function removeLiquidity(
        bytes32 marketId,
        uint256 lpSharesIn,
        uint256 minCollateralOut,
        uint256[] calldata minOutcomeAmounts
    ) external nonReentrant returns (
        uint256 collateralOut,
        uint256[] memory outcomeTokensOut
    ) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        if (lpSharesIn == 0) revert ZeroAmount();
        
        FpmmMarketConfig storage config = _configs[marketId];
        FpmmMarketState storage state = _states[marketId];
        
        if (minOutcomeAmounts.length != config.numOutcomes) {
            revert ArrayLengthMismatch();
        }
        
        uint256 userShares = lpShares[marketId][msg.sender];
        if (lpSharesIn > userShares) revert InsufficientLpShares();
        
        // Calculate pro-rata share (18 decimal precision)
        uint256 shareRatio = (lpSharesIn * PRECISION) / state.lpShareSupply;
        
        // Calculate collateral to return
        collateralOut = (state.collateralBalance * shareRatio) / PRECISION;
        if (collateralOut < minCollateralOut) revert SlippageExceeded();
        
        // Calculate outcome tokens to return (LP gets share of AMM's held tokens)
        outcomeTokensOut = new uint256[](config.numOutcomes);
        
        for (uint8 i = 0; i < config.numOutcomes;) {
            int256 netSold = netOutcomeTokensSold[marketId][i];
            
            // If netSold < 0, AMM holds excess tokens (bought back from market)
            // LP gets their proportional share of these excess holdings
            if (netSold < 0) {
                uint256 excessHeld = uint256(-netSold);
                outcomeTokensOut[i] = (excessHeld * shareRatio) / PRECISION;
            } else {
                outcomeTokensOut[i] = 0;
            }
            
            // Slippage check per outcome
            if (outcomeTokensOut[i] < minOutcomeAmounts[i]) revert SlippageExceeded();
            
            unchecked { ++i; }
        }
        
        // Update state
        state.collateralBalance -= collateralOut;
        state.lpShareSupply -= lpSharesIn;
        lpShares[marketId][msg.sender] = userShares - lpSharesIn;
        
        // Transfer collateral to LP
        IERC20(config.collateralToken).safeTransfer(msg.sender, collateralOut);
        
        // Transfer outcome tokens to LP (if any)
        for (uint8 i = 0; i < config.numOutcomes;) {
            if (outcomeTokensOut[i] > 0) {
                uint256 tokenId = _computeOutcomeTokenId(marketId, i);
                IOutcomeToken1155(outcomeToken1155).safeTransferFrom(
                    address(this),
                    msg.sender,
                    tokenId,
                    outcomeTokensOut[i],
                    ""
                );
                
                // Adjust net sold (AMM no longer holds these)
                netOutcomeTokensSold[marketId][i] += int256(outcomeTokensOut[i]);
            }
            unchecked { ++i; }
        }
        
        emit LiquidityRemoved(marketId, msg.sender, lpSharesIn, collateralOut, outcomeTokensOut);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get FPMM market configuration
     * @param marketId The market identifier
     * @return collateralToken ERC-20 collateral token address
     * @return numOutcomes Number of possible outcomes
     * @return liquidityParameterB LMSR liquidity parameter
     * @return outcomeTokenIds Array of ERC-1155 token IDs for each outcome
     */
    function getFpmmMarketConfig(bytes32 marketId) external view returns (
        address collateralToken,
        uint8 numOutcomes,
        uint256 liquidityParameterB,
        uint256[] memory outcomeTokenIds
    ) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        
        FpmmMarketConfig storage config = _configs[marketId];
        
        collateralToken = config.collateralToken;
        numOutcomes = config.numOutcomes;
        liquidityParameterB = config.liquidityParameterB;
        
        outcomeTokenIds = new uint256[](numOutcomes);
        for (uint8 i = 0; i < numOutcomes;) {
            outcomeTokenIds[i] = _computeOutcomeTokenId(marketId, i);
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get FPMM market state
     * @param marketId The market identifier
     * @return collateralBalance Total collateral held by AMM
     * @return netTokensSold Net tokens sold per outcome (positive = users hold, negative = AMM holds)
     * @return lpShareSupply Total LP shares outstanding
     */
    function getFpmmMarketState(bytes32 marketId) external view returns (
        uint256 collateralBalance,
        int256[] memory netTokensSold,
        uint256 lpShareSupply
    ) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        
        FpmmMarketConfig storage config = _configs[marketId];
        FpmmMarketState storage state = _states[marketId];
        
        collateralBalance = state.collateralBalance;
        lpShareSupply = state.lpShareSupply;
        
        netTokensSold = new int256[](config.numOutcomes);
        for (uint8 i = 0; i < config.numOutcomes;) {
            netTokensSold[i] = netOutcomeTokensSold[marketId][i];
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Get current prices for all outcomes
     * @param marketId The market identifier
     * @return prices Array of prices in 18 decimals (sum ≈ 1e18)
     * @dev Uses LMSR formula: p_i = exp(q_i / b) / Σ exp(q_j / b)
     */
    function getOutcomePrices(bytes32 marketId) external view returns (uint256[] memory prices) {
        if (!isRegistered[marketId]) revert MarketNotRegistered();
        
        FpmmMarketConfig storage config = _configs[marketId];
        uint8 n = config.numOutcomes;
        uint256 b = config.liquidityParameterB;
        
        prices = new uint256[](n);
        
        // Calculate exp(q_i / b) for each outcome
        uint256[] memory expValues = new uint256[](n);
        uint256 sumExp = 0;
        
        for (uint8 i = 0; i < n;) {
            int256 qi = netOutcomeTokensSold[marketId][i];
            int256 scaled = (qi * int256(PRECISION)) / int256(b);
            expValues[i] = _exp(scaled);
            sumExp += expValues[i];
            unchecked { ++i; }
        }
        
        // Price_i = exp(q_i / b) / Σ exp(q_j / b)
        for (uint8 i = 0; i < n;) {
            prices[i] = (expValues[i] * PRECISION) / sumExp;
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Estimate outcome tokens from buying (view function)
     * @param marketId The market
     * @param outcomeIndex Which outcome to buy
     * @param collateralIn Collateral amount to spend
     * @return outcomeOut Estimated outcome tokens to receive
     */
    function calcBuyAmount(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 collateralIn
    ) external view returns (uint256) {
        return _calcBuyAmount(marketId, outcomeIndex, collateralIn);
    }
    
    /**
     * @notice Estimate collateral from selling (view function)
     * @param marketId The market
     * @param outcomeIndex Which outcome to sell
     * @param outcomeIn Outcome tokens to sell
     * @return collateralOut Estimated collateral to receive
     */
    function calcSellReturn(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 outcomeIn
    ) external view returns (uint256) {
        return _calcSellReturn(marketId, outcomeIndex, outcomeIn);
    }

    // ============ LMSR Core Math ============
    
    /**
     * @dev Calculate outcome tokens received for collateral spent
     *      Uses binary search to find Δ such that C(q + Δ*e_i) - C(q) = collateralIn
     * @param marketId The market
     * @param outcomeIndex Which outcome being bought
     * @param collateralIn Collateral being spent
     * @return Amount of outcome tokens to receive
     */
    function _calcBuyAmount(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 collateralIn
    ) internal view returns (uint256) {
        FpmmMarketConfig storage config = _configs[marketId];
        uint256 b = config.liquidityParameterB;
        uint8 n = config.numOutcomes;
        
        // Current cost C(q)
        uint256 currentCost = _lmsrCost(marketId, n, b);
        
        // Target cost after spending collateral
        uint256 targetCost = currentCost + collateralIn;
        
        // Binary search for token amount that achieves target cost
        uint256 low = 0;
        uint256 high = collateralIn * 2; // Upper bound with buffer
        
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            uint256 costAfter = _lmsrCostAfterBuy(marketId, outcomeIndex, mid, n, b);
            
            if (costAfter <= targetCost) {
                low = mid;
            } else {
                high = mid;
            }
        }
        
        return low;
    }
    
    /**
     * @dev Calculate collateral received for outcome tokens sold
     *      Uses LMSR: return = C(q) - C(q - Δ*e_i)
     * @param marketId The market
     * @param outcomeIndex Which outcome being sold
     * @param outcomeIn Tokens being sold
     * @return Collateral to return to seller
     */
    function _calcSellReturn(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 outcomeIn
    ) internal view returns (uint256) {
        FpmmMarketConfig storage config = _configs[marketId];
        uint256 b = config.liquidityParameterB;
        uint8 n = config.numOutcomes;
        
        // Current cost C(q)
        uint256 currentCost = _lmsrCost(marketId, n, b);
        
        // Cost after sell C(q - Δ*e_i)
        uint256 costAfter = _lmsrCostAfterSell(marketId, outcomeIndex, outcomeIn, n, b);
        
        // Return is the difference (cost decreases when selling)
        if (currentCost > costAfter) {
            return currentCost - costAfter;
        }
        return 0;
    }
    
    /**
     * @dev Calculate LMSR cost function: C(q) = b * ln(Σ exp(q_i / b))
     * @param marketId The market
     * @param n Number of outcomes
     * @param b Liquidity parameter
     * @return The current cost value
     */
    function _lmsrCost(
        bytes32 marketId,
        uint8 n,
        uint256 b
    ) internal view returns (uint256) {
        uint256 sumExp = 0;
        
        for (uint8 i = 0; i < n;) {
            int256 qi = netOutcomeTokensSold[marketId][i];
            int256 scaled = (qi * int256(PRECISION)) / int256(b);
            sumExp += _exp(scaled);
            unchecked { ++i; }
        }
        
        // C = b * ln(sumExp)
        return (b * _ln(sumExp)) / PRECISION;
    }
    
    /**
     * @dev Calculate LMSR cost after hypothetically buying `amount` of outcome `idx`
     */
    function _lmsrCostAfterBuy(
        bytes32 marketId,
        uint8 idx,
        uint256 amount,
        uint8 n,
        uint256 b
    ) internal view returns (uint256) {
        uint256 sumExp = 0;
        
        for (uint8 i = 0; i < n;) {
            int256 qi = netOutcomeTokensSold[marketId][i];
            if (i == idx) {
                qi += int256(amount);
            }
            int256 scaled = (qi * int256(PRECISION)) / int256(b);
            sumExp += _exp(scaled);
            unchecked { ++i; }
        }
        
        return (b * _ln(sumExp)) / PRECISION;
    }
    
    /**
     * @dev Calculate LMSR cost after hypothetically selling `amount` of outcome `idx`
     */
    function _lmsrCostAfterSell(
        bytes32 marketId,
        uint8 idx,
        uint256 amount,
        uint8 n,
        uint256 b
    ) internal view returns (uint256) {
        uint256 sumExp = 0;
        
        for (uint8 i = 0; i < n;) {
            int256 qi = netOutcomeTokensSold[marketId][i];
            if (i == idx) {
                qi -= int256(amount);
            }
            int256 scaled = (qi * int256(PRECISION)) / int256(b);
            sumExp += _exp(scaled);
            unchecked { ++i; }
        }
        
        return (b * _ln(sumExp)) / PRECISION;
    }

    // ============ Fixed-Point Math Library ============
    
    /**
     * @dev Compute e^x for x in fixed-point (18 decimals)
     *      Uses range reduction + Taylor series for accuracy
     * @param x Input value (can be negative)
     * @return e^x in 18 decimal fixed-point
     */
    function _exp(int256 x) internal pure returns (uint256) {
        // Clamp to safe range to prevent overflow
        if (x > MAX_EXP_INPUT) x = MAX_EXP_INPUT;
        if (x < MIN_EXP_INPUT) return 0;
        
        // e^0 = 1
        if (x == 0) return PRECISION;
        
        // Handle negative exponents separately
        bool negative = x < 0;
        if (negative) x = -x;
        
        // Range reduction: e^x = e^k * e^r where k is integer part, r is fractional
        uint256 e1 = 2718281828459045235; // e^1 in 18 decimals
        
        uint256 k = uint256(x) / PRECISION;
        uint256 r = uint256(x) % PRECISION;
        
        // Compute e^k via binary exponentiation
        uint256 result = PRECISION;
        uint256 ePower = e1;
        
        while (k > 0) {
            if (k & 1 == 1) {
                result = (result * ePower) / PRECISION;
            }
            ePower = (ePower * ePower) / PRECISION;
            k >>= 1;
        }
        
        // Compute e^r using Taylor series (for small r < 1)
        // e^r ≈ 1 + r + r²/2! + r³/3! + ...
        if (r > 0) {
            uint256 term = PRECISION;
            uint256 sum = PRECISION;
            
            for (uint256 i = 1; i <= 12;) {
                term = (term * r) / (i * PRECISION);
                sum += term;
                if (term < 1) break; // Negligible contribution
                unchecked { ++i; }
            }
            
            result = (result * sum) / PRECISION;
        }
        
        // For negative input: e^(-x) = 1/e^x
        if (negative) {
            result = (PRECISION * PRECISION) / result;
        }
        
        return result;
    }
    
    /**
     * @dev Compute ln(x) for x in fixed-point (18 decimals)
     *      Uses range reduction + series expansion
     * @param x Input value (must be positive)
     * @return ln(x) in 18 decimal fixed-point
     */
    function _ln(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        if (x == PRECISION) return 0; // ln(1) = 0
        
        uint256 e1 = 2718281828459045235; // e^1
        uint256 ln1 = PRECISION; // ln(e) = 1
        
        uint256 result = 0;
        
        // Range reduction: factor out powers of e for large x
        while (x >= e1) {
            x = (x * PRECISION) / e1;
            result += ln1;
        }
        
        // Range reduction: factor in powers of e for small x
        while (x < PRECISION) {
            x = (x * e1) / PRECISION;
            result -= ln1;
        }
        
        // Now x is in [1, e), use series: ln(x) = 2 * Σ (1/(2n+1)) * ((x-1)/(x+1))^(2n+1)
        uint256 y = ((x - PRECISION) * PRECISION) / (x + PRECISION);
        uint256 y2 = (y * y) / PRECISION;
        
        uint256 term = y;
        uint256 sum = term;
        
        for (uint256 i = 1; i <= 20;) {
            term = (term * y2) / PRECISION;
            uint256 contribution = term / (2 * i + 1);
            if (contribution == 0) break;
            sum += contribution;
            unchecked { ++i; }
        }
        
        // Multiply by 2 (from series formula)
        result += 2 * sum;
        
        return result;
    }

    // ============ Internal Helpers ============
    
    /**
     * @dev Compute ERC-1155 token ID from market ID and outcome index
     * @param marketId The market identifier
     * @param outcomeIndex The outcome index
     * @return Token ID with marketId in upper 248 bits, outcomeIndex in lower 8 bits
     */
    function _computeOutcomeTokenId(
        bytes32 marketId,
        uint8 outcomeIndex
    ) internal pure returns (uint256) {
        return (uint256(marketId) << 8) | uint256(outcomeIndex);
    }

    // ============ ERC-1155 Receiver Implementation ============
    
    /**
     * @notice Handle receipt of single ERC-1155 token
     * @dev Required for AMM to receive outcome tokens during sells
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    /**
     * @notice Handle receipt of batch ERC-1155 tokens
     * @dev Required for AMM to receive multiple outcome tokens
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    
    /**
     * @notice ERC-165 interface detection
     */
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}

// ============ External Interfaces ============

/**
 * @title IMarketCore
 * @notice Interface for MarketCore contract
 */
interface IMarketCore {
    struct MarketParams {
        address collateralToken;
        uint64 marketDeadline;
        uint8 configFlags;
        uint8 numOutcomes;
        address oracle;
        bytes32 questionId;
    }
    
    function getMarketParams(bytes32 marketId) external view returns (MarketParams memory);
    function isMarketOpen(bytes32 marketId) external view returns (bool);
    function depositCollateral(bytes32 marketId, uint256 amount) external;
}

/**
 * @title IOutcomeToken1155
 * @notice Interface for OutcomeToken1155 contract
 */
interface IOutcomeToken1155 {
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}
