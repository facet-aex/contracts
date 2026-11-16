// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetUsageProof} from "./FacetUsageProof.sol";

/// @notice Immutable first-write proof that a paid FACET run produced signed usage.
contract FacetReceiptLog is FacetUsageProof {
    struct Receipt {
        bytes32 facetId;
        bytes32 inputHash;
        bytes32 outputHash;
        uint256 itemCount;
        bytes32 paymentTxHash;
        address runnerSigner;
    }

    address public immutable runnerSigner;
    address public immutable recorder;
    mapping(bytes32 => Receipt) private _receipts;
    mapping(bytes32 => bool) private _recorded;

    event RunReceiptLogged(
        bytes32 indexed runId,
        bytes32 indexed facetId,
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 itemCount,
        bytes32 paymentTxHash,
        address runnerSigner
    );

    constructor(address runnerSigner_, address recorder_) {
        require(runnerSigner_ != address(0) && recorder_ != address(0), "zero address");
        runnerSigner = runnerSigner_;
        recorder = recorder_;
    }

    function recordReceipt(
        bytes32 runId,
        bytes32 facetId,
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 itemCount,
        bytes32 paymentTxHash,
        bytes calldata runnerSignature
    ) external {
        require(msg.sender == recorder, "not recorder");
        require(runId != bytes32(0) && facetId != bytes32(0), "zero id");
        require(!_recorded[runId], "receipt exists");
        require(paymentTxHash != bytes32(0), "payment hash zero");
        require(
            recoverUsageSigner(runId, facetId, inputHash, outputHash, itemCount, runnerSignature)
                == runnerSigner,
            "invalid usage signer"
        );
        _recorded[runId] = true;
        _receipts[runId] = Receipt(facetId, inputHash, outputHash, itemCount, paymentTxHash, runnerSigner);
        emit RunReceiptLogged(runId, facetId, inputHash, outputHash, itemCount, paymentTxHash, runnerSigner);
    }

    function getReceipt(bytes32 runId) external view returns (Receipt memory) {
        require(_recorded[runId], "receipt missing");
        return _receipts[runId];
    }
}
