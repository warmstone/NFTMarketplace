// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PandaNFT} from "../src/PandaNFT.sol";

contract PandaNFTTest is Test {
    PandaNFT public pandaNFT;

    address public owner = address(this);
    address public user = address(0x1);
    address public anotherUser = address(0x2);
    address public royaltyReceiver = address(0x3);

    string public constant TOKEN_URI = "ipfs://panda-token-uri";

    event NFTMinted(address indexed minter, uint256 indexed tokenId, string uri);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event Withdrawn(address indexed recipient, uint256 amount);
    event DefaultRoyaltyUpdated(address indexed receiver, uint96 royaltyBps);
    event TokenRoyaltyUpdated(uint256 indexed tokenId, address indexed receiver, uint96 royaltyBps);

    receive() external payable {}

    function setUp() public {
        pandaNFT = new PandaNFT();

        vm.deal(user, 10 ether);
        vm.deal(anotherUser, 10 ether);
    }

    function testDeploymentInitializesMetadataOwnerPriceSupplyAndPauseState() public view {
        assertEq(pandaNFT.name(), "PandaNFT");
        assertEq(pandaNFT.symbol(), "PNFT");
        assertEq(pandaNFT.owner(), owner);
        assertEq(pandaNFT.mintPrice(), 0.01 ether);
        assertEq(pandaNFT.totalSupply(), 0);
        assertEq(pandaNFT.MAX_SUPPLY(), 10_000);
        assertFalse(pandaNFT.paused());
    }

    function testMintCreatesTokenForSenderAndStoresURI() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        assertEq(tokenId, 1);
        assertEq(pandaNFT.ownerOf(tokenId), user);
        assertEq(pandaNFT.balanceOf(user), 1);
        assertEq(pandaNFT.totalSupply(), 1);
        assertEq(pandaNFT.tokenURI(tokenId), TOKEN_URI);
        assertEq(address(pandaNFT).balance, mintPrice);
    }

    function testMintEmitsNFTMintedEvent() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.expectEmit(true, true, false, true, address(pandaNFT));
        emit NFTMinted(user, 1, TOKEN_URI);

        vm.prank(user);
        pandaNFT.mint{value: mintPrice}(TOKEN_URI);
    }

    function testMintRevertsWhenPaymentIsInsufficient() public {
        uint256 insufficientPayment = pandaNFT.mintPrice() - 1;

        vm.expectRevert(PandaNFT.IncorrectPayment.selector);

        vm.prank(user);
        pandaNFT.mint{value: insufficientPayment}(TOKEN_URI);
    }

    function testMintRevertsWhenPaymentIsTooHigh() public {
        uint256 excessivePayment = pandaNFT.mintPrice() + 1;

        vm.expectRevert(PandaNFT.IncorrectPayment.selector);

        vm.prank(user);
        pandaNFT.mint{value: excessivePayment}(TOKEN_URI);
    }

    function testMintRevertsWhenURIIsEmpty() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.expectRevert(PandaNFT.EmptyTokenURI.selector);

        vm.prank(user);
        pandaNFT.mint{value: mintPrice}("");
    }

    function testMultipleMintsIncrementTokenIdsAndSupply() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user);
        uint256 firstTokenId = pandaNFT.mint{value: mintPrice}("ipfs://first");

        vm.prank(anotherUser);
        uint256 secondTokenId = pandaNFT.mint{value: mintPrice}("ipfs://second");

        assertEq(firstTokenId, 1);
        assertEq(secondTokenId, 2);
        assertEq(pandaNFT.ownerOf(firstTokenId), user);
        assertEq(pandaNFT.ownerOf(secondTokenId), anotherUser);
        assertEq(pandaNFT.totalSupply(), 2);
    }

    function testTokenURIRevertsForNonexistentToken() public {
        vm.expectRevert();

        pandaNFT.tokenURI(1);
    }

    function testOwnerCanSetMintPriceAndEmitEvent() public {
        uint256 oldMintPrice = pandaNFT.mintPrice();
        uint256 newMintPrice = 0.05 ether;

        vm.expectEmit(false, false, false, true, address(pandaNFT));
        emit MintPriceUpdated(oldMintPrice, newMintPrice);

        pandaNFT.setMintPrice(newMintPrice);

        assertEq(pandaNFT.mintPrice(), newMintPrice);
    }

    function testSetMintPriceRevertsForNonOwner() public {
        vm.expectRevert();

        vm.prank(user);
        pandaNFT.setMintPrice(0.05 ether);
    }

    function testSetMintPriceRevertsForZeroPrice() public {
        vm.expectRevert(PandaNFT.InvalidMintPrice.selector);

        pandaNFT.setMintPrice(0);
    }

    function testMintUsesUpdatedMintPrice() public {
        uint256 newMintPrice = 0.05 ether;
        pandaNFT.setMintPrice(newMintPrice);

        vm.expectRevert(PandaNFT.IncorrectPayment.selector);
        vm.prank(user);
        pandaNFT.mint{value: 0.01 ether}(TOKEN_URI);

        vm.prank(user);
        uint256 tokenId = pandaNFT.mint{value: newMintPrice}(TOKEN_URI);

        assertEq(tokenId, 1);
        assertEq(pandaNFT.ownerOf(tokenId), user);
    }

    function testOwnerCanWithdrawMintFeesAndEmitEvent() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user);
        pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        uint256 ownerBalanceBefore = owner.balance;

        vm.expectEmit(true, false, false, true, address(pandaNFT));
        emit Withdrawn(owner, mintPrice);

        pandaNFT.withdraw();

        assertEq(address(pandaNFT).balance, 0);
        assertEq(owner.balance, ownerBalanceBefore + mintPrice);
    }

    function testWithdrawRevertsForNonOwner() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user);
        pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        vm.expectRevert();

        vm.prank(user);
        pandaNFT.withdraw();
    }

    function testWithdrawRevertsWhenContractHasNoBalance() public {
        vm.expectRevert(PandaNFT.NoBalanceToWithdraw.selector);

        pandaNFT.withdraw();
    }

    function testDefaultRoyaltyIsSetToOwnerAtTenPercent() public view {
        uint256 salePrice = 1 ether;

        (address receiver, uint256 royaltyAmount) = pandaNFT.royaltyInfo(1, salePrice);

        assertEq(receiver, owner);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function testOwnerCanSetDefaultRoyaltyAndEmitEvent() public {
        vm.expectEmit(true, false, false, true, address(pandaNFT));
        emit DefaultRoyaltyUpdated(royaltyReceiver, 500);

        pandaNFT.setDefaultRoyalty(royaltyReceiver, 500);

        (address receiver, uint256 royaltyAmount) = pandaNFT.royaltyInfo(1, 2 ether);

        assertEq(receiver, royaltyReceiver);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function testSetDefaultRoyaltyRevertsForNonOwner() public {
        vm.expectRevert();

        vm.prank(user);
        pandaNFT.setDefaultRoyalty(royaltyReceiver, 500);
    }

    function testOwnerCanSetTokenRoyaltyAndEmitEvent() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        vm.expectEmit(true, true, false, true, address(pandaNFT));
        emit TokenRoyaltyUpdated(tokenId, royaltyReceiver, 750);

        pandaNFT.setTokenRoyalty(tokenId, royaltyReceiver, 750);

        (address receiver, uint256 royaltyAmount) = pandaNFT.royaltyInfo(tokenId, 2 ether);

        assertEq(receiver, royaltyReceiver);
        assertEq(royaltyAmount, 0.15 ether);
    }

    function testSetTokenRoyaltyRevertsForNonexistentToken() public {
        vm.expectRevert(PandaNFT.TokenDoesNotExist.selector);

        pandaNFT.setTokenRoyalty(1, royaltyReceiver, 750);
    }

    function testPausePreventsMinting() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        pandaNFT.pause();

        assertTrue(pandaNFT.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        pandaNFT.mint{value: mintPrice}(TOKEN_URI);
    }

    function testOwnerCanUnpauseAndMintingResumes() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        pandaNFT.pause();
        pandaNFT.unpause();

        assertFalse(pandaNFT.paused());

        vm.prank(user);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        assertEq(tokenId, 1);
    }

    function testPauseAndUnpauseRevertForNonOwner() public {
        vm.expectRevert();
        vm.prank(user);
        pandaNFT.pause();

        pandaNFT.pause();

        vm.expectRevert();
        vm.prank(user);
        pandaNFT.unpause();
    }

    function testSupportsERC721MetadataAndERC2981Interfaces() public view {
        assertTrue(pandaNFT.supportsInterface(0x80ac58cd));
        assertTrue(pandaNFT.supportsInterface(0x5b5e139f));
        assertTrue(pandaNFT.supportsInterface(0x2a55205a));
    }

    function testSetDefaultRoyaltyRejectsZeroReceiverAndExcessFee() public {
        vm.expectRevert();
        pandaNFT.setDefaultRoyalty(address(0), 500);

        vm.expectRevert();
        pandaNFT.setDefaultRoyalty(royaltyReceiver, 10_001);
    }

    function testSetTokenRoyaltyRejectsZeroReceiverAndExcessFee() public {
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(TOKEN_URI);

        vm.expectRevert();
        pandaNFT.setTokenRoyalty(tokenId, address(0), 500);

        vm.expectRevert();
        pandaNFT.setTokenRoyalty(tokenId, royaltyReceiver, 10_001);
    }

    function testWithdrawRevertsWhenOwnerCannotReceiveETH() public {
        RejectingPandaOwner rejectingOwner = new RejectingPandaOwner();
        PandaNFT ownedPandaNFT = rejectingOwner.pandaNFT();
        uint256 mintPrice = ownedPandaNFT.mintPrice();

        vm.deal(user, mintPrice);
        vm.prank(user);
        ownedPandaNFT.mint{value: mintPrice}(TOKEN_URI);

        vm.expectRevert(PandaNFT.WithdrawFailed.selector);
        rejectingOwner.withdraw();
    }

    function testFuzzOwnerCanSetMintPriceAndMint(uint96 newPriceRaw) public {
        uint256 newPrice = bound(uint256(newPriceRaw), 1 wei, 100 ether);
        pandaNFT.setMintPrice(newPrice);

        vm.deal(user, newPrice);
        vm.prank(user);
        uint256 tokenId = pandaNFT.mint{value: newPrice}(TOKEN_URI);

        assertEq(tokenId, 1);
        assertEq(pandaNFT.ownerOf(tokenId), user);
        assertEq(address(pandaNFT).balance, newPrice);
    }

    function testFuzzDefaultRoyalty(uint96 royaltyBpsRaw, uint96 salePriceRaw) public {
        uint96 royaltyBps = uint96(bound(uint256(royaltyBpsRaw), 0, 10_000));
        uint256 salePrice = bound(uint256(salePriceRaw), 1 wei, 1_000 ether);

        pandaNFT.setDefaultRoyalty(royaltyReceiver, royaltyBps);
        (address receiver, uint256 royaltyAmount) = pandaNFT.royaltyInfo(1, salePrice);

        assertEq(receiver, royaltyReceiver);
        assertEq(royaltyAmount, salePrice * royaltyBps / 10_000);
    }
}

contract RejectingPandaOwner {
    PandaNFT public immutable pandaNFT;

    constructor() {
        pandaNFT = new PandaNFT();
    }

    function withdraw() external {
        pandaNFT.withdraw();
    }

    receive() external payable {
        revert("reject eth");
    }
}
