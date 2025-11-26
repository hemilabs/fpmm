// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOutcomeOracle} from "./interfaces/IOutcomeOracle.sol";

/**
 * @title MarketCore
 * @author Hemi Prediction Markets
 * @notice Market registry, resolution layer, and collateral vault for prediction markets
 * @dev Central contract managing market lifecycle from creation through resolution to redemption
 * 
 * Architecture:
 * - Single contract holds all market data and collateral (no per-market vaults)
 * - Markets are created permissionlessly with immutable parameters
 * - Resolution is triggered via oracle callbacks
 * - Winning token holders redeem 1:1 for collateral
 * - Works in conjunction with OutcomeToken1155 and FpmmAMM
 * 
 * Market Lifecycle:
 * 1. createMarket() - Register market with oracle reference
 * 2. Trading via FpmmAMM (deposits collateral here)
 * 3. requestResolution() - Trigger oracle after deadline
 * 4. finalizeMarket() - Read oracle result and set winner
 * 5. redeemWinnings() - Burn winning tokens for collateral
 * 
 * Security Model:
 * - Fully permissionless - no admin, owner, or governance
 * - Not pausable - fully unstoppable once deployed
 * - Non-custodial - collateral only released on valid redemption
 * - Immutable market parameters after creation
 * - ReentrancyGuard on all external collateral transfers
 * 
 * Gas Optimizations:
 * - Packed structs for storage efficiency (MarketParams fits in 3 slots)
 * - O(1) operations throughout - no loops
 * - Separate existence mapping for gas-efficient checks
 * - Storage pointers to avoid repeated SLOAD
 */
