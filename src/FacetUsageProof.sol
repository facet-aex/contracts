// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Shared EIP-191 commitment for a single FACET run's measured output.
contract FacetUsageProof {
    function facetKey(string memory uuid) public pure returns (bytes32) {
        return keccak256(bytes(uuid));
    }

    function usageDigest(
        bytes32 runId,
        bytes32 facetId,
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 itemCount
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(runId, facetId, inputHash, outputHash, itemCount));
    }

    function recoverUsageSigner(
        bytes32 runId,
        bytes32 facetId,
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 itemCount,
        bytes memory signature
    ) public pure returns (address) {
        return ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(
                usageDigest(runId, facetId, inputHash, outputHash, itemCount)
            ),
            signature
        );
    }
}
