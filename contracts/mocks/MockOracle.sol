// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOutcomeOracle} from "../interfaces/IOutcomeOracle.sol";

/**
 * @title MockOracle
 * @notice Mock implementation of IOutcomeOracle for testing
 * @dev Allows manual setting of outcomes for test scenarios
 */
contract MockOracle is IOutcomeOracle {
    struct QuestionData {
        uint8 winningOutcomeIndex;
        bool isInvalid;
        bool resolved;
        uint64 resolutionTime;
        bool exists;
    }

    mapping(bytes32 => QuestionData) public questions;

    /**
     * @notice Register a question (for test setup)
     * @param questionId The question identifier
     */
    function registerQuestion(bytes32 questionId) external {
        questions[questionId] = QuestionData({
            winningOutcomeIndex: 0,
            isInvalid: false,
            resolved: false,
            resolutionTime: 0,
            exists: true
        });
    }

    /**
     * @notice Set the outcome for a question (for test setup)
     * @param questionId The question identifier
     * @param winningOutcomeIndex The winning outcome (0=No, 1=Yes for binary)
     * @param isInvalid Whether the market is invalid
     */
    function setOutcome(
        bytes32 questionId,
        uint8 winningOutcomeIndex,
        bool isInvalid
    ) external {
        questions[questionId].winningOutcomeIndex = winningOutcomeIndex;
        questions[questionId].isInvalid = isInvalid;
        questions[questionId].resolved = true;
        questions[questionId].resolutionTime = uint64(block.timestamp);
    }

    /**
     * @notice Request resolution - in mock, this is a no-op
     * @param questionId The question identifier
     */
    function requestResolution(bytes32 questionId) external override {
        // In mock, we don't auto-resolve - tests call setOutcome directly
        if (!questions[questionId].exists) {
            questions[questionId].exists = true;
        }
    }

    /**
     * @notice Get the outcome for a question
     * @param questionId The question identifier
     * @return winningOutcomeIndex Index of winning outcome
     * @return isInvalid Whether resolved as invalid
     * @return resolved Whether question is resolved
     * @return resolutionTime When resolution occurred
     */
    function getOutcome(bytes32 questionId) external view override returns (
        uint8 winningOutcomeIndex,
        bool isInvalid,
        bool resolved,
        uint64 resolutionTime
    ) {
        QuestionData storage q = questions[questionId];
        return (q.winningOutcomeIndex, q.isInvalid, q.resolved, q.resolutionTime);
    }
}
