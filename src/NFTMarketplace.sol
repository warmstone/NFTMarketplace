// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NFTMarketplace is ReentrancyGuard, IERC721Receiver {
    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 price;
        bool active;
    }

    struct Auction {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 startPrice;
        uint256 highestBid;
        address highestBidder;
        uint256 endTime;
        bool active;
    }

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_PLATFORM_FEE = 1_000;
    uint256 public constant MIN_BID_INCREMENT_BPS = 500;

    mapping(uint256 => Listing) public listings;
    uint256 public listingCounter;

    mapping(uint256 => Auction) public auctions;
    uint256 public auctionCounter;

    mapping(uint256 => mapping(address => uint256)) public pendingReturns;

    address public feeRecipient;
    uint256 public platformFee = 250;

    error ZeroAddress();
    error InvalidPrice();
    error InvalidDuration();
    error NotOwner();
    error NotSeller();
    error NotFeeRecipient();
    error MarketplaceNotApproved();
    error ListingNotActive();
    error AuctionNotActive();
    error AuctionEndedAlready();
    error AuctionNotEnded();
    error SellerCannotBid();
    error CannotBuyOwnNFT();
    error IncorrectPayment();
    error BidTooLow();
    error NoPendingReturn();
    error FeeTooHigh();
    error InvalidRoyalty();
    error TransferFailed();

    event NFTListed(
        uint256 indexed listingId, address indexed seller, address indexed nftContract, uint256 tokenId, uint256 price
    );
    event NFTDelisted(uint256 indexed listingId);
    event NFTPriceUpdated(uint256 indexed listingId, uint256 oldPrice, uint256 newPrice);
    event NFTSold(uint256 indexed listingId, address indexed buyer, address indexed seller, uint256 price);
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 endTime
    );
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 bidAmount);
    event AuctionEnded(uint256 indexed auctionId, address indexed buyer, uint256 price);
    event BidWithdrawn(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    constructor(address _feeRecipient) {
        if (_feeRecipient == address(0)) revert ZeroAddress();

        feeRecipient = _feeRecipient;
    }

    function listNFT(address nftContract, uint256 tokenId, uint256 price) external nonReentrant returns (uint256) {
        if (nftContract == address(0)) revert ZeroAddress();
        if (price == 0) revert InvalidPrice();

        IERC721 nft = IERC721(nftContract);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (!_isApprovedForMarketplace(nft, msg.sender, tokenId)) revert MarketplaceNotApproved();

        listingCounter++;
        listings[listingCounter] =
            Listing({seller: msg.sender, nftContract: nftContract, tokenId: tokenId, price: price, active: true});

        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        emit NFTListed(listingCounter, msg.sender, nftContract, tokenId, price);

        return listingCounter;
    }

    function delistNFT(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ListingNotActive();
        if (listing.seller != msg.sender) revert NotSeller();

        listing.active = false;
        IERC721(listing.nftContract).safeTransferFrom(address(this), listing.seller, listing.tokenId);

        emit NFTDelisted(listingId);
    }

    function updatePrice(uint256 listingId, uint256 newPrice) external {
        if (newPrice == 0) revert InvalidPrice();

        Listing storage listing = listings[listingId];
        if (!listing.active) revert ListingNotActive();
        if (listing.seller != msg.sender) revert NotSeller();

        uint256 oldPrice = listing.price;
        listing.price = newPrice;

        emit NFTPriceUpdated(listingId, oldPrice, newPrice);
    }

    function buyNFT(uint256 listingId) external payable nonReentrant {
        Listing storage listing = listings[listingId];

        if (!listing.active) revert ListingNotActive();
        if (msg.value != listing.price) revert IncorrectPayment();
        if (msg.sender == listing.seller) revert CannotBuyOwnNFT();

        listing.active = false;

        _payoutSale(listing.nftContract, listing.tokenId, listing.seller, listing.price);
        IERC721(listing.nftContract).safeTransferFrom(address(this), msg.sender, listing.tokenId);

        emit NFTSold(listingId, msg.sender, listing.seller, listing.price);
    }

    function createAuction(address nftContract, uint256 tokenId, uint256 startPrice, uint256 durationHours)
        external
        nonReentrant
        returns (uint256)
    {
        if (nftContract == address(0)) revert ZeroAddress();
        if (startPrice == 0) revert InvalidPrice();
        if (durationHours <= 1) revert InvalidDuration();

        IERC721 nft = IERC721(nftContract);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (!_isApprovedForMarketplace(nft, msg.sender, tokenId)) revert MarketplaceNotApproved();

        auctionCounter++;
        uint256 endTime = block.timestamp + durationHours * 1 hours;
        auctions[auctionCounter] = Auction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            startPrice: startPrice,
            highestBid: 0,
            highestBidder: address(0),
            endTime: endTime,
            active: true
        });

        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(auctionCounter, msg.sender, nftContract, tokenId, startPrice, endTime);

        return auctionCounter;
    }

    function placeBid(uint256 auctionId) external payable nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotActive();
        if (auction.endTime <= block.timestamp) revert AuctionEndedAlready();
        if (msg.sender == auction.seller) revert SellerCannotBid();

        uint256 minBid = auction.startPrice;
        if (auction.highestBid != 0) {
            minBid = auction.highestBid + (auction.highestBid * MIN_BID_INCREMENT_BPS / BASIS_POINTS);
        }

        if (msg.value < minBid) revert BidTooLow();

        if (auction.highestBidder != address(0)) {
            pendingReturns[auctionId][auction.highestBidder] += auction.highestBid;
        }

        auction.highestBid = msg.value;
        auction.highestBidder = msg.sender;

        emit BidPlaced(auctionId, msg.sender, msg.value);
    }

    function endAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotActive();
        if (auction.endTime > block.timestamp) revert AuctionNotEnded();

        auction.active = false;

        if (auction.highestBidder == address(0)) {
            IERC721(auction.nftContract).safeTransferFrom(address(this), auction.seller, auction.tokenId);
            emit AuctionEnded(auctionId, address(0), 0);
            return;
        }

        uint256 highestBid = auction.highestBid;
        _payoutSale(auction.nftContract, auction.tokenId, auction.seller, highestBid);
        IERC721(auction.nftContract).safeTransferFrom(address(this), auction.highestBidder, auction.tokenId);

        emit AuctionEnded(auctionId, auction.highestBidder, highestBid);
    }

    function withdrawBid(uint256 auctionId) external nonReentrant {
        uint256 amount = pendingReturns[auctionId][msg.sender];
        if (amount == 0) revert NoPendingReturn();

        pendingReturns[auctionId][msg.sender] = 0;

        _sendValue(msg.sender, amount);

        emit BidWithdrawn(auctionId, msg.sender, amount);
    }

    function getListing(uint256 listingId)
        external
        view
        returns (address seller, address nftContract, uint256 tokenId, uint256 price, bool active)
    {
        Listing memory listing = listings[listingId];
        return (listing.seller, listing.nftContract, listing.tokenId, listing.price, listing.active);
    }

    function getAuction(uint256 auctionId)
        external
        view
        returns (
            address seller,
            address nftContract,
            uint256 tokenId,
            uint256 startPrice,
            uint256 highestBid,
            address highestBidder,
            uint256 endTime,
            bool active
        )
    {
        Auction memory auction = auctions[auctionId];
        return (
            auction.seller,
            auction.nftContract,
            auction.tokenId,
            auction.startPrice,
            auction.highestBid,
            auction.highestBidder,
            auction.endTime,
            auction.active
        );
    }

    function setPlatformFee(uint256 newFee) external {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        if (newFee > MAX_PLATFORM_FEE) revert FeeTooHigh();

        uint256 oldFee = platformFee;
        platformFee = newFee;

        emit PlatformFeeUpdated(oldFee, newFee);
    }

    function updateFeeRecipient(address newRecipient) external {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _payoutSale(address nftContract, uint256 tokenId, address seller, uint256 salePrice) private {
        uint256 fee = salePrice * platformFee / BASIS_POINTS;
        (address receiver, uint256 royaltyAmount) = _getRoyaltyInfo(nftContract, tokenId, salePrice);
        if (fee + royaltyAmount > salePrice) revert InvalidRoyalty();

        uint256 sellerAmount = salePrice - fee - royaltyAmount;

        if (receiver != address(0) && royaltyAmount > 0) {
            _sendValue(receiver, royaltyAmount);
        }

        if (fee > 0) {
            _sendValue(feeRecipient, fee);
        }

        _sendValue(seller, sellerAmount);
    }

    function _getRoyaltyInfo(address nftContract, uint256 tokenId, uint256 salePrice)
        private
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        try IERC165(nftContract).supportsInterface(type(IERC2981).interfaceId) returns (bool supportsRoyalty) {
            if (!supportsRoyalty) return (address(0), 0);
        } catch {
            return (address(0), 0);
        }

        try IERC2981(nftContract).royaltyInfo(tokenId, salePrice) returns (address royaltyReceiver, uint256 amount) {
            return (royaltyReceiver, amount);
        } catch {
            return (address(0), 0);
        }
    }

    function _isApprovedForMarketplace(IERC721 nft, address owner, uint256 tokenId) private view returns (bool) {
        return nft.getApproved(tokenId) == address(this) || nft.isApprovedForAll(owner, address(this));
    }

    function _sendValue(address recipient, uint256 amount) private {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
