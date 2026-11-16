// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetUSD} from "./FacetUSD.sol";
import {FacetUsageProof} from "./FacetUsageProof.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice EIP-3009-funded immediate payout and usage-based escrow for FACET runs.
contract FacetFeeSplitAndEscrow is FacetUsageProof, ReentrancyGuard {
    using SafeERC20 for FacetUSD;

    enum RunState { UNUSED, ESCROWED, SETTLED, REFUNDED }

    struct TaskEscrow {
        bytes32 facetId;
        address payer;
        address creatorPayTo;
        uint256 unitPriceAtomic;
        uint256 maxAmount;
    }

    FacetUSD public immutable token;
    address public immutable platformTreasury;
    uint16 public immutable platformFeeBps;
    address public immutable runnerSigner;
    address public immutable settlementOperator;

    mapping(bytes32 => RunState) public runState;
    mapping(bytes32 => TaskEscrow) public escrows;

    event FeeSplitSettled(bytes32 indexed runId, bytes32 indexed facetId, address indexed creatorPayTo, uint256 creatorAmount, uint256 platformFee);
    event TaskEscrowDeposited(bytes32 indexed runId, bytes32 indexed facetId, address indexed payer, uint256 maxAmount);
    event TaskEscrowSettled(bytes32 indexed runId, bytes32 indexed facetId, uint256 itemCount, uint256 actualAmount, uint256 refundAmount);
    event TaskEscrowRefunded(bytes32 indexed runId, bytes32 indexed facetId, uint256 refundAmount);

    modifier onlyOperator() {
        require(msg.sender == settlementOperator, "not operator");
        _;
    }

    constructor(address token_, address treasury_, uint16 feeBps_, address runnerSigner_, address operator_) {
        require(token_ != address(0) && treasury_ != address(0) && runnerSigner_ != address(0) && operator_ != address(0), "zero address");
        require(feeBps_ <= 10_000, "invalid fee");
        token = FacetUSD(token_);
        platformTreasury = treasury_;
        platformFeeBps = feeBps_;
        runnerSigner = runnerSigner_;
        settlementOperator = operator_;
    }

    function settlePayPerRunWithAuthorization(
        bytes32 runId,
        bytes32 facetId,
        address payer,
        address creatorPayTo,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata payerSignature
    ) external nonReentrant onlyOperator {
        _validateNewRun(runId, facetId, payer, creatorPayTo, amount);
        runState[runId] = RunState.SETTLED;
        (uint256 creatorAmount, uint256 fee) = _split(amount);
        emit FeeSplitSettled(runId, facetId, creatorPayTo, creatorAmount, fee);
        _pullAuthorization(payer, amount, validAfter, validBefore, nonce, payerSignature);
        _payout(creatorPayTo, creatorAmount, fee);
    }

    function depositEscrowWithAuthorization(
        bytes32 runId,
        bytes32 facetId,
        address payer,
        address creatorPayTo,
        uint256 unitPriceAtomic,
        uint256 maxAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata payerSignature
    ) external nonReentrant onlyOperator {
        _validateNewRun(runId, facetId, payer, creatorPayTo, maxAmount);
        require(unitPriceAtomic > 0, "unit price zero");
        runState[runId] = RunState.ESCROWED;
        escrows[runId] = TaskEscrow(facetId, payer, creatorPayTo, unitPriceAtomic, maxAmount);
        emit TaskEscrowDeposited(runId, facetId, payer, maxAmount);
        _pullAuthorization(payer, maxAmount, validAfter, validBefore, nonce, payerSignature);
    }

    function settleEscrow(bytes32 runId, bytes32 inputHash, bytes32 outputHash, uint256 itemCount, bytes calldata runnerSignature)
        external nonReentrant onlyOperator
    {
        require(runState[runId] == RunState.ESCROWED, "not escrowed");
        TaskEscrow memory task = escrows[runId];
        require(recoverUsageSigner(runId, task.facetId, inputHash, outputHash, itemCount, runnerSignature) == runnerSigner, "invalid usage signer");
        uint256 actualAmount = itemCount > task.maxAmount / task.unitPriceAtomic
            ? task.maxAmount : itemCount * task.unitPriceAtomic;
        uint256 refundAmount = task.maxAmount - actualAmount;
        runState[runId] = RunState.SETTLED;
        delete escrows[runId];
        emit TaskEscrowSettled(runId, task.facetId, itemCount, actualAmount, refundAmount);
        (uint256 creatorAmount, uint256 fee) = _split(actualAmount);
        _payout(task.creatorPayTo, creatorAmount, fee);
        if (refundAmount > 0) token.safeTransfer(task.payer, refundAmount);
    }

    function refundEscrow(bytes32 runId) external nonReentrant onlyOperator {
        require(runState[runId] == RunState.ESCROWED, "not escrowed");
        TaskEscrow memory task = escrows[runId];
        runState[runId] = RunState.REFUNDED;
        delete escrows[runId];
        emit TaskEscrowRefunded(runId, task.facetId, task.maxAmount);
        token.safeTransfer(task.payer, task.maxAmount);
    }

    function _validateNewRun(bytes32 runId, bytes32 facetId, address payer, address creatorPayTo, uint256 amount) private view {
        require(runId != bytes32(0) && facetId != bytes32(0), "zero id");
        require(runState[runId] == RunState.UNUSED, "run used");
        require(payer != address(0) && creatorPayTo != address(0), "zero recipient");
        require(amount > 0, "amount zero");
    }

    function _pullAuthorization(address payer, uint256 amount, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature) private {
        token.transferWithAuthorization(payer, address(this), amount, validAfter, validBefore, nonce, signature);
    }

    function _split(uint256 amount) private view returns (uint256 creatorAmount, uint256 fee) {
        fee = amount * platformFeeBps / 10_000;
        creatorAmount = amount - fee;
    }

    function _payout(address creatorPayTo, uint256 creatorAmount, uint256 fee) private {
        if (creatorAmount > 0) token.safeTransfer(creatorPayTo, creatorAmount);
        if (fee > 0) token.safeTransfer(platformTreasury, fee);
    }
}