contract MarketCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    
    /// @notice Market with this ID already exists
    error MarketAlreadyExists();
    
    /// @notice No market found with this ID
    error MarketNotFound();
    
    /// @notice Market is not in Open status
    error MarketNotOpen();
    
    /// @notice Market is not in Resolvable status
    error MarketNotResolvable();
    
    /// @notice Market has not been resolved yet
    error MarketNotResolved();
    
    /// @notice Market has already been resolved
    error MarketAlreadyResolved();
    
    /// @notice Outcome index is out of valid range
    error InvalidOutcomeIndex();
    
    /// @notice Attempting to redeem non-winning outcome
    error NotWinningOutcome();
    
    /// @notice Market resolved as invalid and refund not enabled
    error InvalidMarketInvalid();
    
    /// @notice Amount cannot be zero
    error ZeroAmount();
    
    /// @notice Number of outcomes outside valid range [2, 8]
    error InvalidNumOutcomes();
    
    /// @notice Collateral token address is zero
    error InvalidCollateralToken();
    
    /// @notice Oracle address is zero
    error InvalidOracle();
    
    /// @notice Market deadline has not passed yet
    error DeadlineNotPassed();
    
    /// @notice Oracle has not resolved the question yet
    error OracleNotResolved();
    
    /// @notice Early resolution not allowed for this market
    error EarlyResolutionNotAllowed();

    // ============ Constants ============
    
    /// @notice Minimum number of outcomes per market
    uint8 public constant MIN_OUTCOMES = 2;
    
    /// @notice Maximum number of outcomes per market (for initial version)
    uint8 public constant MAX_OUTCOMES = 8;
    
    /// @notice Config flag: allow early resolution before deadline
    /// @dev When set, requestResolution() can be called before marketDeadline
    uint8 public constant FLAG_EARLY_RESOLUTION = 0x01;
    
    /// @notice Config flag: on invalid resolution, allow refund of all outcomes
    /// @dev When set, all outcome tokens can be redeemed 1:1 if market is invalid
    uint8 public constant FLAG_INVALID_REFUND = 0x02;

    // ============ Types ============
    
    /// @notice Market lifecycle status
    enum MarketStatus {
        Open,       // Trading allowed until deadline
        Resolvable, // Deadline passed, awaiting resolution
        Resolved    // Final outcome determined
    }
    
    /**
     * @notice Immutable market parameters set at creation
     * @dev Packed for gas efficiency - fits in 3 storage slots
     * 
     * Slot 1 (32 bytes):
     * - collateralToken: 20 bytes
     * - marketDeadline: 8 bytes
     * - configFlags: 1 byte
     * - numOutcomes: 1 byte
     * - padding: 2 bytes
     * 
     * Slot 2 (32 bytes):
     * - oracle: 20 bytes
     * - padding: 12 bytes
     * 
     * Slot 3 (32 bytes):
     * - questionId: 32 bytes
     */
    struct MarketParams {
        address collateralToken;  // ERC-20 token used as collateral
        uint64 marketDeadline;    // Unix timestamp - last trade time
        uint8 configFlags;        // Bitfield for market configuration
        uint8 numOutcomes;        // Number of possible outcomes (2-8)
        address oracle;           // IOutcomeOracle implementation
        bytes32 questionId;       // Oracle-specific question identifier
    }
    
    /**
     * @notice Full market data including mutable resolution state
     * @dev Resolution fields packed into minimal storage
     */
    struct MarketData {
        MarketParams params;       // Immutable parameters (3 slots)
        MarketStatus status;       // Current lifecycle status (1 byte)
        uint8 winningOutcomeIndex; // Winning outcome index if resolved (1 byte)
        bool isInvalid;            // True if resolved as invalid (1 byte)
        string metadataURI;        // Off-chain metadata pointer (IPFS, etc.)
    }

    // ============ Storage ============
    
    /// @notice OutcomeToken1155 contract reference (immutable)
    address public immutable outcomeToken1155;
    
    /// @notice All markets indexed by their deterministic ID
    mapping(bytes32 => MarketData) private _markets;
    
    /// @notice Quick existence check (separate from status for gas efficiency)
    mapping(bytes32 => bool) public marketExists;
    
    /// @notice Total collateral deposited per market (for redemption accounting)
    mapping(bytes32 => uint256) public marketCollateralBalance;

    // ============ Events ============
    
    /**
     * @notice Emitted when a new market is created
     * @param marketId Deterministic market identifier
     * @param collateralToken ERC-20 token used as collateral
     * @param oracle Oracle contract for resolution
     * @param questionId Oracle-specific question identifier
     * @param marketDeadline Unix timestamp for trading deadline
     * @param numOutcomes Number of possible outcomes
     * @param metadataURI Off-chain metadata location
     * @param creator Address that created the market
     */
    event MarketCreated(
        bytes32 indexed marketId,
        address indexed collateralToken,
        address indexed oracle,
        bytes32 questionId,
        uint64 marketDeadline,
        uint8 numOutcomes,
        string metadataURI,
        address creator
    );
    
    /**
     * @notice Emitted when resolution is requested from oracle
     * @param marketId The market requesting resolution
     * @param requester Address that triggered the request
     */
    event ResolutionRequested(
        bytes32 indexed marketId,
        address indexed requester
    );
    
    /**
     * @notice Emitted when market is finalized with oracle result
     * @param marketId The finalized market
     * @param winningOutcomeIndex Index of winning outcome (0 = YES, 1 = NO for binary)
     * @param isInvalid True if market resolved as invalid
     */
    event MarketFinalized(
        bytes32 indexed marketId,
        uint8 winningOutcomeIndex,
        bool isInvalid
    );
    
    /**
     * @notice Emitted when user redeems winning tokens for collateral
     * @param marketId The market being redeemed from
     * @param redeemer Address receiving collateral
     * @param outcomeIndex Index of outcome being redeemed
     * @param amount Amount of outcome tokens burned
     * @param collateralPaid Amount of collateral transferred
     */
    event WinningsRedeemed(
        bytes32 indexed marketId,
        address indexed redeemer,
        uint8 outcomeIndex,
        uint256 amount,
        uint256 collateralPaid
    );
    
    /**
     * @notice Emitted when collateral is deposited to back tokens
     * @param marketId The market receiving collateral
     * @param depositor Address providing collateral
     * @param amount Amount of collateral deposited
     */
    event CollateralDeposited(
        bytes32 indexed marketId,
        address indexed depositor,
        uint256 amount
    );

    // ============ Constructor ============
    
    /**
     * @notice Deploy MarketCore with reference to outcome token contract
     * @param _outcomeToken1155 Address of the OutcomeToken1155 contract
     * @dev OutcomeToken1155 must list this contract as an authorized minter
     */
    constructor(address _outcomeToken1155) {
        outcomeToken1155 = _outcomeToken1155;
    }

    // ============ Market Creation ============
    
    /**
     * @notice Create a new prediction market
     * @param params Immutable market parameters (collateral, oracle, deadline, etc.)
     * @param metadataURI Off-chain metadata pointer (IPFS hash, URL, etc.)
     * @return marketId Deterministic market identifier (hash of params)
     * @dev Permissionless - anyone can create markets
     *      Market ID is deterministic: keccak256(abi.encode(params))
     *      This prevents duplicate markets with identical parameters
     */
    function createMarket(
        MarketParams calldata params,
        string calldata metadataURI
    ) external returns (bytes32 marketId) {
        // Validate parameters
        if (params.collateralToken == address(0)) revert InvalidCollateralToken();
        if (params.oracle == address(0)) revert InvalidOracle();
        if (params.numOutcomes < MIN_OUTCOMES || params.numOutcomes > MAX_OUTCOMES) {
            revert InvalidNumOutcomes();
        }
        
        // Compute deterministic market ID from parameters
        marketId = keccak256(abi.encode(params));
        
        // Prevent duplicate markets
        if (marketExists[marketId]) revert MarketAlreadyExists();
        
        // Store market data
        marketExists[marketId] = true;
        
        MarketData storage market = _markets[marketId];
        market.params = params;
        market.status = MarketStatus.Open;
        market.winningOutcomeIndex = 0;
        market.isInvalid = false;
        market.metadataURI = metadataURI;
        
        emit MarketCreated(
            marketId,
            params.collateralToken,
            params.oracle,
            params.questionId,
            params.marketDeadline,
            params.numOutcomes,
            metadataURI,
            msg.sender
        );
    }

    // ============ Resolution ============
    
    /**
     * @notice Request the oracle to resolve the market's question
     * @param marketId The market to request resolution for
     * @dev Anyone can call after deadline passes (or earlier if FLAG_EARLY_RESOLUTION set)
     *      This triggers the oracle to compute and store the outcome
     *      Does NOT finalize the market - call finalizeMarket() after oracle resolves
     */
    function requestResolution(bytes32 marketId) external {
        if (!marketExists[marketId]) revert MarketNotFound();
        
        MarketData storage market = _markets[marketId];
        
        // Can only request for Open or Resolvable markets
        if (market.status == MarketStatus.Resolved) revert MarketAlreadyResolved();
        
        MarketParams storage params = market.params;
        
        // Check timing constraints
        bool deadlinePassed = block.timestamp >= params.marketDeadline;
        bool earlyAllowed = (params.configFlags & FLAG_EARLY_RESOLUTION) != 0;
        
        if (!deadlinePassed && !earlyAllowed) revert DeadlineNotPassed();
        
        // Transition to Resolvable status
        if (market.status == MarketStatus.Open) {
            market.status = MarketStatus.Resolvable;
        }
        
        // Trigger oracle resolution
        IOutcomeOracle(params.oracle).requestResolution(params.questionId);
        
        emit ResolutionRequested(marketId, msg.sender);
    }
    
    /**
     * @notice Finalize market with oracle result
     * @param marketId The market to finalize
     * @dev Anyone can call once oracle.getOutcome() returns resolved = true
     *      Reads the outcome from oracle and stores winning outcome index
     *      After this, winners can call redeemWinnings()
     */
    function finalizeMarket(bytes32 marketId) external {
        if (!marketExists[marketId]) revert MarketNotFound();

        MarketData storage market = _markets[marketId];

        if (market.status == MarketStatus.Resolved) revert MarketAlreadyResolved();

        MarketParams storage params = market.params;

        // Fetch outcome from oracle (multi-outcome interface)
        (
            uint8 winningOutcomeIndex,
            bool isInvalid,
            bool resolved,
            /* resolutionTime */
        ) = IOutcomeOracle(params.oracle).getOutcome(params.questionId);

        if (!resolved) revert OracleNotResolved();

        // Store oracle result directly (supports 2-8 outcomes)
        market.isInvalid = isInvalid;
        market.winningOutcomeIndex = winningOutcomeIndex;
        market.status = MarketStatus.Resolved;

        emit MarketFinalized(marketId, market.winningOutcomeIndex, market.isInvalid);
    }

    // ============ Redemption ============
    
    /**
     * @notice Redeem winning outcome tokens for collateral
     * @param marketId The market to redeem from
     * @param outcomeIndex The outcome index to redeem (must be winner unless invalid)
     * @param amount Amount of outcome tokens to redeem
     * @dev Burns outcome tokens from caller and transfers collateral 1:1
     *      Caller must have approved this contract to burn their tokens
     *      For invalid markets with FLAG_INVALID_REFUND, any outcome can redeem
     */
    function redeemWinnings(
        bytes32 marketId,
        uint8 outcomeIndex,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!marketExists[marketId]) revert MarketNotFound();
        
        MarketData storage market = _markets[marketId];
        
        if (market.status != MarketStatus.Resolved) revert MarketNotResolved();
        
        MarketParams storage params = market.params;
        
        // Handle invalid markets
        if (market.isInvalid) {
            // Check if refund mode is enabled
            if ((params.configFlags & FLAG_INVALID_REFUND) == 0) {
                // No refund enabled - market is frozen
                revert InvalidMarketInvalid();
            }
            // In refund mode, all outcomes can redeem 1:1
        } else {
            // Valid resolution - only winning outcome can redeem
            if (outcomeIndex != market.winningOutcomeIndex) {
                revert NotWinningOutcome();
            }
        }
        
        // Validate outcome index bounds
        if (outcomeIndex >= params.numOutcomes) revert InvalidOutcomeIndex();
        
        // Compute ERC-1155 token ID
        uint256 tokenId = _computeOutcomeTokenId(marketId, outcomeIndex);
        
        // Burn outcome tokens from caller (requires approval to this contract)
        IOutcomeToken1155(outcomeToken1155).burn(msg.sender, tokenId, amount);
        
        // Calculate collateral to pay (1:1 for winning outcomes)
        uint256 collateralAmount = amount;
        
        // Update collateral balance tracking
        marketCollateralBalance[marketId] -= collateralAmount;
        
        // Transfer collateral to redeemer
        IERC20(params.collateralToken).safeTransfer(msg.sender, collateralAmount);
        
        emit WinningsRedeemed(marketId, msg.sender, outcomeIndex, amount, collateralAmount);
    }

    // ============ Collateral Management ============
    
    /**
     * @notice Deposit collateral to back outcome tokens
     * @param marketId The market to deposit to
     * @param amount Amount of collateral to deposit
     * @dev Called by FpmmAMM when minting complete sets or adding liquidity
     *      Caller must have approved this contract to transfer their collateral
     *      Only callable while market is Open
     */
    function depositCollateral(
        bytes32 marketId,
        uint256 amount
    ) external nonReentrant {
        if (!marketExists[marketId]) revert MarketNotFound();
        if (amount == 0) revert ZeroAmount();
        
        MarketData storage market = _markets[marketId];
        if (market.status != MarketStatus.Open) revert MarketNotOpen();
        
        // Transfer collateral from caller to this contract
        IERC20(market.params.collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        
        // Track deposit for redemption accounting
        marketCollateralBalance[marketId] += amount;
        
        emit CollateralDeposited(marketId, msg.sender, amount);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get immutable market parameters
     * @param marketId The market identifier
     * @return params The market's immutable configuration
     */
    function getMarketParams(bytes32 marketId) external view returns (MarketParams memory) {
        if (!marketExists[marketId]) revert MarketNotFound();
        return _markets[marketId].params;
    }
    
    /**
     * @notice Get market resolution state
     * @param marketId The market identifier
     * @return status Current lifecycle status (Open, Resolvable, Resolved)
     * @return winningOutcomeIndex Index of winning outcome (valid only if Resolved)
     * @return isInvalid True if market resolved as invalid
     */
    function getMarketState(bytes32 marketId) external view returns (
        MarketStatus status,
        uint8 winningOutcomeIndex,
        bool isInvalid
    ) {
        if (!marketExists[marketId]) revert MarketNotFound();
        MarketData storage market = _markets[marketId];
        return (market.status, market.winningOutcomeIndex, market.isInvalid);
    }
    
    /**
     * @notice Get market metadata URI
     * @param marketId The market identifier
     * @return The off-chain metadata URI string
     */
    function getMarketMetadataURI(bytes32 marketId) external view returns (string memory) {
        if (!marketExists[marketId]) revert MarketNotFound();
        return _markets[marketId].metadataURI;
    }
    
    /**
     * @notice Compute the ERC-1155 token ID for a market outcome
     * @param marketId The market identifier
     * @param outcomeIndex The outcome index (0 to numOutcomes-1)
     * @return tokenId The ERC-1155 token ID
     * @dev Pure function - can be called off-chain for gas-free computation
     *      Token ID = (marketId << 8) | outcomeIndex
     */
    function computeOutcomeTokenId(
        bytes32 marketId,
        uint8 outcomeIndex
    ) external pure returns (uint256) {
        return _computeOutcomeTokenId(marketId, outcomeIndex);
    }
    
    /**
     * @notice Check if market is currently open for trading
     * @param marketId The market identifier
     * @return True if market exists, is Open, and deadline has not passed
     */
    function isMarketOpen(bytes32 marketId) external view returns (bool) {
        if (!marketExists[marketId]) return false;
        MarketData storage market = _markets[marketId];
        return market.status == MarketStatus.Open && 
               block.timestamp < market.params.marketDeadline;
    }

    // ============ Internal Functions ============
    
    /**
     * @dev Compute outcome token ID from market ID and outcome index
     * @param marketId The market identifier (bytes32)
     * @param outcomeIndex The outcome index (uint8)
     * @return Token ID with marketId in upper 248 bits, outcomeIndex in lower 8 bits
     */
    function _computeOutcomeTokenId(
        bytes32 marketId,
        uint8 outcomeIndex
    ) internal pure returns (uint256) {
        return (uint256(marketId) << 8) | uint256(outcomeIndex);
    }
}

// ============ Interface for OutcomeToken1155 ============

/**
 * @title IOutcomeToken1155
 * @notice Interface for the OutcomeToken1155 contract
 * @dev Used by MarketCore to mint and burn outcome tokens
 */
interface IOutcomeToken1155 {
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}
