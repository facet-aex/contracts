// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice First-write registry for published FACET identities and pricing.
contract FacetActorRegistry is Ownable {
    struct FacetRegistration {
        uint8 facetType;
        bytes32 imageDigest;
        string schemaURI;
        uint8 pricingModel;
        uint256 priceAtomic;
        address payTo;
        uint256 erc8004TokenId;
        bool active;
    }

    mapping(bytes32 => FacetRegistration) private _facets;
    mapping(bytes32 => bool) private _registered;

    event FacetRegistered(
        bytes32 indexed facetId,
        uint8 facetType,
        bytes32 imageDigest,
        uint8 pricingModel,
        uint256 priceAtomic,
        address indexed payTo,
        uint256 erc8004TokenId
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function registerFacet(bytes32 facetId, FacetRegistration calldata registration) external onlyOwner {
        require(facetId != bytes32(0), "facet id zero");
        require(!_registered[facetId], "facet registered");
        require(registration.facetType <= 2, "invalid facet type");
        require(registration.pricingModel <= 1, "invalid pricing model");
        require(registration.priceAtomic > 0, "price zero");
        require(registration.payTo != address(0), "recipient zero");

        _registered[facetId] = true;
        _facets[facetId] = registration;
        emit FacetRegistered(
            facetId,
            registration.facetType,
            registration.imageDigest,
            registration.pricingModel,
            registration.priceAtomic,
            registration.payTo,
            registration.erc8004TokenId
        );
    }

    function getFacet(bytes32 facetId) external view returns (FacetRegistration memory) {
        require(_registered[facetId], "facet missing");
        return _facets[facetId];
    }
}
