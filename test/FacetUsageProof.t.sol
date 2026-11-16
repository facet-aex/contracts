// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetUsageProof} from "../src/FacetUsageProof.sol";

interface VmUsage {
    function addr(uint256 key) external returns (address);
    function sign(uint256 key, bytes32 digest) external returns (uint8, bytes32, bytes32);
}

contract FacetUsageProofTest {
    VmUsage private constant vm = VmUsage(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SIGNER_KEY = 0xA11CE;
    FacetUsageProof private proof;

    function setUp() public {
        proof = new FacetUsageProof();
    }

    function testFacetKeyHashesUuidBytes() public view {
        require(
            proof.facetKey("019a1234-5678-7abc-8def-123456789abc")
                == keccak256(bytes("019a1234-5678-7abc-8def-123456789abc")),
            "UUID key"
        );
    }

    function testUsageDigestUsesPackedFields() public view {
        bytes32 runId = keccak256("run");
        bytes32 facetId = keccak256("facet");
        bytes32 inputHash = sha256("input");
        bytes32 outputHash = sha256("output");
        require(
            proof.usageDigest(runId, facetId, inputHash, outputHash, 7)
                == keccak256(abi.encodePacked(runId, facetId, inputHash, outputHash, uint256(7))),
            "packed digest"
        );
    }

    function testRecoversOnlyExactSignedUsage() public {
        bytes32 runId = keccak256("run");
        bytes32 facetId = keccak256("facet");
        bytes32 inputHash = sha256("input");
        bytes32 outputHash = sha256("output");
        bytes32 digest = proof.usageDigest(runId, facetId, inputHash, outputHash, 7);
        bytes32 signedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, signedDigest);
        bytes memory signature = abi.encodePacked(r, s, v);
        address signer = vm.addr(SIGNER_KEY);

        require(proof.recoverUsageSigner(runId, facetId, inputHash, outputHash, 7, signature) == signer, "valid signer");
        require(proof.recoverUsageSigner(keccak256("other run"), facetId, inputHash, outputHash, 7, signature) != signer, "run mismatch");
        require(proof.recoverUsageSigner(runId, keccak256("other facet"), inputHash, outputHash, 7, signature) != signer, "facet mismatch");
        require(proof.recoverUsageSigner(runId, facetId, sha256("other input"), outputHash, 7, signature) != signer, "input mismatch");
        require(proof.recoverUsageSigner(runId, facetId, inputHash, sha256("other output"), 7, signature) != signer, "output mismatch");
        require(proof.recoverUsageSigner(runId, facetId, inputHash, outputHash, 8, signature) != signer, "count mismatch");
    }
}
