// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";
import {PandaNFT} from "../src/PandaNFT.sol";

contract NFTMarketplaceTest is Test {
    NFTMarketplace public marketplace;
    PandaNFT public pandaNFT;

    address public seller = address(0x1);
    address public buyer = address(0x2);
    address public bidder = address(0x3);
    address public feeRecipient = address(0x4);
    address public newFeeRecipient = address(0x5);

    string public constant TOKEN_URI = "ipfs://market-token";

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

    receive() external payable {}

    function setUp() public {
        marketplace = new NFTMarketplace(feeRecipient);
        pandaNFT = new PandaNFT();

        vm.deal(seller, 10 ether);
        vm.deal(buyer, 10 ether);
        vm.deal(bidder, 10 ether);
    }

    function testConstructorInitializesFeeRecipientAndDefaultFee() public view {
        assertEq(marketplace.feeRecipient(), feeRecipient);
        assertEq(marketplace.platformFee(), 250);
    }

    function testListEscrowsNFTAndEmitsEvent() public {
        uint256 tokenId = _mintAndApprove(seller);
        uint256 price = 1 ether;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit NFTListed(1, seller, address(pandaNFT), tokenId, price);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, price);

        assertEq(listingId, 1);
        assertEq(pandaNFT.ownerOf(tokenId), address(marketplace));
    }

    function testDelistReturnsEscrowedNFTToSeller() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, 1 ether);

        vm.expectEmit(true, false, false, true, address(marketplace));
        emit NFTDelisted(listingId);

        vm.prank(seller);
        marketplace.delistNFT(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), seller);
        (,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active);
    }

    function testBuyNFTTransfersTokenAndDistributesRoyaltyFeeAndSellerProceeds() public {
        uint256 tokenId = _mintAndApprove(seller);
        uint256 price = 1 ether;

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, price);

        uint256 sellerBalanceBefore = seller.balance;
        uint256 feeRecipientBalanceBefore = feeRecipient.balance;
        uint256 royaltyReceiverBalanceBefore = address(this).balance;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit NFTSold(listingId, buyer, seller, price);

        vm.prank(buyer);
        marketplace.buyNFT{value: price}(listingId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
        assertEq(seller.balance, sellerBalanceBefore + 0.875 ether);
        assertEq(feeRecipient.balance, feeRecipientBalanceBefore + 0.025 ether);
        assertEq(address(this).balance, royaltyReceiverBalanceBefore + 0.1 ether);
        (,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active);
    }

    function testBuyNFTRevertsWhenPaymentIsNotExact() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, 1 ether);

        vm.expectRevert(NFTMarketplace.IncorrectPayment.selector);
        vm.prank(buyer);
        marketplace.buyNFT{value: 1 ether + 1}(listingId);
    }

    function testCannotCreateDuplicateOrderForEscrowedToken() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        marketplace.listNFT(address(pandaNFT), tokenId, 1 ether);

        vm.expectRevert(NFTMarketplace.NotOwner.selector);
        vm.prank(seller);
        marketplace.createAuction(address(pandaNFT), tokenId, 1 ether, 2);
    }

    function testUpdatePriceEmitsOldAndNewPrice() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(pandaNFT), tokenId, 1 ether);

        vm.expectEmit(true, false, false, true, address(marketplace));
        emit NFTPriceUpdated(listingId, 1 ether, 2 ether);

        vm.prank(seller);
        marketplace.updatePrice(listingId, 2 ether);
    }

    function testCreateAuctionEscrowsNFT() public {
        uint256 tokenId = _mintAndApprove(seller);
        uint256 endTime = block.timestamp + 2 hours;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit AuctionCreated(1, seller, address(pandaNFT), tokenId, 1 ether, endTime);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, 1 ether, 2);

        assertEq(auctionId, 1);
        assertEq(pandaNFT.ownerOf(tokenId), address(marketplace));
    }

    function testOutbidBidderCanWithdrawPendingReturn() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, 1 ether, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: 1 ether}(auctionId);

        vm.prank(bidder);
        marketplace.placeBid{value: 1.05 ether}(auctionId);

        assertEq(marketplace.pendingReturns(auctionId, buyer), 1 ether);

        uint256 buyerBalanceBefore = buyer.balance;

        vm.expectEmit(true, true, false, true, address(marketplace));
        emit BidWithdrawn(auctionId, buyer, 1 ether);

        vm.prank(buyer);
        marketplace.withdrawBid(auctionId);

        assertEq(marketplace.pendingReturns(auctionId, buyer), 0);
        assertEq(buyer.balance, buyerBalanceBefore + 1 ether);
    }

    function testAnyoneCanEndAuctionAfterEndTimeAndDistributeFunds() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, 1 ether, 2);

        vm.prank(buyer);
        marketplace.placeBid{value: 1 ether}(auctionId);

        uint256 sellerBalanceBefore = seller.balance;
        uint256 feeRecipientBalanceBefore = feeRecipient.balance;
        uint256 royaltyReceiverBalanceBefore = address(this).balance;

        vm.warp(block.timestamp + 2 hours + 1);

        vm.expectEmit(true, true, false, true, address(marketplace));
        emit AuctionEnded(auctionId, buyer, 1 ether);

        vm.prank(bidder);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), buyer);
        assertEq(seller.balance, sellerBalanceBefore + 0.875 ether);
        assertEq(feeRecipient.balance, feeRecipientBalanceBefore + 0.025 ether);
        assertEq(address(this).balance, royaltyReceiverBalanceBefore + 0.1 ether);
    }

    function testAuctionWithoutBidsReturnsNFTToSeller() public {
        uint256 tokenId = _mintAndApprove(seller);

        vm.prank(seller);
        uint256 auctionId = marketplace.createAuction(address(pandaNFT), tokenId, 1 ether, 2);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(buyer);
        marketplace.endAuction(auctionId);

        assertEq(pandaNFT.ownerOf(tokenId), seller);
    }

    function testHighRoyaltySaleReverts() public {
        HighRoyaltyNFT highRoyaltyNFT = new HighRoyaltyNFT();
        highRoyaltyNFT.mint(seller, 1);

        vm.prank(seller);
        highRoyaltyNFT.approve(address(marketplace), 1);

        vm.prank(seller);
        uint256 listingId = marketplace.listNFT(address(highRoyaltyNFT), 1, 1 ether);

        vm.expectRevert(NFTMarketplace.InvalidRoyalty.selector);
        vm.prank(buyer);
        marketplace.buyNFT{value: 1 ether}(listingId);
    }

    function testFeeRecipientCanUpdateFeeAndRecipient() public {
        vm.expectEmit(false, false, false, true, address(marketplace));
        emit PlatformFeeUpdated(250, 500);

        vm.prank(feeRecipient);
        marketplace.setPlatformFee(500);

        vm.expectEmit(true, true, false, true, address(marketplace));
        emit FeeRecipientUpdated(feeRecipient, newFeeRecipient);

        vm.prank(feeRecipient);
        marketplace.updateFeeRecipient(newFeeRecipient);

        assertEq(marketplace.platformFee(), 500);
        assertEq(marketplace.feeRecipient(), newFeeRecipient);
    }

    function _mintAndApprove(address tokenOwner) private returns (uint256 tokenId) {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(tokenOwner);
        tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        vm.prank(tokenOwner);
        pandaNFT.approve(address(marketplace), tokenId);
    }
}

contract HighRoyaltyNFT is ERC721, IERC2981 {
    constructor() ERC721("HighRoyaltyNFT", "HRNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function royaltyInfo(uint256, uint256 salePrice) external pure returns (address receiver, uint256 royaltyAmount) {
        return (address(0xBEEF), salePrice + 1);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
