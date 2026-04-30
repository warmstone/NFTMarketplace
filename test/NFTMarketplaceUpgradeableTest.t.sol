// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PandaNFT} from "../src/PandaNFT.sol";
import {NFTMarketplaceUpgradeable} from "../src/upgradeable/NFTMarketplaceUpgradeable.sol";

contract NFTMarketplaceUpgradeableTest is Test {
    NFTMarketplaceUpgradeable public marketplace;
    NFTMarketplaceUpgradeable public implementation;
    PandaNFT public pandaNFT;
    ERC20Mock public paymentToken;
    UpgradeableMockV3Aggregator public ethUsdFeed;
    UpgradeableMockV3Aggregator public tokenUsdFeed;

    address public owner = address(this);
    address public seller = address(0x1);
    address public buyer = address(0x2);
    address public bidder = address(0x3);
    address public feeRecipient = address(0x4);
    address public other = address(0x5);

    string public constant TOKEN_URI = "ipfs://upgradeable-market-token";
    uint256 public constant START_PRICE_USD = 100e18;

    receive() external payable {}

    function setUp() public {
        implementation = new NFTMarketplaceUpgradeable();
        bytes memory initData = abi.encodeCall(NFTMarketplaceUpgradeable.initialize, (owner, feeRecipient));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        marketplace = NFTMarketplaceUpgradeable(address(proxy));

        pandaNFT = new PandaNFT();
        paymentToken = new ERC20Mock();
        ethUsdFeed = new UpgradeableMockV3Aggregator(8, 2_000e8);
        tokenUsdFeed = new UpgradeableMockV3Aggregator(8, 1e8);

        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(bidder, 10 ether);
        vm.deal(other, 10 ether);
    }

    function testProxyInitializesOwnerFeeRecipientAndDefaultFee() public view {
        assertEq(marketplace.owner(), owner);
        assertEq(marketplace.feeRecipient(), feeRecipient);
        assertEq(marketplace.platformFee(), 250);
        assertEq(marketplace.version(), "1.0.0");
    }

    function testImplementationCannotBeInitializedDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, feeRecipient);
    }

    function testOwnerCanUpgradeAndKeepExistingAuctionState() public {
        _configureEthFeed();
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        NFTMarketplaceUpgradeable newImplementation = new NFTMarketplaceUpgradeable();
        marketplace.upgradeToAndCall(address(newImplementation), "");

        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(marketplace.owner(), owner);
        assertEq(marketplace.feeRecipient(), feeRecipient);
        assertEq(pandaNFT.ownerOf(tokenId), buyer);
    }

    function testNonOwnerCannotUpgrade() public {
        NFTMarketplaceUpgradeable newImplementation = new NFTMarketplaceUpgradeable();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.upgradeToAndCall(address(newImplementation), "");
    }

    function testETHAuctionWithdrawalSettlementAndGetters() public {
        _configureEthFeed();
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        vm.prank(bidder);
        marketplace.placeBid{value: 0.0525 ether}(auctionId, address(0), 0.0525 ether);

        (
            ,,
            uint256 returnedTokenId,
            uint256 startPriceUsd,
            uint256 highestBidUsd,
            address highestBidTokenAddress,
            uint256 highestBidAmount,
            address highestBidder,,
        ) = marketplace.getAuction(auctionId);

        assertEq(returnedTokenId, tokenId);
        assertEq(startPriceUsd, START_PRICE_USD);
        assertEq(highestBidUsd, 105e18);
        assertEq(highestBidTokenAddress, address(0));
        assertEq(highestBidAmount, 0.0525 ether);
        assertEq(highestBidder, bidder);
        assertEq(marketplace.pendingReturns(auctionId, buyer, address(0)), 0.05 ether);

        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(buyer);
        marketplace.withdrawBid(auctionId, address(0));
        assertEq(buyer.balance, buyerBalanceBefore + 0.05 ether);
        assertEq(marketplace.pendingReturns(auctionId, buyer, address(0)), 0);

        uint256 sellerBalanceBefore = seller.balance;
        uint256 feeRecipientBalanceBefore = feeRecipient.balance;
        uint256 royaltyReceiverBalanceBefore = address(this).balance;

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), bidder);
        assertEq(seller.balance, sellerBalanceBefore + 0.0459375 ether);
        assertEq(feeRecipient.balance, feeRecipientBalanceBefore + 0.0013125 ether);
        assertEq(address(this).balance, royaltyReceiverBalanceBefore + 0.00525 ether);
    }

    function testERC20AuctionBidWithdrawalAndSettlement() public {
        _configureERC20Feed();
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        paymentToken.mint(buyer, 100 ether);
        paymentToken.mint(bidder, 105 ether);

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), 100 ether);
        vm.prank(buyer);
        marketplace.placeBid(auctionId, address(paymentToken), 100 ether);

        vm.prank(bidder);
        paymentToken.approve(address(marketplace), 105 ether);
        vm.prank(bidder);
        marketplace.placeBid(auctionId, address(paymentToken), 105 ether);

        assertEq(marketplace.pendingReturns(auctionId, buyer, address(paymentToken)), 100 ether);

        vm.prank(buyer);
        marketplace.withdrawBid(auctionId, address(paymentToken));

        assertEq(paymentToken.balanceOf(buyer), 100 ether);
        assertEq(marketplace.pendingReturns(auctionId, buyer, address(paymentToken)), 0);

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), bidder);
        assertEq(paymentToken.balanceOf(address(this)), 10.5 ether);
        assertEq(paymentToken.balanceOf(feeRecipient), 2.625 ether);
        assertEq(paymentToken.balanceOf(seller), 91.875 ether);
    }

    function testMixedCurrencyAuctionRefundsByToken() public {
        _configureEthFeed();
        _configureERC20Feed();
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        paymentToken.mint(bidder, 106 ether);
        vm.prank(bidder);
        paymentToken.approve(address(marketplace), 106 ether);
        vm.prank(bidder);
        marketplace.placeBid(auctionId, address(paymentToken), 106 ether);

        assertEq(marketplace.pendingReturns(auctionId, buyer, address(0)), 0.05 ether);
        assertEq(marketplace.pendingReturns(auctionId, buyer, address(paymentToken)), 0);

        vm.prank(buyer);
        marketplace.withdrawBid(auctionId, address(0));

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), bidder);
        assertEq(paymentToken.balanceOf(seller), 92.75 ether);
    }

    function testAuctionWithoutBidsReturnsNFTToSeller() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), seller);
    }

    function testPaymentTokenPriceFeedAndFeeAdminControls() public {
        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        marketplace.setPaymentTokenAllowed(address(0), true);

        _configureERC20Feed();
        assertTrue(marketplace.paymentTokenAllowed(address(paymentToken)));
        assertEq(marketplace.quoteTokenAmount(address(paymentToken), START_PRICE_USD), 100 ether);

        _configureEthFeed();
        assertEq(marketplace.quoteTokenAmount(address(0), START_PRICE_USD), 0.05 ether);

        marketplace.disablePriceFeed(address(0));
        vm.expectRevert(NFTMarketplaceUpgradeable.PriceFeedNotActive.selector);
        marketplace.quoteTokenAmount(address(0), START_PRICE_USD);

        vm.prank(feeRecipient);
        marketplace.setPlatformFee(500);
        assertEq(marketplace.platformFee(), 500);

        vm.prank(feeRecipient);
        marketplace.updateFeeRecipient(other);
        assertEq(marketplace.feeRecipient(), other);
    }

    function testOnlyOwnerAdminControlsRevertForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.setPriceFeed(address(0), address(ethUsdFeed), 18, 1 hours);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.disablePriceFeed(address(0));
    }

    function testAuctionCreateRevertBranches() public {
        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        vm.prank(seller);
        marketplace.createAuction(address(0), 1, START_PRICE_USD, 2);

        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidPrice.selector);
        vm.prank(seller);
        marketplace.createAuction(address(pandaNFT), tokenId, 0, 2);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidDuration.selector);
        vm.prank(seller);
        marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 1);

        vm.expectRevert(NFTMarketplaceUpgradeable.NotOwner.selector);
        vm.prank(buyer);
        marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        uint256 unapprovedTokenId = _mintWithoutApproval(seller);
        vm.expectRevert(NFTMarketplaceUpgradeable.MarketplaceNotApproved.selector);
        vm.prank(seller);
        marketplace.createAuction(address(pandaNFT), unapprovedTokenId, START_PRICE_USD, 2);
    }

    function testBidAndEndAuctionRevertBranches() public {
        _configureEthFeed();
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidPrice.selector);
        vm.prank(buyer);
        marketplace.placeBid(auctionId, address(0), 0);

        vm.expectRevert(NFTMarketplaceUpgradeable.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether - 1}(auctionId, address(0), 0.05 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.SellerCannotBid.selector);
        vm.prank(seller);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.BidTooLow.selector);
        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether - 1}(auctionId, address(0), 0.05 ether - 1);

        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.BidTooLow.selector);
        vm.prank(bidder);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.AuctionNotEnded.selector);
        marketplace.endAuction(auctionId);

        vm.expectRevert(NFTMarketplaceUpgradeable.NoPendingReturn.selector);
        vm.prank(other);
        marketplace.withdrawBid(auctionId, address(0));

        vm.warp(block.timestamp + 2 hours + 1);

        vm.expectRevert(NFTMarketplaceUpgradeable.AuctionEndedAlready.selector);
        vm.prank(bidder);
        marketplace.placeBid{value: 0.0525 ether}(auctionId, address(0), 0.0525 ether);

        marketplace.endAuction(auctionId);

        vm.expectRevert(NFTMarketplaceUpgradeable.AuctionNotActive.selector);
        marketplace.endAuction(auctionId);
    }

    function testERC20BidRevertBranches() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, START_PRICE_USD, 2);

        paymentToken.mint(buyer, 100 ether);
        vm.prank(buyer);
        paymentToken.approve(address(marketplace), 100 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.placeBid{value: 1}(auctionId, address(paymentToken), 100 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.PaymentTokenNotAllowed.selector);
        vm.prank(buyer);
        marketplace.placeBid(auctionId, address(paymentToken), 100 ether);

        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        vm.expectRevert(NFTMarketplaceUpgradeable.PriceFeedNotActive.selector);
        vm.prank(buyer);
        marketplace.placeBid(auctionId, address(paymentToken), 100 ether);
    }

    function testFeeRecipientControlsRevertBranches() public {
        vm.expectRevert(NFTMarketplaceUpgradeable.NotFeeRecipient.selector);
        marketplace.setPlatformFee(500);

        vm.expectRevert(NFTMarketplaceUpgradeable.NotFeeRecipient.selector);
        marketplace.updateFeeRecipient(other);

        vm.expectRevert(NFTMarketplaceUpgradeable.FeeTooHigh.selector);
        vm.prank(feeRecipient);
        marketplace.setPlatformFee(1_001);

        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        vm.prank(feeRecipient);
        marketplace.updateFeeRecipient(address(0));
    }

    function testOracleRevertBranches() public {
        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        marketplace.setPriceFeed(address(paymentToken), address(0), 18, 1 hours);

        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        marketplace.setERC20PriceFeed(address(0), address(tokenUsdFeed), 1 hours);

        _configureERC20Feed();

        tokenUsdFeed.setAnswer(0);
        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidOraclePrice.selector);
        marketplace.quoteTokenAmount(address(paymentToken), START_PRICE_USD);

        tokenUsdFeed.setAnswer(1e8);
        tokenUsdFeed.setAnsweredInRound(0);
        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidOraclePrice.selector);
        marketplace.quoteUsdAmount(address(paymentToken), 100 ether);

        tokenUsdFeed.setAnsweredInRound(1);
        vm.warp(10 hours);
        tokenUsdFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(NFTMarketplaceUpgradeable.StaleOraclePrice.selector);
        marketplace.quoteUsdAmount(address(paymentToken), 100 ether);
    }

    function testHighRoyaltyAuctionSettlementReverts() public {
        _configureEthFeed();
        HighRoyaltyNFT highRoyaltyNFT = new HighRoyaltyNFT();
        highRoyaltyNFT.mint(seller, 1);

        vm.prank(seller);
        highRoyaltyNFT.approve(address(marketplace), 1);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(highRoyaltyNFT), 1, START_PRICE_USD, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: 0.05 ether}(auctionId, address(0), 0.05 ether);

        vm.warp(block.timestamp + 2 hours + 1);
        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidRoyalty.selector);
        marketplace.endAuction(auctionId);
    }

    function testFuzzQuoteTokenAmount(
        uint96 usdAmountRaw,
        uint96 answerRaw,
        uint8 feedDecimalsRaw,
        uint8 tokenDecimalsRaw
    ) public {
        uint256 usdAmount = bound(uint256(usdAmountRaw), 1e18, 1_000_000e18);
        uint256 answer = bound(uint256(answerRaw), 1, 1_000_000e8);
        uint8 feedDecimals = uint8(bound(uint256(feedDecimalsRaw), 1, 18));
        uint8 tokenDecimals = uint8(bound(uint256(tokenDecimalsRaw), 1, 18));
        UpgradeableMockV3Aggregator feed = new UpgradeableMockV3Aggregator(feedDecimals, int256(answer));

        marketplace.setPriceFeed(address(0), address(feed), tokenDecimals, 1 hours);

        uint256 expected = usdAmount * (10 ** feedDecimals) * (10 ** tokenDecimals) / answer / 1e18;
        assertEq(marketplace.quoteTokenAmount(address(0), usdAmount), expected);
    }

    function testFuzzQuoteUsdAmount(
        uint96 tokenAmountRaw,
        uint96 answerRaw,
        uint8 feedDecimalsRaw,
        uint8 tokenDecimalsRaw
    ) public {
        uint256 tokenAmount = bound(uint256(tokenAmountRaw), 1e18, 1_000_000e18);
        uint256 answer = bound(uint256(answerRaw), 1, 1_000_000e8);
        uint8 feedDecimals = uint8(bound(uint256(feedDecimalsRaw), 1, 18));
        uint8 tokenDecimals = uint8(bound(uint256(tokenDecimalsRaw), 1, 18));
        UpgradeableMockV3Aggregator feed = new UpgradeableMockV3Aggregator(feedDecimals, int256(answer));

        marketplace.setPriceFeed(address(0), address(feed), tokenDecimals, 1 hours);

        uint256 expected = tokenAmount * answer * 1e18 / (10 ** feedDecimals) / (10 ** tokenDecimals);
        assertEq(marketplace.quoteUsdAmount(address(0), tokenAmount), expected);
    }

    function testFuzzBidRequiresFivePercentUsdIncrement(uint96 startPriceRaw) public {
        _configureERC20Feed();
        uint256 startPriceUsd = bound(uint256(startPriceRaw), 1e18, 10_000e18);
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);
        uint256 firstBidAmount = startPriceUsd;

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, startPriceUsd, 2);

        paymentToken.mint(buyer, firstBidAmount);
        vm.prank(buyer);
        paymentToken.approve(address(marketplace), firstBidAmount);
        vm.prank(buyer);
        marketplace.placeBid(auctionId, address(paymentToken), firstBidAmount);

        (,,,, uint256 highestBidUsd,,,,,) = marketplace.getAuction(auctionId);
        uint256 minNextBidUsd =
            highestBidUsd + (highestBidUsd * marketplace.MIN_BID_INCREMENT_BPS() / marketplace.BASIS_POINTS());
        uint256 minNextBidAmount = minNextBidUsd;

        paymentToken.mint(bidder, minNextBidAmount);
        vm.prank(bidder);
        paymentToken.approve(address(marketplace), minNextBidAmount);
        vm.expectRevert(NFTMarketplaceUpgradeable.BidTooLow.selector);
        vm.prank(bidder);
        marketplace.placeBid(auctionId, address(paymentToken), minNextBidAmount - 1);

        vm.prank(bidder);
        marketplace.placeBid(auctionId, address(paymentToken), minNextBidAmount);

        assertEq(marketplace.pendingReturns(auctionId, buyer, address(paymentToken)), firstBidAmount);
    }

    function _configureEthFeed() private {
        marketplace.setPriceFeed(address(0), address(ethUsdFeed), 18, 1 hours);
    }

    function _configureERC20Feed() private {
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        marketplace.setERC20PriceFeed(address(paymentToken), address(tokenUsdFeed), 1 hours);
    }

    function _mintAndApprove(address operator, address tokenOwner) private returns (uint256 tokenId) {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(tokenOwner);
        tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        vm.prank(tokenOwner);
        pandaNFT.approve(operator, tokenId);
    }

    function _mintWithoutApproval(address tokenOwner) private returns (uint256 tokenId) {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(tokenOwner);
        tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);
    }
}

