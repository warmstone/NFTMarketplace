pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PandaCoin} from "../src/PandaCoin.sol";

contract DeployPandaCoin is Script {
    // 代币名称
    string constant TOKEN_NAME = "PandaCoin";
    // 代币符号
    string constant TOKEN_SYMBOL = "PdC";
    // 初始供应量（1000 个代币，18 位小数）
    uint256 constant INITIAL_SUPPLY = 1000 * 10 ** 18;

    function run() external returns (PandaCoin pandaCoin) {
        // 获取部署者地址作为初始代币接收者
        address deployer = msg.sender;

        // 如果要部署到本地链，可以使用以下方式获取地址
        // address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("Deploying ERC20 token...");
        console.log("Token Name:", TOKEN_NAME);
        console.log("Token Symbol:", TOKEN_SYMBOL);
        console.log("Initial Supply:", INITIAL_SUPPLY);
        console.log("Initial Recipient:", deployer);

        vm.startBroadcast();
        pandaCoin = new PandaCoin(TOKEN_NAME, TOKEN_SYMBOL, INITIAL_SUPPLY, deployer);
        vm.stopBroadcast();

        console.log("ERC20 Token deployed at:", address(pandaCoin));
        console.log("Deployer balance:", pandaCoin.balanceOf(deployer));
    }
}
