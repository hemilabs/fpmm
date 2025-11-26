// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SimpleRouter
 * @author Hemi Prediction Markets
 * @notice High-level UX wrapper for prediction market interactions
 * @dev Provides simplified, user-friendly interface for common prediction market operations
 *
 * This router simplifies user interactions by:
 * - Handling token approvals transparently (users only approve router once)
 * - Providing generic functions for any number of outcomes (2-8)
 * - Auto-detecting winning outcome for redemptions
 * - Batching multi-step operations into single transactions
 *
 * Supported Operations:
 * - Buy outcome tokens with collateral (any outcome index)
 * - Sell outcome tokens for collateral (any outcome index)
 * - Redeem winning tokens after market resolution
 * - Add/remove liquidity to/from markets
 * - Query prices, balances, and estimates
 *
 * Architecture:
 * - Thin wrapper around FpmmAMM and MarketCore
 * - Stateless except for immutable contract references
 * - No admin, owner, or governance functions
 * - All user funds flow through immediately - never held
 *
 * Security Model:
 * - ReentrancyGuard on all entry points
 * - Non-custodial - router never holds user funds
 * - Permissionless and ungoverned
 * - Implements ERC-1155 receiver for token handling
 *
 * Gas Optimizations:
 * - Lazy approval pattern (approve once, use forever)
 * - Minimal intermediate storage
 * - Direct forwarding to underlying contracts
 */
