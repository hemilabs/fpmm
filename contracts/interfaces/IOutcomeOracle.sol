// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOutcomeOracle
 * @notice Standard interface for prediction market oracle adapters
 * @dev Implement this interface to create custom oracles for different question types
 *      Supports multi-outcome markets (2-8 outcomes), where binary (Yes/No) is a subset
 *
 * Multi-Outcome Design:
 * - winningOutcomeIndex: 0 to (numOutcomes-1) for valid outcomes
 * - isInvalid: true when question cannot be resolved (ambiguous, cancelled, etc.)
 * - Binary markets: index 0 = No, index 1 = Yes (standard boolean convention)
 * - Multi-outcome: index 0, 1, 2, ... N-1 for each possible outcome
 */
interface IOutcomeOracle {
    /**
     * @notice Request the oracle to resolve a question
     * @param questionId The unique identifier for the question
     * @dev May be called multiple times; oracle should handle idempotently
     *      Resolution may happen in the same transaction or asynchronously
     */
    function requestResolution(bytes32 questionId) external;

    /**
     * @notice Get the current outcome for a question
     * @param questionId The unique identifier for the question
     * @return winningOutcomeIndex Index of the winning outcome (0-indexed)
     *         For binary markets: 0 = No, 1 = Yes (standard boolean convention)
     *         For multi-outcome: 0 to (numOutcomes-1)
     * @return isInvalid True if the question was resolved as invalid/cancelled
     *         When true, winningOutcomeIndex should be ignored
     * @return resolved True if the question has been resolved
     * @return resolutionTime Unix timestamp when resolution occurred (0 if not resolved)
     */
    function getOutcome(bytes32 questionId) external view returns (
        uint8 winningOutcomeIndex,
        bool isInvalid,
        bool resolved,
        uint64 resolutionTime
    );
}
