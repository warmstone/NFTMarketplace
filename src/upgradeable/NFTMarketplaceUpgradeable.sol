// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice UUPS upgradeable NFT auction marketplace using USD-denominated auction prices with ETH/ERC20 bids.
contract NFTMarketplaceUpgradeable is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct DeprecatedListing {
        address seller;
        address nftContract;
        uint256 tokenId;
        address tokenAddress;
        uint256 price;
        bool useUsdPrice;
        bool active;
    }

    struct Auction {
        address seller;
        address nftContract;
        uint256 tokenId;
        address deprecatedTokenAddress;
        uint256 startPriceUsd;
        uint256 highestBidUsd;
        address highestBidder;
        uint256 endTime;
        bool active;
        address highestBidTokenAddress;
        uint256 highestBidAmount;
    }

    struct PriceFeedConfig {
        AggregatorV3Interface feed;
        uint8 tokenDecimals;
        uint256 maxStaleness;
        bool active;
    }

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_PLATFORM_FEE = 1_000;
    uint256 public constant MIN_BID_INCREMENT_BPS = 500;

    mapping(uint256 => DeprecatedListing) private _deprecatedListings;
    uint256 private _deprecatedListingCounter;

    mapping(uint256 => Auction) public auctions;
    uint256 public auctionCounter;

    mapping(uint256 => mapping(address => mapping(address => uint256))) public pendingReturns;
    mapping(address => bool) public paymentTokenAllowed;
    mapping(address => PriceFeedConfig) public priceFeeds;

    address public feeRecipient;
    uint256 public platformFee;

    error ZeroAddress();
    error InvalidPrice();
    error InvalidDuration();
    error NotOwner();
    error NotFeeRecipient();
    error MarketplaceNotApproved();
    error AuctionNotActive();
    error AuctionEndedAlready();
    error AuctionNotEnded();
    error SellerCannotBid();
    error IncorrectPayment();
    error BidTooLow();
    error NoPendingReturn();
    error FeeTooHigh();
    error InvalidRoyalty();
    error TransferFailed();
    error PaymentTokenNotAllowed();
    error PriceFeedNotActive();
    error InvalidOraclePrice();
    error StaleOraclePrice();

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 startPriceUsd,
        uint256 endTime
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        address indexed tokenAddress,
        uint256 bidAmount,
        uint256 bidUsdAmount
    );
    event AuctionEnded(
        uint256 indexed auctionId, address indexed buyer, address indexed tokenAddress, uint256 price, uint256 usdPrice
    );
    event BidWithdrawn(uint256 indexed auctionId, address indexed bidder, address indexed tokenAddress, uint256 amount);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PaymentTokenAllowedUpdated(address indexed tokenAddress, bool allowed);
    event PriceFeedConfigured(
        address indexed tokenAddress, address indexed feed, uint8 tokenDecimals, uint256 maxStaleness
    );
    event PriceFeedDisabled(address indexed tokenAddress);

    // Initialization

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address initialFeeRecipient) external initializer {
        if (initialOwner == address(0) || initialFeeRecipient == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        feeRecipient = initialFeeRecipient;
        platformFee = 250;
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // Auction actions

    function createAuction(address nftContract, uint256 tokenId, uint256 startPriceUsd, uint256 durationHours)
        external
        nonReentrant
        returns (uint256)
    {
        return _createAuction(nftContract, tokenId, startPriceUsd, durationHours);
    }

    function placeBid(uint256 auctionId, address tokenAddress, uint256 bidAmount) external payable nonReentrant {
        _collectBidPayment(tokenAddress, bidAmount);
        _placeBid(auctionId, tokenAddress, bidAmount);
    }

    function endAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotActive();
        if (auction.endTime > block.timestamp) revert AuctionNotEnded();

        auction.active = false;

        if (auction.highestBidder == address(0)) {
            IERC721(auction.nftContract).safeTransferFrom(address(this), auction.seller, auction.tokenId);
            emit AuctionEnded(auctionId, address(0), address(0), 0, 0);
            return;
        }

        address highestBidTokenAddress = auction.highestBidTokenAddress;
        uint256 highestBidAmount = auction.highestBidAmount;
        uint256 highestBidUsd = auction.highestBidUsd;
        _payoutSale(highestBidTokenAddress, auction.nftContract, auction.tokenId, auction.seller, highestBidAmount);
        IERC721(auction.nftContract).safeTransferFrom(address(this), auction.highestBidder, auction.tokenId);

        emit AuctionEnded(auctionId, auction.highestBidder, highestBidTokenAddress, highestBidAmount, highestBidUsd);
    }

    function withdrawBid(uint256 auctionId, address tokenAddress) external nonReentrant {
        uint256 amount = pendingReturns[auctionId][msg.sender][tokenAddress];
        if (amount == 0) revert NoPendingReturn();

        pendingReturns[auctionId][msg.sender][tokenAddress] = 0;
        _sendPayment(tokenAddress, msg.sender, amount);

        emit BidWithdrawn(auctionId, msg.sender, tokenAddress, amount);
    }

    // Views

    function getAuction(uint256 auctionId)
        external
        view
        returns (
            address seller,
            address nftContract,
            uint256 tokenId,
            uint256 startPriceUsd,
            uint256 highestBidUsd,
            address highestBidTokenAddress,
            uint256 highestBidAmount,
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
            auction.startPriceUsd,
            auction.highestBidUsd,
            auction.highestBidTokenAddress,
            auction.highestBidAmount,
            auction.highestBidder,
            auction.endTime,
            auction.active
        );
    }

    // Admin

    function setPaymentTokenAllowed(address tokenAddress, bool allowed) external onlyOwner {
        if (tokenAddress == address(0)) revert ZeroAddress();
        paymentTokenAllowed[tokenAddress] = allowed;
        emit PaymentTokenAllowedUpdated(tokenAddress, allowed);
    }

    function setPriceFeed(address tokenAddress, address feed, uint8 tokenDecimals, uint256 maxStaleness)
        external
        onlyOwner
    {
        if (feed == address(0)) revert ZeroAddress();

        priceFeeds[tokenAddress] = PriceFeedConfig({
            feed: AggregatorV3Interface(feed), tokenDecimals: tokenDecimals, maxStaleness: maxStaleness, active: true
        });

        emit PriceFeedConfigured(tokenAddress, feed, tokenDecimals, maxStaleness);
    }

    function setERC20PriceFeed(address tokenAddress, address feed, uint256 maxStaleness) external onlyOwner {
        if (tokenAddress == address(0) || feed == address(0)) revert ZeroAddress();

        uint8 tokenDecimals = IERC20Metadata(tokenAddress).decimals();
        priceFeeds[tokenAddress] = PriceFeedConfig({
            feed: AggregatorV3Interface(feed), tokenDecimals: tokenDecimals, maxStaleness: maxStaleness, active: true
        });

        emit PriceFeedConfigured(tokenAddress, feed, tokenDecimals, maxStaleness);
    }

    function disablePriceFeed(address tokenAddress) external onlyOwner {
        priceFeeds[tokenAddress].active = false;
        emit PriceFeedDisabled(tokenAddress);
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

    // Quotes

    /// @notice Converts an 18-decimal USD amount into the configured token amount by reading Chainlink latestRoundData.
    function quoteTokenAmount(address tokenAddress, uint256 usdAmount) public view returns (uint256 tokenAmount) {
        PriceFeedConfig memory config = priceFeeds[tokenAddress];
        if (!config.active) revert PriceFeedNotActive();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = config.feed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidOraclePrice();
        if (config.maxStaleness != 0 && block.timestamp - updatedAt > config.maxStaleness) revert StaleOraclePrice();

        uint8 feedDecimals = config.feed.decimals();
        return usdAmount * (10 ** feedDecimals) * (10 ** config.tokenDecimals) / uint256(answer) / 1e18;
    }

    /// @notice Converts a token amount into an 18-decimal USD amount by reading Chainlink latestRoundData.
    function quoteUsdAmount(address tokenAddress, uint256 tokenAmount) public view returns (uint256 usdAmount) {
        PriceFeedConfig memory config = priceFeeds[tokenAddress];
        if (!config.active) revert PriceFeedNotActive();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = config.feed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidOraclePrice();
        if (config.maxStaleness != 0 && block.timestamp - updatedAt > config.maxStaleness) revert StaleOraclePrice();

        uint8 feedDecimals = config.feed.decimals();
        return tokenAmount * uint256(answer) * 1e18 / (10 ** feedDecimals) / (10 ** config.tokenDecimals);
    }

    // Upgrade and token receiver hooks

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // Internal auction logic

    function _createAuction(address nftContract, uint256 tokenId, uint256 startPriceUsd, uint256 durationHours)
        private
        returns (uint256)
    {
        if (nftContract == address(0)) revert ZeroAddress();
        if (startPriceUsd == 0) revert InvalidPrice();
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
            deprecatedTokenAddress: address(0),
            startPriceUsd: startPriceUsd,
            highestBidUsd: 0,
            highestBidder: address(0),
            endTime: endTime,
            active: true,
            highestBidTokenAddress: address(0),
            highestBidAmount: 0
        });

        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(auctionCounter, msg.sender, nftContract, tokenId, startPriceUsd, endTime);

        return auctionCounter;
    }

    function _placeBid(uint256 auctionId, address tokenAddress, uint256 bidAmount) private {
        Auction storage auction = auctions[auctionId];
        if (!auction.active) revert AuctionNotActive();
        if (auction.endTime <= block.timestamp) revert AuctionEndedAlready();
        if (msg.sender == auction.seller) revert SellerCannotBid();

        uint256 bidUsdAmount = quoteUsdAmount(tokenAddress, bidAmount);
        uint256 minBidUsd = auction.startPriceUsd;
        if (auction.highestBidUsd != 0) {
            // Keep every new bid at least 5% higher, so auctions cannot be extended by dust-size increases.
            minBidUsd = auction.highestBidUsd + (auction.highestBidUsd * MIN_BID_INCREMENT_BPS / BASIS_POINTS);
        }

        if (bidUsdAmount < minBidUsd) revert BidTooLow();

        if (auction.highestBidder != address(0)) {
            // Pull refunds avoid making an external call to the previous bidder during the new bid transaction.
            pendingReturns[auctionId][auction.highestBidder][auction.highestBidTokenAddress] += auction.highestBidAmount;
        }

        auction.highestBidUsd = bidUsdAmount;
        auction.highestBidTokenAddress = tokenAddress;
        auction.highestBidAmount = bidAmount;
        auction.highestBidder = msg.sender;

        emit BidPlaced(auctionId, msg.sender, tokenAddress, bidAmount, bidUsdAmount);
    }

    // Internal payment helpers

    function _collectBidPayment(address tokenAddress, uint256 amount) private {
        if (amount == 0) revert InvalidPrice();
        if (tokenAddress == address(0)) {
            if (msg.value != amount) revert IncorrectPayment();
        } else {
            if (msg.value != 0) revert IncorrectPayment();
            if (!paymentTokenAllowed[tokenAddress]) revert PaymentTokenNotAllowed();
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _payoutSale(address tokenAddress, address nftContract, uint256 tokenId, address seller, uint256 salePrice)
        internal
    {
        uint256 fee = salePrice * platformFee / BASIS_POINTS;
        (address receiver, uint256 royaltyAmount) = _getRoyaltyInfo(nftContract, tokenId, salePrice);
        if (fee + royaltyAmount > salePrice) revert InvalidRoyalty();

        uint256 sellerAmount = salePrice - fee - royaltyAmount;

        if (receiver != address(0) && royaltyAmount > 0) {
            _sendPayment(tokenAddress, receiver, royaltyAmount);
        }

        if (fee > 0) {
            _sendPayment(tokenAddress, feeRecipient, fee);
        }

        _sendPayment(tokenAddress, seller, sellerAmount);
    }

    // Internal NFT helpers

    function _getRoyaltyInfo(address nftContract, uint256 tokenId, uint256 salePrice)
        internal
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

    function _isApprovedForMarketplace(IERC721 nft, address tokenOwner, uint256 tokenId) internal view returns (bool) {
        return nft.getApproved(tokenId) == address(this) || nft.isApprovedForAll(tokenOwner, address(this));
    }

    function _sendPayment(address tokenAddress, address recipient, uint256 amount) private {
        if (tokenAddress == address(0)) {
            _sendValue(recipient, amount);
        } else {
            IERC20(tokenAddress).safeTransfer(recipient, amount);
        }
    }

    function _sendValue(address recipient, uint256 amount) internal {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    uint256[45] private __gap;
}
