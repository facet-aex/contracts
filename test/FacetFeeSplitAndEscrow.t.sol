// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetUSD} from "../src/FacetUSD.sol";
import {FacetFeeSplitAndEscrow} from "../src/FacetFeeSplitAndEscrow.sol";

interface VmEscrow {
    function addr(uint256 key) external returns (address);
    function sign(uint256 key, bytes32 digest) external returns (uint8, bytes32, bytes32);
    function warp(uint256 time) external;
    function prank(address sender) external;
    function expectRevert() external;
}

contract FacetFeeSplitAndEscrowTest {
    VmEscrow private constant vm = VmEscrow(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant PAYER_KEY = 0xA11CE;
    uint256 private constant RUNNER_KEY = 0xB0B;
    bytes32 private constant RUN_ID = keccak256("run uuid");
    bytes32 private constant FACET_ID = keccak256("facet uuid");
    bytes32 private constant INPUT_HASH = sha256("input");
    bytes32 private constant OUTPUT_HASH = sha256("output");
    address private constant CREATOR = address(0xC0DE);
    address private constant TREASURY = address(0xFEE);

    FacetUSD private token;
    FacetFeeSplitAndEscrow private escrow;
    address private payer;

    function setUp() public {
        payer = vm.addr(PAYER_KEY);
        token = new FacetUSD(address(this), payer);
        escrow = new FacetFeeSplitAndEscrow(address(token), TREASURY, 500, vm.addr(RUNNER_KEY), address(this));
        vm.warp(1_800_000_000);
    }

    function paymentSignature(uint256 amount, bytes32 nonce) internal returns (bytes memory) {
        bytes32 typeHash = token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH();
        bytes32 structHash = keccak256(abi.encode(typeHash, payer, address(escrow), amount, block.timestamp - 1, block.timestamp + 60, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function usageSignature(uint256 count) internal returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(RUN_ID, FACET_ID, INPUT_HASH, OUTPUT_HASH, count));
        bytes32 signedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RUNNER_KEY, signedDigest);
        return abi.encodePacked(r, s, v);
    }

    function deposit(bytes32 runId, uint256 unitPrice, uint256 maxAmount, bytes32 nonce) internal {
        bytes memory signature = paymentSignature(maxAmount, nonce);
        escrow.depositEscrowWithAuthorization(runId, FACET_ID, payer, CREATOR, unitPrice, maxAmount, block.timestamp - 1, block.timestamp + 60, nonce, signature);
    }

    function testPayPerRunSplitsAndRejectsReplay() public {
        bytes32 nonce = keccak256("pay per run");
        bytes memory signature = paymentSignature(10_000, nonce);
        escrow.settlePayPerRunWithAuthorization(RUN_ID, FACET_ID, payer, CREATOR, 10_000, block.timestamp - 1, block.timestamp + 60, nonce, signature);
        require(token.balanceOf(CREATOR) == 9_500, "creator share");
        require(token.balanceOf(TREASURY) == 500, "treasury share");
        require(token.balanceOf(address(escrow)) == 0, "no retained funds");
        vm.expectRevert();
        escrow.settlePayPerRunWithAuthorization(RUN_ID, FACET_ID, payer, CREATOR, 10_000, block.timestamp - 1, block.timestamp + 60, nonce, signature);
    }

    function testOnlyOperatorCanSettle() public {
        bytes memory signature = paymentSignature(10_000, keccak256("unauthorized"));
        vm.prank(CREATOR);
        vm.expectRevert();
        escrow.settlePayPerRunWithAuthorization(RUN_ID, FACET_ID, payer, CREATOR, 10_000, block.timestamp - 1, block.timestamp + 60, keccak256("unauthorized"), signature);
    }

    function testEscrowSettlesUsageAndRefundsRemainder() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, keccak256("deposit"));
        require(token.balanceOf(address(escrow)) == 20_000, "locked");
        escrow.settleEscrow(RUN_ID, INPUT_HASH, OUTPUT_HASH, 7, usageSignature(7));
        require(token.balanceOf(CREATOR) == 6_650, "creator share");
        require(token.balanceOf(TREASURY) == 350, "treasury share");
        require(token.balanceOf(payer) == payerBefore - 7_000, "refund");
        require(token.balanceOf(address(escrow)) == 0, "empty escrow");
        bytes memory replaySignature = usageSignature(7);
        bytes32 inputHash = INPUT_HASH;
        bytes32 outputHash = OUTPUT_HASH;
        vm.expectRevert();
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 7, replaySignature);
    }

    function testEscrowCapsChargeAtDeposit() public {
        deposit(RUN_ID, 1_000, 20_000, keccak256("cap"));
        bytes memory signature = usageSignature(30);
        escrow.settleEscrow(RUN_ID, INPUT_HASH, OUTPUT_HASH, 30, signature);
        require(token.balanceOf(CREATOR) == 19_000, "capped creator share");
        require(token.balanceOf(TREASURY) == 1_000, "capped treasury share");
    }

    function testEscrowRejectsWrongUsageAndAllowsFailureRefund() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, keccak256("refund"));
        bytes memory signature = usageSignature(1);
        bytes32 wrongOutput = sha256("wrong output");
        bytes32 inputHash = INPUT_HASH;
        bytes32 outputHash = OUTPUT_HASH;
        vm.expectRevert();
        escrow.settleEscrow(RUN_ID, inputHash, wrongOutput, 1, signature);
        vm.expectRevert();
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 2, signature);
        escrow.refundEscrow(RUN_ID);
        require(token.balanceOf(payer) == payerBefore, "full refund");
        vm.expectRevert();
        escrow.refundEscrow(RUN_ID);
    }
}
