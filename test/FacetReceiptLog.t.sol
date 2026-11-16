// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetReceiptLog} from "../src/FacetReceiptLog.sol";

interface VmReceipt {
    function addr(uint256 key) external returns (address);
    function sign(uint256 key, bytes32 digest) external returns (uint8, bytes32, bytes32);
    function prank(address sender) external;
    function expectRevert() external;
}

contract FacetReceiptLogTest {
    VmReceipt private constant vm = VmReceipt(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant RUNNER_KEY = 0xB0B;
    bytes32 private constant RUN_ID = keccak256("run uuid");
    bytes32 private constant FACET_ID = keccak256("facet uuid");
    bytes32 private constant INPUT_HASH = keccak256("input");
    bytes32 private constant OUTPUT_HASH = keccak256("output");
    bytes32 private constant PAYMENT_HASH = keccak256("payment");
    FacetReceiptLog private receiptLog;

    function setUp() public {
        receiptLog = new FacetReceiptLog(vm.addr(RUNNER_KEY), address(this));
    }

    function signature(bytes32 runId, bytes32 facetId, bytes32 inputHash, bytes32 outputHash, uint256 count) internal returns (bytes memory) {
        bytes32 usage = keccak256(abi.encodePacked(runId, facetId, inputHash, outputHash, count));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", usage));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RUNNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function testRecordsOnceAndReadsExactReceipt() public {
        bytes memory sig = signature(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3);
        receiptLog.recordReceipt(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3, PAYMENT_HASH, sig);
        FacetReceiptLog.Receipt memory saved = receiptLog.getReceipt(RUN_ID);
        require(saved.facetId == FACET_ID, "facet");
        require(saved.inputHash == INPUT_HASH && saved.outputHash == OUTPUT_HASH, "hashes");
        require(saved.itemCount == 3 && saved.paymentTxHash == PAYMENT_HASH, "usage and payment");
        require(saved.runnerSigner == vm.addr(RUNNER_KEY), "runner");
        vm.expectRevert();
        receiptLog.recordReceipt(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3, PAYMENT_HASH, sig);
    }

    function testRejectsAlteredUsageAndMissingPayment() public {
        bytes memory sig = signature(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3);
        vm.expectRevert();
        receiptLog.recordReceipt(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 4, PAYMENT_HASH, sig);
        vm.expectRevert();
        receiptLog.recordReceipt(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3, bytes32(0), sig);
    }

    function testRejectsUnauthorizedRecorder() public {
        bytes memory sig = signature(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        receiptLog.recordReceipt(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, 3, PAYMENT_HASH, sig);
    }
}
