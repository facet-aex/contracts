// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetUSD} from "./FacetUSD.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice EIP-3009 ReceiveWithAuthorization-funded immediate payout and timeout-protected usage escrow for FACET runs.
contract FacetFeeSplitAndEscrow is EIP712, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for FacetUSD;
    using SafeERC20 for IERC20;

    enum RunState { UNUSED, ESCROWED, SETTLED, REFUNDED }

    struct TaskEscrow {
        bytes32 facetId;
        address payer;
        address creatorPayTo;
        uint256 unitPriceAtomic;
        uint256 maxAmount;
        uint64 expiresAt;
    }

    uint64 public constant DEFAULT_ESCROW_TIMEOUT = 15 minutes;
    uint64 public constant MIN_ESCROW_TIMEOUT = 5 minutes;
    uint64 public constant MAX_ESCROW_TIMEOUT = 1 hours;

    bytes32 public constant ESCROW_USAGE_PROOF_TYPEHASH = keccak256(
        "EscrowUsageProof(bytes32 runId,bytes32 facetId,bytes32 inputHash,bytes32 outputHash,uint256 itemCount)"
    );

    FacetUSD public immutable token;
    address public immutable platformTreasury;
    uint16 public immutable platformFeeBps;
    address public immutable runnerSigner;
    address public immutable settlementOperator;

    uint256 public totalEscrowed;
    mapping(bytes32 => RunState) public runState;
    mapping(bytes32 => TaskEscrow) public escrows;

    event FeeSplitSettled(
        bytes32 indexed runId,
        bytes32 indexed facetId,
        address indexed creatorPayTo,
        uint256 creatorAmount,
        uint256 platformFee
    );
    event TaskEscrowDeposited(
        bytes32 indexed runId,
        bytes32 indexed facetId,
        address indexed payer,
        uint256 maxAmount,
        uint64 expiresAt
    );
    event TaskEscrowSettled(
        bytes32 indexed runId,
        bytes32 indexed facetId,
        uint256 itemCount,
        uint256 actualAmount,
        uint256 refundAmount
    );
    event TaskEscrowRefunded(
        bytes32 indexed runId,
        bytes32 indexed facetId,
        address indexed caller,
        uint256 refundAmount,
        bool expired
    );
    event SurplusRescued(address indexed erc20, address indexed to, uint256 amount);

    modifier onlyOperator() {
        require(msg.sender == settlementOperator, "not operator");
        _;
    }

    constructor(
        address token_,
        address treasury_,
        uint16 feeBps_,
        address runnerSigner_,
        address operator_,
        address rescueAdmin_
    ) EIP712("FacetFeeSplitAndEscrow", "2") Ownable(rescueAdmin_) {
        require(
            token_ != address(0) && treasury_ != address(0) && runnerSigner_ != address(0)
                && operator_ != address(0) && rescueAdmin_ != address(0),
            "zero address"
        );
        require(feeBps_ <= 10_000, "invalid fee");
        token = FacetUSD(token_);
        platformTreasury = treasury_;
        platformFeeBps = feeBps_;
        runnerSigner = runnerSigner_;
        settlementOperator = operator_;
    }

    function escrowDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
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
        uint64 timeoutSeconds,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata payerSignature
    ) external nonReentrant onlyOperator {
        _openEscrow(runId, facetId, payer, creatorPayTo, unitPriceAtomic, maxAmount, timeoutSeconds);
        _pullAuthorization(payer, maxAmount, validAfter, validBefore, nonce, payerSignature);
    }

    function _openEscrow(
        bytes32 runId,
        bytes32 facetId,
        address payer,
        address creatorPayTo,
        uint256 unitPriceAtomic,
        uint256 maxAmount,
        uint64 timeoutSeconds
    ) private {
        _validateNewRun(runId, facetId, payer, creatorPayTo, maxAmount);
        require(unitPriceAtomic > 0, "unit price zero");
        uint64 duration = timeoutSeconds == 0 ? DEFAULT_ESCROW_TIMEOUT : timeoutSeconds;
        require(duration >= MIN_ESCROW_TIMEOUT && duration <= MAX_ESCROW_TIMEOUT, "invalid timeout");
        uint64 expiresAt = uint64(block.timestamp) + duration;

        runState[runId] = RunState.ESCROWED;
        escrows[runId] = TaskEscrow(facetId, payer, creatorPayTo, unitPriceAtomic, maxAmount, expiresAt);
        totalEscrowed += maxAmount;
        emit TaskEscrowDeposited(runId, facetId, payer, maxAmount, expiresAt);
    }

    function settleEscrow(
        bytes32 runId,
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 itemCount,
        bytes calldata escrowSignature
    ) external nonReentrant {
        require(runState[runId] == RunState.ESCROWED, "not escrowed");
        TaskEscrow memory task = escrows[runId];
        require(msg.sender == settlementOperator || msg.sender == task.creatorPayTo, "not authorized settler");
        require(block.timestamp < task.expiresAt, "escrow expired");

        bytes32 structHash = keccak256(
            abi.encode(ESCROW_USAGE_PROOF_TYPEHASH, runId, task.facetId, inputHash, outputHash, itemCount)
        );
        require(ECDSA.recover(_hashTypedDataV4(structHash), escrowSignature) == runnerSigner, "invalid usage signer");

        uint256 actualAmount =
            itemCount > task.maxAmount / task.unitPriceAtomic ? task.maxAmount : itemCount * task.unitPriceAtomic;
        uint256 refundAmount = task.maxAmount - actualAmount;

        runState[runId] = RunState.SETTLED;
        totalEscrowed -= task.maxAmount;
        delete escrows[runId];

        emit TaskEscrowSettled(runId, task.facetId, itemCount, actualAmount, refundAmount);
        (uint256 creatorAmount, uint256 fee) = _split(actualAmount);
        _payout(task.creatorPayTo, creatorAmount, fee);
        if (refundAmount > 0) token.safeTransfer(task.payer, refundAmount);
    }

    function refundEscrow(bytes32 runId) external nonReentrant {
        require(runState[runId] == RunState.ESCROWED, "not escrowed");
        TaskEscrow memory task = escrows[runId];
        bool expired = block.timestamp >= task.expiresAt;
        if (msg.sender != settlementOperator) {
            require(expired, "escrow not expired");
        }

        runState[runId] = RunState.REFUNDED;
        totalEscrowed -= task.maxAmount;
        delete escrows[runId];

        emit TaskEscrowRefunded(runId, task.facetId, msg.sender, task.maxAmount, expired);
        token.safeTransfer(task.payer, task.maxAmount);
    }

    function rescueSurplus(address erc20, address to) external onlyOwner nonReentrant {
        require(erc20 != address(0) && to != address(0), "zero address");
        uint256 balance = IERC20(erc20).balanceOf(address(this));
        uint256 amount;
        if (erc20 == address(token)) {
            require(balance > totalEscrowed, "no surplus");
            amount = balance - totalEscrowed;
        } else {
            require(balance > 0, "no surplus");
            amount = balance;
        }
        IERC20(erc20).safeTransfer(to, amount);
        emit SurplusRescued(erc20, to, amount);
    }

    function _validateNewRun(bytes32 runId, bytes32 facetId, address payer, address creatorPayTo, uint256 amount)
        private
        view
    {
        require(runId != bytes32(0) && facetId != bytes32(0), "zero id");
        require(runState[runId] == RunState.UNUSED, "run used");
        require(payer != address(0) && creatorPayTo != address(0), "zero recipient");
        require(amount > 0, "amount zero");
    }

    function _pullAuthorization(
        address payer,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) private {
        token.receiveWithAuthorization(payer, address(this), amount, validAfter, validBefore, nonce, signature);
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
