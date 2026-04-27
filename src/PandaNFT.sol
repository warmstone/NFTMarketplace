// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* 
    1. 实现ERC721 ERC721URIStorage Ownable 
    2. 状态变量：tokenId计数器，最大供应量，铸造价格 0.01 ether
    3. 事件：NFT铸造事件
    4. 方法：铸造NFT，重写tokenURI，检查接口支持，查询总供应量，提取铸造费用，设置铸造价格    
*/

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract PandaNFT is ERC721, ERC721URIStorage, ERC2981, Ownable {

    uint256 private _tokenIdCounter;
    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public mintPrice = 0.01 ether;

    event NFTMinted(address indexed minter, uint256 indexed tokenId, string uri);

    constructor() ERC721("PandaNFT", "PNFT") Ownable(msg.sender) {
        // 默认版税
        _setDefaultRoyalty(msg.sender, 1000);
    }

    // function setDefaultRoyalty(address royalty, uint96 rolyaltyBps) external onlyOwner {

    // }

    function mint(string memory uri) public payable returns (uint256) {
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");
        require(msg.value >= mintPrice, "Insufficient payment");

        _tokenIdCounter++;
        uint256 newTokenId = _tokenIdCounter;

        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, uri);

        emit NFTMinted(msg.sender, newTokenId, uri);

        return newTokenId;
    }

    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter;
    }

    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdrwa");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
    }

    function setMintPrice(uint256 newPrice) public onlyOwner {
        require(newPrice > 0, "MintPrice must great than 0");
        mintPrice = newPrice;
    }

    function tokenURI(uint256 tokenId) public override(ERC721, ERC721URIStorage) view returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public override(ERC721, ERC721URIStorage, ERC2981) view returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
}