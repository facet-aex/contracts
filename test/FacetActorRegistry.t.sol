// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FacetActorRegistry} from "../src/FacetActorRegistry.sol";

interface VmRegistry {
    function prank(address sender) external;
    function expectRevert() external;
}

contract FacetActorRegistryTest {
    VmRegistry private constant vm = VmRegistry(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant CREATOR = address(0xB0B);
    bytes32 private constant FACET_ID = keccak256("facet uuid");
    FacetActorRegistry private registry;

    function setUp() public {
        registry = new FacetActorRegistry(address(this));
    }

    function registration(uint8 facetType) internal pure returns (FacetActorRegistry.FacetRegistration memory) {
        return FacetActorRegistry.FacetRegistration({
            facetType: facetType,
            imageDigest: facetType == 1 ? sha256("runner and code") : bytes32(0),
            schemaURI: "ipfs://schema",
            pricingModel: 0,
            priceAtomic: 1_000,
            payTo: CREATOR,
            erc8004TokenId: facetType == 2 ? 42 : 0,
            active: true
        });
    }

    function testRegistersAndReadsAllFacetTypes() public {
        for (uint8 facetType = 0; facetType < 3; facetType++) {
            bytes32 id = keccak256(abi.encodePacked(FACET_ID, facetType));
            registry.registerFacet(id, registration(facetType));
            FacetActorRegistry.FacetRegistration memory saved = registry.getFacet(id);
            require(saved.facetType == facetType, "type");
            require(saved.imageDigest == registration(facetType).imageDigest, "digest");
            require(keccak256(bytes(saved.schemaURI)) == keccak256("ipfs://schema"), "schema");
            require(saved.pricingModel == 0 && saved.priceAtomic == 1_000, "pricing");
            require(saved.payTo == CREATOR, "recipient");
            require(saved.erc8004TokenId == (facetType == 2 ? 42 : 0), "agent token");
            require(saved.active, "active");
        }
    }

    function testRejectsDuplicateAndMissingFacet() public {
        vm.expectRevert();
        registry.getFacet(FACET_ID);
        FacetActorRegistry.FacetRegistration memory entry = registration(1);
        registry.registerFacet(FACET_ID, entry);
        vm.expectRevert();
        registry.registerFacet(FACET_ID, entry);
    }

    function testRejectsUnauthorizedRegistration() public {
        FacetActorRegistry.FacetRegistration memory entry = registration(1);
        vm.prank(CREATOR);
        vm.expectRevert();
        registry.registerFacet(FACET_ID, entry);
    }

    function testRejectsInvalidRegistration() public {
        FacetActorRegistry.FacetRegistration memory bad = registration(3);
        vm.expectRevert();
        registry.registerFacet(FACET_ID, bad);

        bad = registration(1);
        bad.pricingModel = 2;
        vm.expectRevert();
        registry.registerFacet(FACET_ID, bad);

        bad = registration(1);
        bad.payTo = address(0);
        vm.expectRevert();
        registry.registerFacet(FACET_ID, bad);

        bad = registration(1);
        bad.priceAtomic = 0;
        vm.expectRevert();
        registry.registerFacet(FACET_ID, bad);

        bad = registration(1);
        vm.expectRevert();
        registry.registerFacet(bytes32(0), bad);
    }
}
