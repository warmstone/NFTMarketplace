// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NFTMarketplaceUpgradeable} from "../src/upgradeable/NFTMarketplaceUpgradeable.sol";

contract DeployNFTMarketplaceUpgradeable is Script {
    function run() external returns (NFTMarketplaceUpgradeable marketplace, NFTMarketplaceUpgradeable implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address ethUsdPriceFeed = vm.envOr("ETH_USD_PRICE_FEED", address(0));
        uint256 ethFeedMaxStaleness = vm.envOr("ETH_PRICE_FEED_MAX_STALENESS", uint256(1 days));
        address paymentToken = vm.envOr("PAYMENT_TOKEN", address(0));
        address paymentTokenUsdPriceFeed = vm.envOr("PAYMENT_TOKEN_USD_PRICE_FEED", address(0));
        uint256 paymentTokenFeedMaxStaleness = vm.envOr("PAYMENT_TOKEN_PRICE_FEED_MAX_STALENESS", uint256(1 days));

        vm.startBroadcast(deployerPrivateKey);
        implementation = new NFTMarketplaceUpgradeable();
        bytes memory initData = abi.encodeCall(NFTMarketplaceUpgradeable.initialize, (deployer, feeRecipient));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        marketplace = NFTMarketplaceUpgradeable(address(proxy));

        if (ethUsdPriceFeed != address(0)) {
            marketplace.setPriceFeed(address(0), ethUsdPriceFeed, 18, ethFeedMaxStaleness);
        }

        if (paymentToken != address(0)) {
            marketplace.setPaymentTokenAllowed(paymentToken, true);

            if (paymentTokenUsdPriceFeed != address(0)) {
                marketplace.setERC20PriceFeed(paymentToken, paymentTokenUsdPriceFeed, paymentTokenFeedMaxStaleness);
            }
        }

        vm.stopBroadcast();
    }
}
