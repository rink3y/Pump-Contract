// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./utils/token/ERC20.sol";
import "./utils/owner/Ownable.sol";
import "./utils/token/extensions/ERC20Burnable.sol";

contract BondingCurveToken is ERC20, ERC20Burnable, Ownable {
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant TRADING_SUPPLY = 800_000_000 * 10**18;
    uint256 public constant LP_SUPPLY = 200_000_000 * 10**18;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        // Mint total supply to the contract itself
        _mint(address(this), TOTAL_SUPPLY);
    }

    function transferTradingSupply(address manager) external onlyOwner {
        // Transfer trading supply to the bonding curve manager
        _transfer(address(this), manager, TRADING_SUPPLY);
    }

    function transferLPSupply(address manager) external onlyOwner {
        // Transfer LP supply to the bonding curve manager
        _transfer(address(this), manager, LP_SUPPLY);
    }

    function burnFrom(address account, uint256 amount) public virtual override {
        super.burnFrom(account, amount);
    }
}