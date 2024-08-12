// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./utils/token/ERC20.sol";
import "./utils/owner/Ownable.sol";
import "./utils/token/extensions/ERC20Burnable.sol";

contract BondingCurveToken is ERC20, ERC20Burnable, Ownable {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) public virtual override {
        super.burnFrom(account, amount);
    }
}