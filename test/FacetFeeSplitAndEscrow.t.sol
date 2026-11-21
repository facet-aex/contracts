// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FacetUSD} from "../src/FacetUSD.sol";
import {FacetFeeSplitAndEscrow} from "../src/FacetFeeSplitAndEscrow.sol";

interface VmEscrow {
    function addr(uint256 key) external returns (address);
    function sign(uint256 key, bytes32 digest) external returns (uint8, bytes32, bytes32);
    function warp(uint256 time) external;
    function prank(address sender) external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
}

contract DummyERC20 is ERC20 {
    constructor(address recipient, uint256 amount) ERC20("Dummy", "DUM") {
        _mint(recipient, amount);
    }
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
    address private constant ATTACKER = address(0xBAD);
    address private constant THIRD_PARTY = address(0xDEAD);

    FacetUSD private token;
    FacetFeeSplitAndEscrow private escrow;
    address private payer;

    function setUp() public {
        payer = vm.addr(PAYER_KEY);
        token = new FacetUSD(address(this), payer);
        escrow = new FacetFeeSplitAndEscrow(
            address(token),
            TREASURY,
            500,
            vm.addr(RUNNER_KEY),
            address(this),
            address(this)
        );
        vm.warp(1_800_000_000);
    }

    function receivePaymentSignature(uint256 amount, bytes32 nonce, address target) internal returns (bytes memory) {
        bytes32 typeHash = token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH();
        bytes32 structHash = keccak256(
            abi.encode(typeHash, payer, target, amount, block.timestamp - 1, block.timestamp + 60, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function transferPaymentSignature(uint256 amount, bytes32 nonce, address target) internal returns (bytes memory) {
        bytes32 typeHash = token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH();
        bytes32 structHash = keccak256(
            abi.encode(typeHash, payer, target, amount, block.timestamp - 1, block.timestamp + 60, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function escrowUsageSignature(FacetFeeSplitAndEscrow targetEscrow, bytes32 runId, bytes32 inputHash, bytes32 outputHash, uint256 count)
        internal
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(targetEscrow.ESCROW_USAGE_PROOF_TYPEHASH(), runId, FACET_ID, inputHash, outputHash, count)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", targetEscrow.escrowDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RUNNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function legacyEip191UsageSignature(bytes32 runId, uint256 count) internal returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(runId, FACET_ID, INPUT_HASH, OUTPUT_HASH, count));
        bytes32 signedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RUNNER_KEY, signedDigest);
        return abi.encodePacked(r, s, v);
    }

    function deposit(bytes32 runId, uint256 unitPrice, uint256 maxAmount, uint64 timeoutSeconds, bytes32 nonce) internal {
        bytes memory signature = receivePaymentSignature(maxAmount, nonce, address(escrow));
        escrow.depositEscrowWithAuthorization(
            runId,
            FACET_ID,
            payer,
            CREATOR,
            unitPrice,
            maxAmount,
            timeoutSeconds,
            block.timestamp - 1,
            block.timestamp + 60,
            nonce,
            signature
        );
    }

    function testPayPerRunSplitsAndRejectsReplay() public {
        bytes32 nonce = keccak256("pay per run");
        bytes memory signature = receivePaymentSignature(10_000, nonce, address(escrow));
        escrow.settlePayPerRunWithAuthorization(
            RUN_ID, FACET_ID, payer, CREATOR, 10_000, block.timestamp - 1, block.timestamp + 60, nonce, signature
        );
        require(token.balanceOf(CREATOR) == 9_500, "creator share");
        require(token.balanceOf(TREASURY) == 500, "treasury share");
        require(token.balanceOf(address(escrow)) == 0, "no retained funds");
        vm.expectRevert();
        escrow.settlePayPerRunWithAuthorization(
            RUN_ID, FACET_ID, payer, CREATOR, 10_000, block.timestamp - 1, block.timestamp + 60, nonce, signature
        );
    }

    function testPayPerRunUsesReceiveWithAuthorizationAndBlocksFrontRun() public {
        bytes32 nonce = keccak256("frontrun pay per run");
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 60;
        bytes memory signature = receivePaymentSignature(10_000, nonce, address(escrow));

        vm.prank(ATTACKER);
        vm.expectRevert(bytes("caller not recipient"));
        token.receiveWithAuthorization(payer, address(escrow), 10_000, validAfter, validBefore, nonce, signature);

        vm.prank(ATTACKER);
        vm.expectRevert(bytes("invalid signature"));
        token.transferWithAuthorization(payer, address(escrow), 10_000, validAfter, validBefore, nonce, signature);

        escrow.settlePayPerRunWithAuthorization(
            RUN_ID, FACET_ID, payer, CREATOR, 10_000, validAfter, validBefore, nonce, signature
        );
        require(token.balanceOf(CREATOR) == 9_500, "creator paid after failed frontrun");
        require(token.balanceOf(address(escrow)) == 0, "no stuck funds");

        // Also reject raw TransferWithAuthorization signature submitted to v2 contract
        bytes32 badNonce = keccak256("transfer sig");
        bytes memory legacyTransferSig = transferPaymentSignature(10_000, badNonce, address(escrow));
        vm.expectRevert(bytes("invalid signature"));
        escrow.settlePayPerRunWithAuthorization(
            keccak256("run2"), FACET_ID, payer, CREATOR, 10_000, validAfter, validBefore, badNonce, legacyTransferSig
        );
    }

    function testDepositEscrowBlocksFrontRun() public {
        bytes32 nonce = keccak256("frontrun deposit");
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 60;
        bytes memory signature = receivePaymentSignature(20_000, nonce, address(escrow));

        vm.prank(ATTACKER);
        vm.expectRevert(bytes("caller not recipient"));
        token.receiveWithAuthorization(payer, address(escrow), 20_000, validAfter, validBefore, nonce, signature);

        vm.prank(ATTACKER);
        vm.expectRevert(bytes("invalid signature"));
        token.transferWithAuthorization(payer, address(escrow), 20_000, validAfter, validBefore, nonce, signature);

        escrow.depositEscrowWithAuthorization(
            RUN_ID, FACET_ID, payer, CREATOR, 1_000, 20_000, 0, validAfter, validBefore, nonce, signature
        );
        require(escrow.totalEscrowed() == 20_000, "escrowed tracked");
        require(token.balanceOf(address(escrow)) == 20_000, "locked");
    }

    function testOnlyOperatorCanSettle() public {
        bytes memory signature = receivePaymentSignature(10_000, keccak256("unauthorized"), address(escrow));
        vm.prank(CREATOR);
        vm.expectRevert();
        escrow.settlePayPerRunWithAuthorization(
            RUN_ID, FACET_ID, payer, CREATOR, 10_000, block.timestamp - 1, block.timestamp + 60, keccak256("unauthorized"), signature
        );
    }

    function testEscrowSettlesUsageAndRefundsRemainder() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("deposit"));
        require(escrow.totalEscrowed() == 20_000, "totalEscrowed set");
        require(token.balanceOf(address(escrow)) == 20_000, "locked");
        bytes memory sig = escrowUsageSignature(escrow, RUN_ID, INPUT_HASH, OUTPUT_HASH, 7);
        escrow.settleEscrow(RUN_ID, INPUT_HASH, OUTPUT_HASH, 7, sig);
        require(token.balanceOf(CREATOR) == 6_650, "creator share");
        require(token.balanceOf(TREASURY) == 350, "treasury share");
        require(token.balanceOf(payer) == payerBefore - 7_000, "refund");
        require(escrow.totalEscrowed() == 0, "totalEscrowed cleared");
        require(token.balanceOf(address(escrow)) == 0, "empty escrow");

        bytes32 inputHash = INPUT_HASH;
        bytes32 outputHash = OUTPUT_HASH;
        vm.expectRevert();
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 7, sig);
    }

    function testEscrowCapsChargeAtDeposit() public {
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("cap"));
        bytes memory sig = escrowUsageSignature(escrow, RUN_ID, INPUT_HASH, OUTPUT_HASH, 30);
        escrow.settleEscrow(RUN_ID, INPUT_HASH, OUTPUT_HASH, 30, sig);
        require(token.balanceOf(CREATOR) == 19_000, "capped creator share");
        require(token.balanceOf(TREASURY) == 1_000, "capped treasury share");
        require(escrow.totalEscrowed() == 0, "totalEscrowed cleared");
    }

    function testPermissionlessReclaimAfterExpiry() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("expiry"));
        (, , , , , uint64 expiresAt) = escrow.escrows(RUN_ID);
        require(expiresAt == uint64(block.timestamp) + escrow.DEFAULT_ESCROW_TIMEOUT(), "default 15m timeout");

        vm.warp(expiresAt);
        vm.prank(THIRD_PARTY);
        escrow.refundEscrow(RUN_ID);

        require(token.balanceOf(payer) == payerBefore, "100% returned strictly to payer");
        require(escrow.totalEscrowed() == 0, "totalEscrowed cleared");
        require(escrow.runState(RUN_ID) == FacetFeeSplitAndEscrow.RunState.REFUNDED, "state REFUNDED");
    }

    function testNonOperatorCannotRefundBeforeExpiry() public {
        deposit(RUN_ID, 1_000, 20_000, 300, keccak256("early-deny"));
        (, , , , , uint64 expiresAt) = escrow.escrows(RUN_ID);
        vm.warp(expiresAt - 1);

        vm.prank(payer);
        vm.expectRevert(bytes("escrow not expired"));
        escrow.refundEscrow(RUN_ID);

        vm.prank(THIRD_PARTY);
        vm.expectRevert(bytes("escrow not expired"));
        escrow.refundEscrow(RUN_ID);
    }

    function testOperatorCanEarlyRefundBeforeExpiry() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("operator-early"));
        escrow.refundEscrow(RUN_ID);
        require(token.balanceOf(payer) == payerBefore, "full early refund");
        require(escrow.totalEscrowed() == 0, "totalEscrowed cleared");
    }

    function testSettleEscrowRevertsAfterExpiry() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, 600, keccak256("late-settle"));
        (, , , , , uint64 expiresAt) = escrow.escrows(RUN_ID);
        bytes memory sig = escrowUsageSignature(escrow, RUN_ID, INPUT_HASH, OUTPUT_HASH, 5);

        bytes32 inputHash = INPUT_HASH;
        bytes32 outputHash = OUTPUT_HASH;
        vm.warp(expiresAt);
        vm.expectRevert(bytes("escrow expired"));
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 5, sig);

        vm.prank(CREATOR);
        vm.expectRevert(bytes("escrow expired"));
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 5, sig);

        vm.prank(THIRD_PARTY);
        escrow.refundEscrow(RUN_ID);
        require(token.balanceOf(payer) == payerBefore, "reclaimed after late settle revert");
    }

    function testCreatorCanSettleEscrowBeforeExpiryWithValidEip712Proof() public {
        uint256 payerBefore = token.balanceOf(payer);
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("creator-settle"));
        bytes memory sig = escrowUsageSignature(escrow, RUN_ID, INPUT_HASH, OUTPUT_HASH, 4);

        vm.prank(CREATOR);
        escrow.settleEscrow(RUN_ID, INPUT_HASH, OUTPUT_HASH, 4, sig);
        require(token.balanceOf(CREATOR) == 3_800, "creator 95%");
        require(token.balanceOf(TREASURY) == 200, "treasury 5%");
        require(token.balanceOf(payer) == payerBefore - 4_000, "remainder returned");
        require(escrow.totalEscrowed() == 0, "totalEscrowed cleared");
    }

    function testEip712DomainSeparationRejectsLegacyEip191AndWrongContractSignature() public {
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("domain-sep"));
        bytes memory legacySig = legacyEip191UsageSignature(RUN_ID, 2);
        bytes32 inputHash = INPUT_HASH;
        bytes32 outputHash = OUTPUT_HASH;
        vm.expectRevert(bytes("invalid usage signer"));
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 2, legacySig);

        FacetFeeSplitAndEscrow otherEscrow = new FacetFeeSplitAndEscrow(
            address(token), TREASURY, 500, vm.addr(RUNNER_KEY), address(this), address(this)
        );
        bytes memory wrongContractSig = escrowUsageSignature(otherEscrow, RUN_ID, inputHash, outputHash, 2);
        vm.expectRevert(bytes("invalid usage signer"));
        escrow.settleEscrow(RUN_ID, inputHash, outputHash, 2, wrongContractSig);
    }

    function testRescueSurplusNeverTouchesActiveEscrows() public {
        deposit(RUN_ID, 1_000, 20_000, 0, keccak256("surplus-guard"));
        // Transfer accidental fUSD surplus directly into contract
        token.mint(address(escrow), 5_000);
        require(token.balanceOf(address(escrow)) == 25_000, "20k escrow + 5k surplus");

        vm.prank(ATTACKER);
        vm.expectRevert();
        escrow.rescueSurplus(address(token), ATTACKER);

        escrow.rescueSurplus(address(token), TREASURY);
        require(token.balanceOf(TREASURY) == 5_000, "only surplus rescued");
        require(token.balanceOf(address(escrow)) == 20_000, "active escrow untouched");

        vm.expectRevert(bytes("no surplus"));
        escrow.rescueSurplus(address(token), TREASURY);

        // Non-fUSD misdirected ERC20 is fully recoverable
        DummyERC20 dummy = new DummyERC20(address(escrow), 777);
        escrow.rescueSurplus(address(dummy), TREASURY);
        require(dummy.balanceOf(TREASURY) == 777, "non-fUSD rescued");
    }
}
