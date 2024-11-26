// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BancorBondingCurve} from "./gate/BancorBondingCurve.sol";
import "./BondingCurveToken.sol";
import "./utils/owner/Ownable.sol";
import "./Interface/IUniswapV2Router02.sol";
// import "./Interface/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title BondingCurveManager
 * @dev Manages bonding curve tokens, allowing creation, buying, selling, and liquidity management.
 */
contract BondingCurveManager is Ownable, ReentrancyGuard {
    BancorBondingCurve private bancorFormula;

    IUniswapV2Router02 private immutable uniRouter;
    // IUniswapV2Factory private immutable uniFactory;


    struct TokenInfo {
        BondingCurveToken token;
        uint256 tokenbalance;
        uint256 ethBalance;
        bool isListed;
    }

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    uint256 private constant FEE_PERCENTAGE = 1e16; // 1% = 1e16
    uint256 private LP_FEE_PERCENTAGE = 5e16; // 5% = 5e16
    uint256 private constant MAX_POOL_BALANCE = 2500 ether;

    address private immutable LP_BURN_ADDR = 0x000000000000000000000000000000000000dEaD;
    address payable private feeRecipient;

    // Events
    event TokenCreated(address indexed tokenAddress, address indexed creator, string name, string symbol);
    event TokensBought(address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event TokensSold(address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount);
    event LiquidityAdded(address indexed token, uint256 ethAmount, uint256 tokenAmount);

    // Custom Errors
    error TokenDoesNotExist();
    error TokenAlreadyListed();
    error ZeroEthSent();
    error ZeroTokenAmount();
    error FailedToSendEth();
    error MaxPoolBalanceReached();
    error InsufficientPoolbalance();
    error TokenTransferFailed();
    error InvalidRecipient();
    error InvalidLpFeePercentage();
    error PairCreationFailed();

    /**
     * @dev Constructor initializes the contract with the Uniswap router, BancorFormula1 address, and fee recipient.
     * @param _uniRouter Address of the Uniswap V2 Router.
     * @param _bancorFormula Address of the deployed BancorFormula1 contract.
     * @param _feeRecipient Address to receive the fees.
     */
    constructor(
        address _uniRouter,
        // address _uniFactory,
        address _bancorFormula,
        address payable _feeRecipient
    ) {
        uniRouter = IUniswapV2Router02(_uniRouter);
        // uniFactory = IUniswapV2Factory(_uniFactory);
        bancorFormula = BancorBondingCurve(_bancorFormula);
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Creates a new bonding curve token.
     * @param name The name of the new token.
     * @param symbol The symbol of the new token.
     */
    function create(string calldata name, string calldata symbol) external payable nonReentrant {
        BondingCurveToken newToken = new BondingCurveToken(name, symbol);
        address tokenAddress = address(newToken);

        tokens[tokenAddress] = TokenInfo({
            token: newToken,
            tokenbalance: 0,
            ethBalance: 0,
            isListed: false
        });
        tokenList.push(tokenAddress);

        // Transfer the trading supply from the token to this manager contract
        newToken.transferTradingSupply(address(this));

        // Verify that tokens were successfully transferred
        uint256 transferredAmount = newToken.balanceOf(address(this));
        if (transferredAmount == 0) revert TokenTransferFailed();
        tokens[tokenAddress].tokenbalance = transferredAmount;

        emit TokenCreated(tokenAddress, msg.sender, name, symbol);

        // // Create a Uniswap pair for the new token and weth
        // address pair = uniFactory.createPair(tokenAddress, uniRouter.WETH());
        // if (pair == address(0)) revert PairCreationFailed();


        // If ETH is sent during token creation, buy tokens on behalf of the creator
        if (msg.value > 0) {
            buyTokenForCreator(tokenAddress, msg.value);
        }
    }


    /**
     * @notice Buys tokens for a specified token address.
     * @param tokenAddress The address of the token to buy.
     */
    function buy(address tokenAddress) external payable nonReentrant {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (msg.value == 0) revert ZeroEthSent();

        uint256 currentEthBalance = tokenInfo.ethBalance;
        uint256 remainingEthToMax = MAX_POOL_BALANCE > currentEthBalance ? MAX_POOL_BALANCE - currentEthBalance : 0;
        if (remainingEthToMax == 0) revert MaxPoolBalanceReached();

        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;

        uint256 feeDenominator = 1e18 - FEE_PERCENTAGE;
        uint256 maxActualEthContribution = (remainingEthToMax * 1e18) / feeDenominator;

        uint256 actualEthContribution = msg.value > maxActualEthContribution ? maxActualEthContribution : msg.value;

        // Calculate fee and ETH to be used for purchasing tokens
        uint256 fee = calculateFee(actualEthContribution, FEE_PERCENTAGE);
        uint256 ethForTokens = actualEthContribution - fee;

        // Calculate the number of tokens the user can buy with ethForTokens
        uint256 tokensToTransfer = bancorFormula.computeMintingAmountFromPrice(currentEthBalance, totalSupply, ethForTokens);

        // If tokensToTransfer exceeds availableTokens, adjust tokensToTransfer without recalculating fee and ethForTokens
        if (tokensToTransfer > availableTokens) {
            tokensToTransfer = availableTokens;
            // Calculate ethForTokens based on tokensToTransfer without recalculating
            ethForTokens = bancorFormula.computePriceForMinting(currentEthBalance, totalSupply, tokensToTransfer);
            fee = calculateFee(ethForTokens, FEE_PERCENTAGE);
            actualEthContribution = ethForTokens + fee;
        }

        // Update balances
        tokenInfo.ethBalance = currentEthBalance + ethForTokens;
        tokenInfo.tokenbalance -= tokensToTransfer;

        // Transfer fee to feeRecipient
        if (fee > 0) {
            (bool feeSent, ) = feeRecipient.call{value: fee}("");
            if (!feeSent) revert FailedToSendEth();
        }

        // Transfer tokens to buyer
        if (!token.transfer(msg.sender, tokensToTransfer)) {
            revert TokenTransferFailed();
        }

        // Refund excess ETH if any
        uint256 excessEth = msg.value > actualEthContribution ? msg.value - actualEthContribution : 0;
        if (excessEth > 0) {
            (bool sent, ) = msg.sender.call{value: excessEth}("");
            if (!sent) revert FailedToSendEth();
        }

        emit TokensBought(tokenAddress, msg.sender, ethForTokens, tokensToTransfer);

        // **New Liquidity Check Using Internal Function**
        if (shouldAddLiquidity(tokenInfo)) {
            _addLiquidity(tokenAddress);
        }
    }

    /**
     * @notice Sells tokens for a specified token address.
     * @param tokenAddress The address of the token to sell.
     * @param tokenAmount The amount of tokens to sell.
     */
    function sell(address tokenAddress, uint256 tokenAmount) external nonReentrant {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (tokenAmount == 0) revert ZeroTokenAmount();

        uint256 currentEthBalance = tokenInfo.ethBalance;
        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;

        uint256 ethToReturn = bancorFormula.computeRefundForBurning(currentEthBalance, totalSupply, tokenAmount);
        uint256 fee = calculateFee(ethToReturn, FEE_PERCENTAGE);
        uint256 ethAfterFee = ethToReturn - fee;

        if (currentEthBalance < ethToReturn) revert InsufficientPoolbalance();
        unchecked {
            tokenInfo.ethBalance -= ethToReturn;
            tokenInfo.tokenbalance += tokenAmount;
        }

        if (fee > 0) {
            (bool feeSent, ) = feeRecipient.call{value: fee}("");
            if (!feeSent) revert FailedToSendEth();
        }

        if (!token.transferFrom(msg.sender, address(this), tokenAmount)) {
            revert TokenTransferFailed();
        }

        (bool sent, ) = msg.sender.call{value: ethAfterFee}("");
        if (!sent) revert FailedToSendEth();

        emit TokensSold(tokenAddress, msg.sender, tokenAmount, ethAfterFee);
    }

    /**
     * @dev Buys tokens on behalf of the creator during token creation.
     * @param tokenAddress The address of the token.
     * @param ethAmount The amount of ETH sent.
     */
    function buyTokenForCreator(address tokenAddress, uint256 ethAmount) internal {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        uint256 currentEthBalance = tokenInfo.ethBalance;
        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;
        uint256 fee = calculateFee(ethAmount, FEE_PERCENTAGE);
        uint256 ethForTokens = ethAmount - fee;

        uint256 tokensToTransfer = bancorFormula.computeMintingAmountFromPrice(currentEthBalance, totalSupply, ethForTokens);

        // Ensure that the tokens purchased do not exceed of the trading supply
        if (tokensToTransfer > availableTokens) {
            tokensToTransfer = availableTokens;
            ethForTokens = bancorFormula.computePriceForMinting(
                currentEthBalance,
                totalSupply,
                tokensToTransfer
            );
            fee = calculateFee(ethForTokens, FEE_PERCENTAGE);
        }


        // Update token eth balance/pool
        tokenInfo.ethBalance += ethForTokens;
        tokenInfo.tokenbalance -= tokensToTransfer;

        if (fee > 0) {
            (bool feeSent, ) = feeRecipient.call{value: fee}("");
            if (!feeSent) revert FailedToSendEth();
        }

        if (!token.transfer(msg.sender, tokensToTransfer)) {
            revert TokenTransferFailed();
        }

        uint256 excessEth = ethAmount > ethForTokens + fee ? ethAmount - (ethForTokens + fee) : 0;
        if (excessEth > 0) {
            (bool sent, ) = msg.sender.call{value: excessEth}("");
            if (!sent) revert FailedToSendEth();
        }

        emit TokensBought(tokenAddress, msg.sender, ethForTokens, tokensToTransfer);
    }

    function _addLiquidity(address tokenAddress) internal {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (tokenInfo.isListed) revert TokenAlreadyListed();

        uint256 totalEthBalance = tokenInfo.ethBalance;
        uint256 lpFee = calculateFee(totalEthBalance, LP_FEE_PERCENTAGE);
        uint256 ethForLiquidity = totalEthBalance - lpFee;

        token.transferLPSupply(address(this));
        uint256 tokensForLiquidity = token.LP_SUPPLY() + tokenInfo.tokenbalance;

        // Update state variables before external calls to prevent re-entrancy
        tokenInfo.tokenbalance = 0;
        tokenInfo.ethBalance = 0;
        tokenInfo.isListed = true;

        // Transfer LP fee to the fee recipient
        if (lpFee > 0) {
            (bool feeSent, ) = feeRecipient.call{value: lpFee}("");
            if (!feeSent) revert FailedToSendEth();
        }

        token.approve(address(uniRouter), tokensForLiquidity);

        // Add liquidity to Uniswap
        (uint256 amountToken, uint256 amountETH, ) = uniRouter.addLiquidityETH{value: ethForLiquidity}(
            tokenAddress,
            tokensForLiquidity,
            0, 
            0,
            LP_BURN_ADDR, 
            block.timestamp
        );

        token.renounceOwnership();

        emit LiquidityAdded(tokenAddress, amountETH, amountToken);
    }


    /**
     * @dev Manually adds liquidity for a specified token.
     * Can only be called by the contract owner.
     * 
     * @param tokenAddress The address of the token to add liquidity for.
     * To be used in situations where the bond owner wants to shutdown and 
     * ensure tokens are safely moved to DEX.
     */
    function addLP(address tokenAddress) external onlyOwner nonReentrant {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();

        _addLiquidity(tokenAddress);
    }

    /**
     * @notice Sets the LP fee percentage.
     * @param _lpFeePercentage The new LP fee percentage in WAD (must not exceed 5%).
     */
    function setLpFeePercentage(uint256 _lpFeePercentage) external onlyOwner {
        if (_lpFeePercentage > 5e16) revert InvalidLpFeePercentage();
        LP_FEE_PERCENTAGE = _lpFeePercentage;
    }

    /**
     * @notice Retrieves the ETH balance for a specific token.
     * @param tokenAddress The address of the token.
     * @return The ETH balance of the token pool.
     */
    function getTokenEthBalance(address tokenAddress) external view returns (uint256) {
        return tokens[tokenAddress].ethBalance;
    }

    /**
     * @notice Updates the fee recipient address.
     * @param _newRecipient The new address to receive fees.
     */
    function setFeeRecipient(address payable _newRecipient) external onlyOwner {
        if (_newRecipient == address(0)) revert InvalidRecipient();
        feeRecipient = _newRecipient;
    }


    function setBancorFormula(address _bancorFormula) external onlyOwner {
        bancorFormula = BancorBondingCurve(_bancorFormula);
    }

    /**
    * @dev Checks if liquidity should be added based on token balance or ETH balance.
    * @param tokenInfo The TokenInfo struct containing token details.
    * @return True if tokenbalance is zero or ethBalance is >= 99% of MAX_POOL_BALANCE, else false.
    */
    function shouldAddLiquidity(TokenInfo storage tokenInfo) internal view returns (bool) {
        uint256 ninetyNinePercent = (MAX_POOL_BALANCE * 99) / 100;
        return (tokenInfo.tokenbalance == 0 || tokenInfo.ethBalance >= ninetyNinePercent);
    }

    /**
     * @notice Calculates the number of tokens that can be purchased for a given amount of ETH.
     * @param tokenAddress The address of the token.
     * @param ethAmount The amount of ETH to spend.
     * @return The number of tokens that can be purchased.
     */
    function calculateCurvedBuyReturn(address tokenAddress, uint256 ethAmount) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (ethAmount == 0) revert ZeroEthSent();

        uint256 currentEthBalance = tokenInfo.ethBalance;
        uint256 fee = calculateFee(ethAmount, FEE_PERCENTAGE);
        uint256 ethForTokens = ethAmount - fee;
        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;

        return bancorFormula.computeMintingAmountFromPrice(
            currentEthBalance,
            totalSupply,
            ethForTokens
        );
    }

    /**
     * @notice Calculates the amount of ETH that will be returned for selling a given amount of tokens.
     * @param tokenAddress The address of the token.
     * @param tokenAmount The amount of tokens to sell.
     * @return The amount of ETH that will be returned after fees.
     */
    function calculateCurvedSellReturn(address tokenAddress, uint256 tokenAmount) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        uint256 currentEthBalance = tokenInfo.ethBalance;
        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (tokenAmount == 0) revert ZeroTokenAmount();

        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;

        uint256 ethToReturn = bancorFormula.computeRefundForBurning(
            currentEthBalance,
            totalSupply,
            tokenAmount
        );

        uint256 fee = calculateFee(ethToReturn, FEE_PERCENTAGE);
        return ethToReturn - fee;
    }

    /**
     * @dev Calculates the current price of a token based on its supply.
     * @param tokenSupply The current supply of the token.
     * @return The current price of the token in ETH.
     */
    function calculateCurrentPrice(uint256 currentEthBalance,uint256 tokenSupply) internal view returns (uint256) {
        uint256 tokenAmount = 1e18;
        uint256 ethAmount = bancorFormula.computePriceForMinting(currentEthBalance, tokenSupply, tokenAmount);

        uint256 fee = calculateFee(ethAmount, FEE_PERCENTAGE);
        return ethAmount - fee;
    }

    /**
     * @notice Retrieves the current price of a specific token.
     * @param tokenAddress The address of the token.
     * @return The current price of the token in ETH.
     */
    function getCurrentTokenPrice(address tokenAddress) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();

        uint256 currentEthBalance = tokenInfo.ethBalance;
        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;

        return calculateCurrentPrice(
            currentEthBalance,
            totalSupply
        );
    }

    /**
     * @notice Calculates the market capitalization of a specific token.
     * @param tokenAddress The address of the token.
     * @return The market capitalization of the token in ETH.
     */
    function getMarketCap(address tokenAddress) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        if (address(token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();

        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 circulatingSupply = token.TRADING_SUPPLY() - availableTokens;

        uint256 currentPrice = getCurrentTokenPrice(tokenAddress);

        // Market cap: circulatingSupply * currentPrice
        uint256 marketCap = (circulatingSupply * currentPrice) / 1e18;

        return marketCap;
    }

    function calculateFee(
        uint256 _amount,
        uint256 _feePercent
    ) internal pure returns (uint256) {
        return (_amount * _feePercent) / 1e18;
    }

    /**
     * @notice Fallback function to accept ETH.
     */
    receive() external payable {}
}
