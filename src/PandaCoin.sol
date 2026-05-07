// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PandaCoin is ERC20, Ownable {
    /**
     * @dev 构造函数
     * @param name 代币名称
     * @param symbol 代币符号
     * @param initialSupply 初始供应量（wei 单位）
     * @param recipient 初始代币接收地址
     */
    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        // 将初始供应量的代币铸造给指定地址
        _mint(recipient, initialSupply);
    }

    /**
     * @dev 允许合约所有者铸造新代币
     * @param to 接收代币的地址
     * @param amount 铸造的代币数量
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