contract SimpleRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Errors ============

    /// @notice Address cannot be zero
    error ZeroAddress();

    /// @notice Amount cannot be zero
    error ZeroAmount();

    /// @notice Outcome index is out of valid range for this market
    error InvalidOutcomeIndex();

    /// @notice Market is not resolved yet
    error MarketNotResolved();

    // ============ Immutable References ============

    /// @notice MarketCore contract for market state and redemptions
    address public immutable marketCore;

    /// @notice FpmmAMM contract for trading and liquidity
    address public immutable fpmmAMM;

    /// @notice OutcomeToken1155 contract for outcome token transfers
    address public immutable outcomeToken1155;

    // ============ Events ============

    /**
     * @notice Emitted when user buys outcome tokens
     * @param marketId The market traded in
     * @param buyer Address of buyer
     * @param outcomeIndex Index of outcome purchased
     * @param collateralIn Collateral spent
     * @param tokensOut Outcome tokens received
     */
    event OutcomeBought(
        bytes32 indexed marketId,
        address indexed buyer,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 tokensOut
    );

    /**
     * @notice Emitted when user sells outcome tokens
     * @param marketId The market traded in
     * @param seller Address of seller
     * @param outcomeIndex Index of outcome sold
     * @param tokensIn Outcome tokens sold
     * @param collateralOut Collateral received
     */
    event OutcomeSold(
        bytes32 indexed marketId,
        address indexed seller,
        uint8 outcomeIndex,
        uint256 tokensIn,
        uint256 collateralOut
    );

    /**
     * @notice Emitted when user redeems winning tokens
     * @param marketId The resolved market
     * @param user Address of redeemer
     * @param outcomeIndex Index of outcome redeemed
     * @param amount Tokens redeemed
     * @param collateralReceived Collateral received
     */
    event WinningsRedeemed(
        bytes32 indexed marketId,
        address indexed user,
        uint8 outcomeIndex,
        uint256 amount,
        uint256 collateralReceived
    );

    /**
     * @notice Emitted when user adds liquidity
     * @param marketId The market
     * @param provider Address of LP
     * @param collateralAmount Collateral deposited
     * @param lpShares LP shares received
     */
    event LiquidityProvided(
        bytes32 indexed marketId,
        address indexed provider,
        uint256 collateralAmount,
        uint256 lpShares
    );

    /**
     * @notice Emitted when user removes liquidity
     * @param marketId The market
     * @param provider Address of LP
     * @param lpShares LP shares burned
     * @param collateralOut Collateral received
     */
    event LiquidityWithdrawn(
        bytes32 indexed marketId,
        address indexed provider,
        uint256 lpShares,
        uint256 collateralOut
    );

    // ============ Constructor ============

    /**
     * @notice Deploy the router with references to core contracts
     * @param _marketCore Address of MarketCore contract
     * @param _fpmmAMM Address of FpmmAMM contract
     * @param _outcomeToken1155 Address of OutcomeToken1155 contract
     */
    constructor(
        address _marketCore,
        address _fpmmAMM,
        address _outcomeToken1155
    ) {
        if (_marketCore == address(0)) revert ZeroAddress();
        if (_fpmmAMM == address(0)) revert ZeroAddress();
        if (_outcomeToken1155 == address(0)) revert ZeroAddress();

        marketCore = _marketCore;
        fpmmAMM = _fpmmAMM;
        outcomeToken1155 = _outcomeToken1155;
    }

    // ============ Trading Functions ============

    /**
     * @notice Buy outcome tokens for a specific outcome
     * @param marketId The market to trade in
     * @param outcomeIndex Index of the outcome to buy (0 to numOutcomes-1)
     * @param collateralIn Amount of collateral to spend
     * @param minTokensOut Minimum outcome tokens to receive (slippage protection)
     * @return tokensOut Actual outcome tokens received
     * @dev User must have approved this router to spend their collateral
     */
    function buyOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 minTokensOut
    ) external nonReentrant returns (uint256 tokensOut) {
        if (collateralIn == 0) revert ZeroAmount();

        // Get market config to validate outcome index
        (
            address collateralToken,
            uint8 numOutcomes,
            ,
        ) = IFpmmAMM(fpmmAMM).getFpmmMarketConfig(marketId);

        if (outcomeIndex >= numOutcomes) revert InvalidOutcomeIndex();

        // Transfer collateral from user to router
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralIn);

        // Ensure FpmmAMM has approval to spend router's collateral
        _ensureApproval(collateralToken, fpmmAMM, collateralIn);

        // Execute buy through FpmmAMM
        tokensOut = IFpmmAMM(fpmmAMM).buyOutcome(marketId, outcomeIndex, collateralIn, minTokensOut);

        // Transfer outcome tokens from router to user
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        IOutcomeToken1155(outcomeToken1155).safeTransferFrom(
            address(this),
            msg.sender,
            tokenId,
            tokensOut,
            ""
        );

        emit OutcomeBought(marketId, msg.sender, outcomeIndex, collateralIn, tokensOut);
    }

    /**
     * @notice Sell outcome tokens for collateral
     * @param marketId The market to trade in
     * @param outcomeIndex Index of the outcome to sell (0 to numOutcomes-1)
     * @param tokensIn Amount of outcome tokens to sell
     * @param minCollateralOut Minimum collateral to receive (slippage protection)
     * @return collateralOut Actual collateral received
     * @dev User must have approved this router for their outcome tokens
     */
    function sellOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 tokensIn,
        uint256 minCollateralOut
    ) external nonReentrant returns (uint256 collateralOut) {
        if (tokensIn == 0) revert ZeroAmount();

        // Get market config to validate outcome index
        (
            address collateralToken,
            uint8 numOutcomes,
            ,
        ) = IFpmmAMM(fpmmAMM).getFpmmMarketConfig(marketId);

        if (outcomeIndex >= numOutcomes) revert InvalidOutcomeIndex();

        // Transfer outcome tokens from user to router
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        IOutcomeToken1155(outcomeToken1155).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            tokensIn,
            ""
        );

        // Ensure FpmmAMM has approval to handle router's outcome tokens
        _ensureOutcomeApproval();

        // Execute sell through FpmmAMM
        collateralOut = IFpmmAMM(fpmmAMM).sellOutcome(marketId, outcomeIndex, tokensIn, minCollateralOut);

        // Transfer collateral to user
        IERC20(collateralToken).safeTransfer(msg.sender, collateralOut);

        emit OutcomeSold(marketId, msg.sender, outcomeIndex, tokensIn, collateralOut);
    }

    // ============ Redemption Functions ============

    /**
     * @notice Redeem winning outcome tokens for collateral (auto-detects winner)
     * @param marketId The resolved market
     * @param amount Amount of winning tokens to redeem
     * @return collateralOut Collateral received (1:1 with tokens)
     * @dev Automatically detects winning outcome - user just needs to specify amount
     *      User must have approved this router for their outcome tokens
     */
    function redeem(
        bytes32 marketId,
        uint256 amount
    ) external nonReentrant returns (uint256 collateralOut) {
        if (amount == 0) revert ZeroAmount();

        // Get market state to find winning outcome
        (
            IMarketCore.MarketStatus status,
            uint8 winningIndex,
            /* isInvalid */
        ) = IMarketCore(marketCore).getMarketState(marketId);

        if (status != IMarketCore.MarketStatus.Resolved) revert MarketNotResolved();

        // Transfer winning tokens from user to router
        uint256 tokenId = _computeOutcomeTokenId(marketId, winningIndex);
        IOutcomeToken1155(outcomeToken1155).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            amount,
            ""
        );

        // Ensure MarketCore has approval to burn router's outcome tokens
        _ensureOutcomeApproval();

        // Execute redemption through MarketCore
        IMarketCore(marketCore).redeemWinnings(marketId, winningIndex, amount);

        // Transfer collateral to user (1:1 redemption)
        address collateralToken = _getCollateralToken(marketId);
        collateralOut = amount;
        IERC20(collateralToken).safeTransfer(msg.sender, collateralOut);

        emit WinningsRedeemed(marketId, msg.sender, winningIndex, amount, collateralOut);
    }

    /**
     * @notice Redeem specific outcome tokens (for invalid markets with refund enabled)
     * @param marketId The resolved market
     * @param outcomeIndex Which outcome to redeem
     * @param amount Amount of tokens to redeem
     * @return collateralOut Collateral received
     * @dev Use this when FLAG_INVALID_REFUND is set and market resolved as invalid
     */
    function redeemOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 amount
    ) external nonReentrant returns (uint256 collateralOut) {
        if (amount == 0) revert ZeroAmount();

        // Transfer outcome tokens from user to router
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        IOutcomeToken1155(outcomeToken1155).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            amount,
            ""
        );

        // Ensure MarketCore has approval to burn router's outcome tokens
        _ensureOutcomeApproval();

        // Execute redemption through MarketCore
        IMarketCore(marketCore).redeemWinnings(marketId, outcomeIndex, amount);

        // Transfer collateral to user (1:1 redemption)
        address collateralToken = _getCollateralToken(marketId);
        collateralOut = amount;
        IERC20(collateralToken).safeTransfer(msg.sender, collateralOut);

        emit WinningsRedeemed(marketId, msg.sender, outcomeIndex, amount, collateralOut);
    }

    // ============ Liquidity Functions ============

    /**
     * @notice Add liquidity to a market
     * @param marketId The market to provide liquidity to
     * @param collateralAmount Amount of collateral to deposit
     * @param minLpShares Minimum LP shares to receive (slippage protection)
     * @return lpShares LP shares received
     * @dev User must have approved this router to spend their collateral
     *      LP shares are credited directly to the user in FpmmAMM
     */
    function addLiquidity(
        bytes32 marketId,
        uint256 collateralAmount,
        uint256 minLpShares
    ) external nonReentrant returns (uint256 lpShares) {
        if (collateralAmount == 0) revert ZeroAmount();

        // Get collateral token
        address collateralToken = _getCollateralToken(marketId);

        // Transfer collateral from user to router
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Ensure FpmmAMM has approval
        _ensureApproval(collateralToken, fpmmAMM, collateralAmount);

        // Add liquidity through FpmmAMM
        lpShares = IFpmmAMM(fpmmAMM).addLiquidity(marketId, collateralAmount, minLpShares);

        // Note: LP shares are tracked in FpmmAMM contract, credited to msg.sender
        // The router facilitated the transaction but shares belong to the caller

        emit LiquidityProvided(marketId, msg.sender, collateralAmount, lpShares);
    }

    /**
     * @notice Remove liquidity from a market
     * @param marketId The market to withdraw from
     * @param lpSharesIn LP shares to burn
     * @param minCollateralOut Minimum collateral to receive (slippage protection)
     * @return collateralOut Collateral received
     * @dev Returns collateral and possibly some outcome tokens
     *      For precise control over outcome token minimums, use FpmmAMM directly
     */
    function removeLiquidity(
        bytes32 marketId,
        uint256 lpSharesIn,
        uint256 minCollateralOut
    ) external nonReentrant returns (uint256 collateralOut) {
        if (lpSharesIn == 0) revert ZeroAmount();

        // Get number of outcomes for min amounts array
        (
            ,
            uint8 numOutcomes,
            ,
        ) = IFpmmAMM(fpmmAMM).getFpmmMarketConfig(marketId);

        // Create zero min amounts (simplified - for precise control use FpmmAMM directly)
        uint256[] memory minOutcomeAmounts = new uint256[](numOutcomes);

        // Remove liquidity through FpmmAMM
        (collateralOut, ) = IFpmmAMM(fpmmAMM).removeLiquidity(
            marketId,
            lpSharesIn,
            minCollateralOut,
            minOutcomeAmounts
        );

        // Transfer collateral to user
        address collateralToken = _getCollateralToken(marketId);
        IERC20(collateralToken).safeTransfer(msg.sender, collateralOut);

        emit LiquidityWithdrawn(marketId, msg.sender, lpSharesIn, collateralOut);
    }

    // ============ View Functions ============

    /**
     * @notice Get prices for all outcomes in a market
     * @param marketId The market to query
     * @return prices Array of prices for each outcome (18 decimals, sum to ~1e18)
     */
    function getOutcomePrices(bytes32 marketId) external view returns (uint256[] memory prices) {
        return IFpmmAMM(fpmmAMM).getOutcomePrices(marketId);
    }

    /**
     * @notice Estimate tokens received for buying a specific outcome
     * @param marketId The market
     * @param outcomeIndex Index of outcome to buy
     * @param collateralIn Amount of collateral to spend
     * @return tokensOut Estimated outcome tokens to receive
     */
    function estimateBuy(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 collateralIn
    ) external view returns (uint256 tokensOut) {
        return IFpmmAMM(fpmmAMM).calcBuyAmount(marketId, outcomeIndex, collateralIn);
    }

    /**
     * @notice Estimate collateral received for selling outcome tokens
     * @param marketId The market
     * @param outcomeIndex Index of outcome to sell
     * @param tokensIn Amount of outcome tokens to sell
     * @return collateralOut Estimated collateral to receive
     */
    function estimateSell(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 tokensIn
    ) external view returns (uint256 collateralOut) {
        return IFpmmAMM(fpmmAMM).calcSellReturn(marketId, outcomeIndex, tokensIn);
    }

    /**
     * @notice Get user's token balance for a specific outcome
     * @param marketId The market
     * @param outcomeIndex Index of outcome
     * @param user The user address
     * @return balance User's token balance for that outcome
     */
    function getUserOutcomeBalance(
        bytes32 marketId,
        uint8 outcomeIndex,
        address user
    ) external view returns (uint256 balance) {
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        return IOutcomeToken1155(outcomeToken1155).balanceOf(user, tokenId);
    }

    /**
     * @notice Get user's token balances for all outcomes in a market
     * @param marketId The market
     * @param user The user address
     * @return balances Array of balances for each outcome
     */
    function getUserAllOutcomeBalances(
        bytes32 marketId,
        address user
    ) external view returns (uint256[] memory balances) {
        (
            ,
            uint8 numOutcomes,
            ,
        ) = IFpmmAMM(fpmmAMM).getFpmmMarketConfig(marketId);

        balances = new uint256[](numOutcomes);
        for (uint8 i = 0; i < numOutcomes;) {
            uint256 tokenId = _computeOutcomeTokenId(marketId, i);
            balances[i] = IOutcomeToken1155(outcomeToken1155).balanceOf(user, tokenId);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get user's LP share balance for a market
     * @param marketId The market
     * @param user The user address
     * @return lpBalance User's LP share balance
     */
    function getUserLpShares(
        bytes32 marketId,
        address user
    ) external view returns (uint256 lpBalance) {
        return IFpmmAMM(fpmmAMM).lpShares(marketId, user);
    }

    /**
     * @notice Get market status and resolution info
     * @param marketId The market
     * @return status Market lifecycle status
     * @return winningOutcome Winning outcome index (valid only if Resolved)
     * @return isInvalid Whether market resolved as invalid
     */
    function getMarketStatus(bytes32 marketId) external view returns (
        IMarketCore.MarketStatus status,
        uint8 winningOutcome,
        bool isInvalid
    ) {
        return IMarketCore(marketCore).getMarketState(marketId);
    }

    /**
     * @notice Get market configuration
     * @param marketId The market
     * @return collateralToken The ERC-20 collateral token address
     * @return numOutcomes Number of outcomes in this market
     * @return liquidityParameterB LMSR liquidity parameter
     */
    function getMarketConfig(bytes32 marketId) external view returns (
        address collateralToken,
        uint8 numOutcomes,
        uint256 liquidityParameterB
    ) {
        (
            collateralToken,
            numOutcomes,
            liquidityParameterB,
        ) = IFpmmAMM(fpmmAMM).getFpmmMarketConfig(marketId);
    }

    /**
     * @notice Get collateral token for a market
     * @param marketId The market
     * @return collateralToken The ERC-20 collateral token address
     */
    function getCollateralToken(bytes32 marketId) external view returns (address) {
        return _getCollateralToken(marketId);
    }

    // ============ Internal Functions ============

    /**
     * @dev Get collateral token address from FpmmAMM market config
     */
    function _getCollateralToken(bytes32 marketId) internal view returns (address) {
        (
            address collateralToken,
            ,
            ,
        ) = IFpmmAMM(fpmmAMM).getFpmmMarketConfig(marketId);
        return collateralToken;
    }

    /**
     * @dev Compute ERC-1155 token ID from market ID and outcome index
     */
    function _computeOutcomeTokenId(
        bytes32 marketId,
        uint8 outcomeIndex
    ) internal pure returns (uint256) {
        return (uint256(marketId) << 8) | uint256(outcomeIndex);
    }

    /**
     * @dev Ensure router has given spender approval for ERC-20 token
     *      Uses lazy approval pattern - approves max once, never again
     */
    function _ensureApproval(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            // Use forceApprove for tokens that require zero-first approval
            IERC20(token).forceApprove(spender, type(uint256).max);
        }
    }

    /**
     * @dev Ensure MarketCore and FpmmAMM have approval for router's outcome tokens
     *      Approves both contracts once for all-token operations
     */
    function _ensureOutcomeApproval() internal {
        // Approve MarketCore if not already
        if (!IOutcomeToken1155(outcomeToken1155).isApprovedForAll(address(this), marketCore)) {
            IOutcomeToken1155(outcomeToken1155).setApprovalForAll(marketCore, true);
        }

        // Approve FpmmAMM if not already
        if (!IOutcomeToken1155(outcomeToken1155).isApprovedForAll(address(this), fpmmAMM)) {
            IOutcomeToken1155(outcomeToken1155).setApprovalForAll(fpmmAMM, true);
        }
    }

    // ============ ERC-1155 Receiver Implementation ============

    /**
     * @notice Handle receipt of single ERC-1155 token
     * @dev Required for router to receive outcome tokens during operations
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @notice Handle receipt of batch ERC-1155 tokens
     * @dev Required for router to receive multiple outcome tokens
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

// ============ External Interfaces ============

/**
 * @title IMarketCore
 * @notice Interface for MarketCore contract
 */
interface IMarketCore {
    enum MarketStatus { Open, Resolvable, Resolved }

    struct MarketParams {
        address collateralToken;
        uint64 marketDeadline;
        uint8 configFlags;
        uint8 numOutcomes;
        address oracle;
        bytes32 questionId;
    }

    function getMarketState(bytes32 marketId) external view returns (
        MarketStatus status,
        uint8 winningOutcomeIndex,
        bool isInvalid
    );

    function getMarketParams(bytes32 marketId) external view returns (MarketParams memory);
    function redeemWinnings(bytes32 marketId, uint8 outcomeIndex, uint256 amount) external;
}

/**
 * @title IFpmmAMM
 * @notice Interface for FpmmAMM contract
 */
interface IFpmmAMM {
    function buyOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 minOutcomeOut
    ) external returns (uint256);

    function sellOutcome(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 outcomeIn,
        uint256 minCollateralOut
    ) external returns (uint256);

    function addLiquidity(
        bytes32 marketId,
        uint256 collateralAmount,
        uint256 minLpSharesOut
    ) external returns (uint256);

    function removeLiquidity(
        bytes32 marketId,
        uint256 lpSharesIn,
        uint256 minCollateralOut,
        uint256[] calldata minOutcomeAmounts
    ) external returns (uint256, uint256[] memory);

    function getFpmmMarketConfig(bytes32 marketId) external view returns (
        address collateralToken,
        uint8 numOutcomes,
        uint256 liquidityParameterB,
        uint256[] memory outcomeTokenIds
    );

    function getOutcomePrices(bytes32 marketId) external view returns (uint256[] memory);
    function calcBuyAmount(bytes32 marketId, uint8 outcomeIndex, uint256 collateralIn) external view returns (uint256);
    function calcSellReturn(bytes32 marketId, uint8 outcomeIndex, uint256 outcomeIn) external view returns (uint256);
    function lpShares(bytes32 marketId, address provider) external view returns (uint256);
}

/**
 * @title IOutcomeToken1155
 * @notice Interface for OutcomeToken1155 contract
 */
interface IOutcomeToken1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);
}
