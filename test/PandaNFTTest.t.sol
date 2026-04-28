// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PandaNFT} from "../src/PandaNFT.sol";

contract PandaNFTTest is Test {
    PandaNFT public pandaNFT;
    address public owner;
    address public user1;
    address public user2;

    event NFTMinted(address indexed minter, uint256 indexed tokenId, string uri);

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        pandaNFT = new PandaNFT();
    }

    // ============= Deployment & Initialization Tests =============

    function test_DeploymentAndInitialization() public view {
        assertEq(pandaNFT.name(), "PandaNFT");
        assertEq(pandaNFT.symbol(), "PNFT");
        assertEq(pandaNFT.owner(), owner);
        assertEq(pandaNFT.mintPrice(), 0.01 ether);
        assertEq(pandaNFT.totalSupply(), 0);
    }

    // ============= Minting Tests =============

    function test_MintNFTWithCorrectPayment() public {
        string memory uri = "ipfs://QmTest";
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user1);

        // 1. 忽略第一个事件（Transfer）
        vm.expectEmit(false, false, false, false);

        vm.expectEmit(true, true, false, true);
        emit NFTMinted(user1, 1, uri);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(uri);

        assertEq(tokenId, 1);
        assertEq(pandaNFT.balanceOf(user1), 1);
        assertEq(pandaNFT.totalSupply(), 1);
        assertEq(pandaNFT.tokenURI(tokenId), uri);
    }

    function test_MintMultipleNFTs() public {
        string memory uri1 = "ipfs://QmTest1";
        string memory uri2 = "ipfs://QmTest2";
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user1);
        uint256 tokenId1 = pandaNFT.mint{value: mintPrice}(uri1);
        assertEq(tokenId1, 1);

        vm.prank(user1);
        uint256 tokenId2 = pandaNFT.mint{value: mintPrice}(uri2);
        assertEq(tokenId2, 2);

        assertEq(pandaNFT.balanceOf(user1), 2);
        assertEq(pandaNFT.totalSupply(), 2);
        assertEq(pandaNFT.tokenURI(tokenId1), uri1);
        assertEq(pandaNFT.tokenURI(tokenId2), uri2);
    }

    function test_MintWithInsufficientPayment() public {
        string memory uri = "ipfs://QmTest";

        vm.expectRevert(bytes("Insufficient payment"));
        vm.prank(user1);
        pandaNFT.mint{value: 0.001 ether}(uri);
    }

    function test_MintWithExcessivePayment() public {
        string memory uri = "ipfs://QmTest";
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: mintPrice + 1 ether}(uri);

        assertEq(tokenId, 1);
        assertEq(pandaNFT.balanceOf(user1), 1);
    }

    function test_MintWhenMaxSupplyReached() public {
        uint256 maxSupply = pandaNFT.MAX_SUPPLY();
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        // Mint until max supply
        for (uint256 i = 0; i < maxSupply; i++) {
            vm.prank(address(uint160(i + 1)));
            pandaNFT.mint{value: mintPrice}(uri);
        }

        assertEq(pandaNFT.totalSupply(), maxSupply);

        // Try to mint beyond max supply
        vm.expectRevert(bytes("Max supply reached"));
        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);
    }

    function test_MintEmitEvent() public {
        string memory uri = "ipfs://QmTest";
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.expectEmit(true, true, false, true);
        emit NFTMinted(user1, 1, uri);

        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);
    }

    // ============= Token URI Tests =============

    function test_TokenURIReturnsCorrectURI() public {
        string memory uri = "ipfs://QmTest123";
        uint256 mintPrice = pandaNFT.mintPrice();

        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(uri);

        assertEq(pandaNFT.tokenURI(tokenId), uri);
    }

    function test_TokenURIRevertsForNonexistentToken() public {
        vm.expectRevert();
        pandaNFT.tokenURI(999);
    }

    // ============= Total Supply Tests =============

    function test_TotalSupplyTracking() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        assertEq(pandaNFT.totalSupply(), 0);

        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);
        assertEq(pandaNFT.totalSupply(), 1);

        vm.prank(user2);
        pandaNFT.mint{value: mintPrice}(uri);
        assertEq(pandaNFT.totalSupply(), 2);
    }

    // ============= Mint Price Tests =============

    function test_SetMintPrice() public {
        uint256 newPrice = 0.05 ether;

        pandaNFT.setMintPrice(newPrice);
        assertEq(pandaNFT.mintPrice(), newPrice);
    }

    function test_SetMintPriceOnlyOwner() public {
        uint256 newPrice = 0.05 ether;

        vm.expectRevert();
        vm.prank(user1);
        pandaNFT.setMintPrice(newPrice);
    }

    function test_SetMintPriceZeroReverts() public {
        vm.expectRevert(bytes("MintPrice must great than 0"));
        pandaNFT.setMintPrice(0);
    }

    function test_MintWithNewPrice() public {
        uint256 newPrice = 0.05 ether;
        string memory uri = "ipfs://QmTest";

        pandaNFT.setMintPrice(newPrice);

        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: newPrice}(uri);
        assertEq(tokenId, 1);
    }

    // ============= Withdrawal Tests =============

    function test_WithdrawSuccess() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        // Mint NFTs to accumulate balance
        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);

        vm.prank(user2);
        pandaNFT.mint{value: mintPrice}(uri);

        uint256 expectedBalance = mintPrice * 2;
        assertEq(address(pandaNFT).balance, expectedBalance);

        // Withdraw
        uint256 ownerBalanceBefore = owner.balance;
        pandaNFT.withdraw();

        assertEq(address(pandaNFT).balance, 0);
        assertEq(owner.balance, ownerBalanceBefore + expectedBalance);
    }

    function test_WithdrawOnlyOwner() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);

        vm.expectRevert();
        vm.prank(user2);
        pandaNFT.withdraw();
    }

    function test_WithdrawNoBalance() public {
        vm.expectRevert(bytes("No balance to withdrwa"));
        pandaNFT.withdraw();
    }

    // ============= Royalty Tests =============

    function test_SetDefaultRoyalty() public {
        address royaltyAddress = address(0x5);
        uint96 royaltyBps = 500; // 5%

        pandaNFT.setDefaultRoyalty(royaltyAddress, royaltyBps);

        // Mint an NFT and check royalty info
        string memory uri = "ipfs://QmTest";
        uint256 mintPrice = pandaNFT.mintPrice();
        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(uri);

        (address receiver, uint256 royaltyAmount) = pandaNFT.royaltyInfo(tokenId, 10000);
        assertEq(receiver, royaltyAddress);
        assertEq(royaltyAmount, 500); // 5% of 10000
    }

    function test_SetDefaultRoyaltyOnlyOwner() public {
        address royaltyAddress = address(0x5);
        uint96 royaltyBps = 500;

        vm.expectRevert();
        vm.prank(user1);
        pandaNFT.setDefaultRoyalty(royaltyAddress, royaltyBps);
    }

    function test_SetTokenRoyalty() public {
        // First mint an NFT
        string memory uri = "ipfs://QmTest";
        uint256 mintPrice = pandaNFT.mintPrice();
        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(uri);

        // Set token-specific royalty
        address royaltyAddress = address(0x6);
        uint96 royaltyBps = 1000; // 10%

        pandaNFT.setTokenRoyalty(tokenId, royaltyAddress, royaltyBps);

        (address receiver, uint256 royaltyAmount) = pandaNFT.royaltyInfo(tokenId, 10000);
        assertEq(receiver, royaltyAddress);
        assertEq(royaltyAmount, 1000); // 10% of 10000
    }

    function test_SetTokenRoyaltyOnlyOwner() public {
        string memory uri = "ipfs://QmTest";
        uint256 mintPrice = pandaNFT.mintPrice();
        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(uri);

        vm.expectRevert();
        vm.prank(user2);
        pandaNFT.setTokenRoyalty(tokenId, user2, 500);
    }

    // ============= Interface Tests =============

    function test_SupportsERC721Interface() public view {
        // ERC721 interface ID
        assertTrue(pandaNFT.supportsInterface(0x80ac58cd));
    }

    function test_SupportsERC2981Interface() public view {
        // ERC2981 interface ID
        assertTrue(pandaNFT.supportsInterface(0x2a55205a));
    }

    function test_SupportsERC165Interface() public view {
        // ERC165 interface ID
        assertTrue(pandaNFT.supportsInterface(0x01ffc9a7));
    }

    // ============= Balance and Ownership Tests =============

    function test_BalanceOf() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);

        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);

        assertEq(pandaNFT.balanceOf(user1), 2);
    }

    function test_OwnerOf() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        vm.prank(user1);
        uint256 tokenId = pandaNFT.mint{value: mintPrice}(uri);

        assertEq(pandaNFT.ownerOf(tokenId), user1);
    }

    // ============= Edge Cases =============

    function test_MintMultipleUsersMultipleTimes() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            pandaNFT.mint{value: mintPrice}(uri);

            vm.prank(user2);
            pandaNFT.mint{value: mintPrice}(uri);
        }

        assertEq(pandaNFT.balanceOf(user1), 3);
        assertEq(pandaNFT.balanceOf(user2), 3);
        assertEq(pandaNFT.totalSupply(), 6);
    }

    function test_WithdrawMultipleTimes() public {
        uint256 mintPrice = pandaNFT.mintPrice();
        string memory uri = "ipfs://QmTest";

        // First withdrawal
        vm.prank(user1);
        pandaNFT.mint{value: mintPrice}(uri);

        uint256 ownerBalanceBefore = owner.balance;
        pandaNFT.withdraw();
        assertEq(owner.balance, ownerBalanceBefore + mintPrice);

        // Second withdrawal should fail (no balance)
        vm.expectRevert("No balance to withdrwa");
        pandaNFT.withdraw();

        // Mint again and withdraw
        vm.prank(user2);
        pandaNFT.mint{value: mintPrice}(uri);

        ownerBalanceBefore = owner.balance;
        pandaNFT.withdraw();
        assertEq(owner.balance, ownerBalanceBefore + mintPrice);
    }
}