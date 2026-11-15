// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetUSD} from "../src/FacetUSD.sol";

interface Vm {
    function addr(uint256 key) external returns (address);
    function sign(uint256 key, bytes32 digest) external returns (uint8, bytes32, bytes32);
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function expectRevert() external;
}

contract FacetUSDTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant PAYER_KEY = 0xA11CE;
    FacetUSD private token;
    address private payer;
    address private constant OWNER = 0x9Ba67CbB2af751af5e874a7EB57691828F43658e;
    address private constant RECIPIENT = 0x0000000000000000000000000000000000000001;

    function setUp() public {
        payer = vm.addr(PAYER_KEY);
        token = new FacetUSD(OWNER, payer);
        vm.warp(1_800_000_000);
    }

    function testMetadataAndOwner() public view {
        require(keccak256(bytes(token.name())) == keccak256("FACET USD"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("fUSD"), "symbol");
        require(keccak256(bytes(token.version())) == keccak256("2"), "version");
        require(token.decimals() == 6, "decimals");
        require(token.owner() == OWNER, "owner");
        require(token.balanceOf(OWNER) == 1_000_000_000, "owner balance");
        require(token.balanceOf(payer) == 100_000_000, "payer balance");
    }

    function testOwnerOnlyMint() public {
        vm.expectRevert();
        token.mint(payer, 1);
        vm.prank(OWNER);
        token.mint(payer, 1);
        require(token.balanceOf(payer) == 100_000_001, "mint balance");
    }

    function testTransferWithAuthorizationAndReplay() public {
        bytes32 nonce = keccak256("demo nonce");
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 60;
        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                RECIPIENT,
                1_000,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        token.transferWithAuthorization(
            payer, RECIPIENT, 1_000, validAfter, validBefore, nonce, v, r, s
        );
        require(token.balanceOf(RECIPIENT) == 1_000, "recipient balance");
        require(token.authorizationState(payer, nonce), "nonce state");
        vm.expectRevert();
        token.transferWithAuthorization(
            payer, RECIPIENT, 1_000, validAfter, validBefore, nonce, v, r, s
        );
    }

    function testInvalidSignatureAndTimeWindow() public {
        bytes32 nonce = keccak256("bad nonce");
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 60;
        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                RECIPIENT,
                1_000,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        vm.expectRevert();
        token.transferWithAuthorization(
            payer, RECIPIENT, 2_000, validAfter, validBefore, nonce, v, r, s
        );
        require(!token.authorizationState(payer, nonce), "bad signature consumed nonce");
        vm.warp(validBefore);
        vm.expectRevert();
        token.transferWithAuthorization(
            payer, RECIPIENT, 1_000, validAfter, validBefore, nonce, v, r, s
        );
    }
}
