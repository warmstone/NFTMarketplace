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

    address public owner = address(this);
    address public seller = address(0x1);
    address public buyer = address(0x2);
    address public bidder = address(0x3);
    address public feeRecipient = address(0x4);
    address public other = address(0x5);

    string public constant TOKEN_URI = "ipfs://upgradeable-market-token";

    receive() external payable {}

    function setUp() public {
        implementation = new NFTMarketplaceUpgradeable();
        bytes memory initData = abi.encodeCall(NFTMarketplaceUpgradeable.initialize, (owner, feeRecipient));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        marketplace = NFTMarketplaceUpgradeable(address(proxy));

        pandaNFT = new PandaNFT();
        paymentToken = new ERC20Mock();

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

    function testOwnerCanUpgradeAndKeepExistingState() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(0), 1 ether);

        NFTMarketplaceUpgradeable newImplementation = new NFTMarketplaceUpgradeable();
        marketplace.upgradeToAndCall(address(newImplementation), "");

        assertEq(marketplace.owner(), owner);
        assertEq(marketplace.feeRecipient(), feeRecipient);

        vm.prank(buyer);
        marketplace.buyNFT{value: 1 ether}(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
    }

    function testNonOwnerCannotUpgrade() public {
        NFTMarketplaceUpgradeable newImplementation = new NFTMarketplaceUpgradeable();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.upgradeToAndCall(address(newImplementation), "");
    }

    function testERC20FixedPricePurchaseAndPayouts() public {
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);

        uint256 tokenId = _mintAndApprove(address(marketplace), seller);
        uint256 price = 100 ether;

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(paymentToken), price);

        paymentToken.mint(buyer, price);

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), price);

        vm.prank(buyer);
        marketplace.buyNFT(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
        assertEq(paymentToken.balanceOf(address(this)), 10 ether);
        assertEq(paymentToken.balanceOf(feeRecipient), 2.5 ether);
        assertEq(paymentToken.balanceOf(seller), 87.5 ether);
    }

    function testERC20AuctionBidWithdrawalAndSettlement() public {
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);

        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, address(paymentToken), 100 ether, 2);

        paymentToken.mint(buyer, 100 ether);
        paymentToken.mint(bidder, 105 ether);

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), 100 ether);
        vm.prank(buyer);
        marketplace.placeBid(auctionId, 100 ether);

        vm.prank(bidder);
        paymentToken.approve(address(marketplace), 105 ether);
        vm.prank(bidder);
        marketplace.placeBid(auctionId, 105 ether);

        assertEq(marketplace.pendingReturns(auctionId, buyer), 100 ether);

        vm.prank(buyer);
        marketplace.withdrawBid(auctionId);

        assertEq(paymentToken.balanceOf(buyer), 100 ether);
        assertEq(marketplace.pendingReturns(auctionId, buyer), 0);

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), bidder);
        assertEq(paymentToken.balanceOf(address(this)), 10.5 ether);
        assertEq(paymentToken.balanceOf(feeRecipient), 2.625 ether);
        assertEq(paymentToken.balanceOf(seller), 91.875 ether);
    }

    function testRejectsUnapprovedPaymentToken() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.expectRevert(NFTMarketplaceUpgradeable.PaymentTokenNotAllowed.selector);
        vm.prank(seller);
        marketplace.listNFT(address(pandaNFT), tokenId, address(paymentToken), 100 ether);
    }

    function testUsdPricedERC20PurchaseThroughChainlinkFeed() public {
        UpgradeableMockV3Aggregator feed = new UpgradeableMockV3Aggregator(8, 2_000e8);

        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        marketplace.setERC20PriceFeed(address(paymentToken), address(feed), 1 hours);

        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFTWithUsdPrice(address(pandaNFT), tokenId, address(paymentToken), 100e18);

        assertEq(marketplace.quoteListing(listingId), 0.05 ether);

        paymentToken.mint(buyer, 0.05 ether);

        vm.prank(buyer);
        paymentToken.approve(address(marketplace), 0.05 ether);

        vm.prank(buyer);
        marketplace.buyNFT(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
        assertEq(paymentToken.balanceOf(address(this)), 0.005 ether);
        assertEq(paymentToken.balanceOf(feeRecipient), 0.00125 ether);
        assertEq(paymentToken.balanceOf(seller), 0.04375 ether);
    }

    function testGettersExposeTokenAddressAndUsdFlag() public {
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(paymentToken), 100 ether);

        (,, uint256 returnedTokenId, address tokenAddress, uint256 price, bool useUsdPrice, bool active) =
            marketplace.getListing(listingId);

        assertEq(returnedTokenId, tokenId);
        assertEq(tokenAddress, address(paymentToken));
        assertEq(price, 100 ether);
        assertFalse(useUsdPrice);
        assertTrue(active);
    }

    function testETHFixedPricePurchaseAndPayouts() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);
        uint256 price = 1 ether;

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(0), price);

        uint256 sellerBalanceBefore = seller.balance;
        uint256 feeRecipientBalanceBefore = feeRecipient.balance;
        uint256 royaltyReceiverBalanceBefore = address(this).balance;

        vm.prank(buyer);
        marketplace.buyNFT{value: price}(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
        assertEq(seller.balance, sellerBalanceBefore + 0.875 ether);
        assertEq(feeRecipient.balance, feeRecipientBalanceBefore + 0.025 ether);
        assertEq(address(this).balance, royaltyReceiverBalanceBefore + 0.1 ether);
        (,,,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active);
    }

    function testDelistAndUpdatePriceOnETHListing() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(0), 1 ether);

        vm.prank(seller);
        marketplace.updatePrice(listingId, 2 ether);

        (,,,, uint256 price,, bool activeBeforeDelist) = marketplace.getListing(listingId);
        assertEq(price, 2 ether);
        assertTrue(activeBeforeDelist);

        vm.prank(seller);
        marketplace.delistNFT(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), seller);
        (,,,,,, bool activeAfterDelist) = marketplace.getListing(listingId);
        assertFalse(activeAfterDelist);
    }

    function testETHAuctionWithdrawalSettlementAndGetters() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, address(0), 1 ether, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: 1 ether}(auctionId, 1 ether);

        vm.prank(bidder);
        marketplace.placeBid{value: 1.05 ether}(auctionId, 1.05 ether);

        (
            ,,
            uint256 returnedTokenId,
            address tokenAddress,
            uint256 startPrice,
            uint256 highestBid,
            address highestBidder,,
        ) = marketplace.getAuction(auctionId);

        assertEq(returnedTokenId, tokenId);
        assertEq(tokenAddress, address(0));
        assertEq(startPrice, 1 ether);
        assertEq(highestBid, 1.05 ether);
        assertEq(highestBidder, bidder);
        assertEq(marketplace.pendingReturns(auctionId, buyer), 1 ether);

        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(buyer);
        marketplace.withdrawBid(auctionId);
        assertEq(buyer.balance, buyerBalanceBefore + 1 ether);

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), bidder);
    }

    function testAuctionWithoutBidsReturnsNFTToSeller() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, address(0), 1 ether, 2);

        vm.warp(block.timestamp + 2 hours + 1);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), seller);
    }

    function testPaymentTokenAndPriceFeedAdminControls() public {
        UpgradeableMockV3Aggregator feed = new UpgradeableMockV3Aggregator(8, 2_000e8);

        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        marketplace.setPaymentTokenAllowed(address(0), true);

        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        assertTrue(marketplace.paymentTokenAllowed(address(paymentToken)));

        marketplace.setPriceFeed(address(0), address(feed), 18, 1 hours);
        assertEq(marketplace.quoteTokenAmount(address(0), 100e18), 0.05 ether);

        marketplace.disablePriceFeed(address(0));
        vm.expectRevert(NFTMarketplaceUpgradeable.PriceFeedNotActive.selector);
        marketplace.quoteTokenAmount(address(0), 100e18);
    }

    function testOnlyOwnerAdminControlsRevertForNonOwner() public {
        UpgradeableMockV3Aggregator feed = new UpgradeableMockV3Aggregator(8, 2_000e8);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.setPriceFeed(address(0), address(feed), 18, 1 hours);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        marketplace.disablePriceFeed(address(0));
    }

    function testListingRevertBranches() public {
        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        vm.prank(seller);
        marketplace.listNFT(address(0), 1, address(0), 1 ether);

        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidPrice.selector);
        vm.prank(seller);
        marketplace.listNFT(address(pandaNFT), tokenId, address(0), 0);

        vm.expectRevert(NFTMarketplaceUpgradeable.NotOwner.selector);
        vm.prank(buyer);
        marketplace.listNFT(address(pandaNFT), tokenId, address(0), 1 ether);

        uint256 unapprovedTokenId = _mintWithoutApproval(seller);
        vm.expectRevert(NFTMarketplaceUpgradeable.MarketplaceNotApproved.selector);
        vm.prank(seller);
        marketplace.listNFT(address(pandaNFT), unapprovedTokenId, address(0), 1 ether);
    }

    function testDelistAndUpdatePriceRevertBranches() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(0), 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.NotSeller.selector);
        vm.prank(buyer);
        marketplace.delistNFT(listingId);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidPrice.selector);
        vm.prank(seller);
        marketplace.updatePrice(listingId, 0);

        vm.expectRevert(NFTMarketplaceUpgradeable.NotSeller.selector);
        vm.prank(buyer);
        marketplace.updatePrice(listingId, 2 ether);

        vm.prank(seller);
        marketplace.delistNFT(listingId);

        vm.expectRevert(NFTMarketplaceUpgradeable.ListingNotActive.selector);
        vm.prank(seller);
        marketplace.delistNFT(listingId);

        vm.expectRevert(NFTMarketplaceUpgradeable.ListingNotActive.selector);
        vm.prank(seller);
        marketplace.updatePrice(listingId, 2 ether);
    }

    function testBuyRevertBranches() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(0), 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.CannotBuyOwnNFT.selector);
        vm.prank(seller);
        marketplace.buyNFT{value: 1 ether}(listingId);

        vm.expectRevert(NFTMarketplaceUpgradeable.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.buyNFT{value: 1 ether + 1}(listingId);

        vm.prank(buyer);
        marketplace.buyNFT{value: 1 ether}(listingId);

        vm.expectRevert(NFTMarketplaceUpgradeable.ListingNotActive.selector);
        vm.prank(other);
        marketplace.buyNFT{value: 1 ether}(listingId);
    }

    function testERC20BuyRejectsETHAndMissingApproval() public {
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(paymentToken), 100 ether);

        paymentToken.mint(buyer, 100 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.buyNFT{value: 1}(listingId);

        vm.expectRevert();
        vm.prank(buyer);
        marketplace.buyNFT(listingId);
    }

    function testAuctionRevertBranches() public {
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidDuration.selector);
        vm.prank(seller);
        marketplace.createAuction(address(pandaNFT), tokenId, address(0), 1 ether, 1);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, address(0), 1 ether, 2);

        vm.expectRevert(NFTMarketplaceUpgradeable.SellerCannotBid.selector);
        vm.prank(seller);
        marketplace.placeBid{value: 1 ether}(auctionId, 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.placeBid{value: 1 ether - 1}(auctionId, 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.BidTooLow.selector);
        vm.prank(buyer);
        marketplace.placeBid{value: 1 ether - 1}(auctionId, 1 ether - 1);

        vm.prank(buyer);
        marketplace.placeBid{value: 1 ether}(auctionId, 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.BidTooLow.selector);
        vm.prank(bidder);
        marketplace.placeBid{value: 1 ether}(auctionId, 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.AuctionNotEnded.selector);
        marketplace.endAuction(auctionId);

        vm.expectRevert(NFTMarketplaceUpgradeable.NoPendingReturn.selector);
        vm.prank(other);
        marketplace.withdrawBid(auctionId);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.expectRevert(NFTMarketplaceUpgradeable.AuctionEndedAlready.selector);
        vm.prank(bidder);
        marketplace.placeBid{value: 1.05 ether}(auctionId, 1.05 ether);

        marketplace.endAuction(auctionId);

        vm.expectRevert(NFTMarketplaceUpgradeable.AuctionNotActive.selector);
        marketplace.endAuction(auctionId);
    }

    function testERC20AuctionRejectsETHPayment() public {
        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, address(paymentToken), 100 ether, 2);

        vm.expectRevert(NFTMarketplaceUpgradeable.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.placeBid{value: 1}(auctionId, 100 ether);
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
        UpgradeableMockV3Aggregator feed = new UpgradeableMockV3Aggregator(8, 2_000e8);

        vm.expectRevert(NFTMarketplaceUpgradeable.NativeTokenNotAllowed.selector);
        vm.prank(seller);
        marketplace.listNFTWithUsdPrice(address(pandaNFT), 1, address(0), 100e18);

        vm.expectRevert(NFTMarketplaceUpgradeable.PriceFeedNotActive.selector);
        vm.prank(seller);
        marketplace.listNFTWithUsdPrice(address(pandaNFT), 1, address(paymentToken), 100e18);

        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        marketplace.setPriceFeed(address(paymentToken), address(0), 18, 1 hours);

        vm.expectRevert(NFTMarketplaceUpgradeable.ZeroAddress.selector);
        marketplace.setERC20PriceFeed(address(0), address(feed), 1 hours);

        marketplace.setPaymentTokenAllowed(address(paymentToken), true);
        marketplace.setERC20PriceFeed(address(paymentToken), address(feed), 1 hours);

        feed.setAnswer(0);
        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidOraclePrice.selector);
        marketplace.quoteTokenAmount(address(paymentToken), 100e18);

        feed.setAnswer(2_000e8);
        feed.setAnsweredInRound(0);
        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidOraclePrice.selector);
        marketplace.quoteTokenAmount(address(paymentToken), 100e18);

        feed.setAnsweredInRound(1);
        vm.warp(10 hours);
        feed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(NFTMarketplaceUpgradeable.StaleOraclePrice.selector);
        marketplace.quoteTokenAmount(address(paymentToken), 100e18);
    }

    function testHighRoyaltySaleReverts() public {
        HighRoyaltyNFT highRoyaltyNFT = new HighRoyaltyNFT();
        highRoyaltyNFT.mint(seller, 1);

        vm.prank(seller);
        highRoyaltyNFT.approve(address(marketplace), 1);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(highRoyaltyNFT), 1, address(0), 1 ether);

        vm.expectRevert(NFTMarketplaceUpgradeable.InvalidRoyalty.selector);
        vm.prank(buyer);
        marketplace.buyNFT{value: 1 ether}(listingId);
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

    function testFuzzETHFixedPricePurchase(uint96 priceRaw) public {
        uint256 price = bound(uint256(priceRaw), 1 wei, 5 ether);
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, address(0), price);

        vm.prank(buyer);
        marketplace.buyNFT{value: price}(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
        (,,,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active);
    }

    function testFuzzBidRequiresFivePercentIncrement(uint96 startPriceRaw) public {
        uint256 startPrice = bound(uint256(startPriceRaw), 1 wei, 5 ether);
        uint256 tokenId = _mintAndApprove(address(marketplace), seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, address(0), startPrice, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: startPrice}(auctionId, startPrice);

        uint256 minNextBid =
            startPrice + (startPrice * marketplace.MIN_BID_INCREMENT_BPS() / marketplace.BASIS_POINTS());
        if (minNextBid > startPrice) {
            vm.expectRevert(NFTMarketplaceUpgradeable.BidTooLow.selector);
            vm.prank(bidder);
            marketplace.placeBid{value: minNextBid - 1}(auctionId, minNextBid - 1);
        }

        vm.prank(bidder);
        marketplace.placeBid{value: minNextBid}(auctionId, minNextBid);

        assertEq(marketplace.pendingReturns(auctionId, buyer), startPrice);
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

    uint80 public answeredInRoundOverride;
    bool public useAnsweredInRoundOverride;
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