contract UpgradeableMockV3Aggregator {
    uint8 public immutable decimals;
    int256 public answer;
    uint80 public roundId = 1;
    uint256 public updatedAt;
    uint80 public answeredInRoundOverride;
    bool public useAnsweredInRoundOverride;

    constructor(uint8 feedDecimals, int256 initialAnswer) {
        decimals = feedDecimals;
        answer = initialAnswer;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 newAnswer) external {
        answer = newAnswer;
    }

    function setAnsweredInRound(uint80 newAnsweredInRound) external {
        roundId = 1;
        answeredInRoundOverride = newAnsweredInRound;
        useAnsweredInRoundOverride = true;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        updatedAt = newUpdatedAt;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 currentRoundId,
            int256 currentAnswer,
            uint256 startedAt,
            uint256 currentUpdatedAt,
            uint80 answeredInRound
        )
    {
        uint80 returnedAnsweredInRound = useAnsweredInRoundOverride ? answeredInRoundOverride : roundId;
        return (roundId, answer, updatedAt, updatedAt, returnedAnsweredInRound);
    }
}

contract HighRoyaltyNFT is ERC721, IERC2981 {
    constructor() ERC721("HighRoyaltyNFT", "HRNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function royaltyInfo(uint256, uint256 salePrice) external pure returns (address receiver, uint256 royaltyAmount) {
        return (address(0x1234), salePrice);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
