// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* 
    1. 实现ERC721 ERC721URIStorage Ownable ERC2981
    2. 状态变量：tokenId计数器，最大供应量，铸造价格 0.01 ether
    3. 事件：NFT铸造事件
    4. 方法：铸造NFT，重写tokenURI，检查接口支持，查询总供应量，提取铸造费用，设置铸造价格
*/
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC2981 } from "@openzeppelin/contracts/token/common/ERC2981.sol";

/**
 * @title PandaNFT
 * @author warmstone
 * @notice 铸造NFT，设置版税
 */
contract PandaNFT is ERC721, ERC721URIStorage, ERC2981, Ownable {
    // tokenId计数器
    uint256 private _tokenIdCounter;
    // 最大供应量
    uint256 public constant MAX_SUPPLY = 10000;
    // 铸造价格
    uint256 public mintPrice = 0.01 ether;

    /**
     * NFT铸造事件
     * @param minter 铸造人
     * @param tokenId tokenId
     * @param uri uir
     */
    event NFTMinted(address indexed minter, uint256 indexed tokenId, string uri);

    /**
     * 构造器，设置默认版税
     */
    constructor() ERC721("PandaNFT", "PNFT") Ownable(msg.sender) {
        // 默认版税
        _setDefaultRoyalty(msg.sender, 1000);
    }

    /**
     * 设置默认版税信息
     * @param royalty 版税接收地址
     * @param royaltyBps 版税比例
     */
    function setDefaultRoyalty(address royalty, uint96 royaltyBps) external onlyOwner {
        _setDefaultRoyalty(royalty, royaltyBps);
    }

    /**
     * 设置单个NFT版税信息
     * @param tokenId NFT tokenId
     * @param royalty 版税接收地址
     * @param royaltyBps 版税比例
     */
    function setTokenRoyalty(uint256 tokenId, address royalty, uint96 royaltyBps) external onlyOwner {
        _setTokenRoyalty(tokenId, royalty, royaltyBps);
    }


    /**
     * @dev 铸造NFT
     * @param uri uri
     */
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

    /**
     * @dev 查询总供应量
     */
    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter;
    }

    /**
     * @dev 提取铸造费用
     */
    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdrwa");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @dev 设置铸造价格
     * @param newPrice 新铸造价格
     */
    function setMintPrice(uint256 newPrice) public onlyOwner {
        require(newPrice > 0, "MintPrice must great than 0");
        mintPrice = newPrice;
    }

    /**
     * @dev 重写 tokenURI
     * @param tokenId tokenId
     */
    function tokenURI(uint256 tokenId) public override(ERC721, ERC721URIStorage) view returns (string memory) {
        return super.tokenURI(tokenId);
    }

    /**
     * @dev 重写supportsInterface
     * @param interfaceId 接口Id
     */
    function supportsInterface(bytes4 interfaceId) public override(ERC721, ERC721URIStorage, ERC2981) view returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
}