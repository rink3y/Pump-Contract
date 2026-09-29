// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BancorBondingCurve} from "./gate/BancorBondingCurve.sol";
import "./BondingCurveToken.sol";
import "./utils/owner/Ownable.sol";
import "./Interface/IUniswapV2Router02.sol";
import "./Interface/IUniswapV2Factory.sol";
import "./Interface/IUniswapV2Pair.sol";
import "./Interface/IWETH.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title BondingCurveManager
 * @dev Manages bonding curve tokens, allowing creation, buying, selling, and liquidity management.
 */
contract BondingCurveManager is Ownable, ReentrancyGuard {
    BancorBondingCurve private immutable bancorFormula;

    IUniswapV2Router02 private immutable uniRouter;
    IUniswapV2Factory private immutable uniFactory;
    IWETH private immutable weth;


    struct TokenInfo {
        BondingCurveToken token;
        address deployer;
        uint256 tokenbalance;
        uint256 ethBalance;
        bool isListed;
    }

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    uint256 private constant FEE_PERCENTAGE = 1e16; // 1% = 1e16
    uint256 private LP_FEE_PERCENTAGE = 5e16; // 5% = 5e16
    uint256 private constant MAX_POOL_BALANCE = 2500 ether;
    uint256 private constant ninetyNinePercent = (MAX_POOL_BALANCE * 99) / 100;

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
    error SlippageExceeded();

    /**
     * @dev Constructor initializes the contract with the Uniswap router, BancorFormula1 address, and fee recipient.
     * The Uniswap factory and WETH addresses are read from the router.
     * @param _uniRouter Address of the Uniswap V2 Router.
     * @param _bancorFormula Address of the deployed BancorFormula1 contract.
     * @param _feeRecipient Address to receive the fees.
     */
    constructor(
        address _uniRouter,
        address _bancorFormula,
        address payable _feeRecipient
    ) {
        uniRouter = IUniswapV2Router02(_uniRouter);
        uniFactory = IUniswapV2Factory(IUniswapV2Router02(_uniRouter).factory());
        weth = IWETH(IUniswapV2Router02(_uniRouter).WETH());
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
            deployer: msg.sender,
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

        // If ETH is sent during token creation, buy tokens on behalf of the creator.
        // Same rules as buy(); no slippage limit is needed since nobody can trade before it.
        if (msg.value > 0) {
            _buy(tokenAddress, msg.value, 0);
        }
    }


    /**
     * @notice Buys tokens for a specified token address.
     * @param tokenAddress The address of the token to buy.
     * @param minTokensOut The minimum amount of tokens to receive, otherwise the buy reverts.
     */
    function buy(address tokenAddress, uint256 minTokensOut) external payable nonReentrant {
        TokenInfo storage tokenInfo = tokens[tokenAddress];

        if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (msg.value == 0) revert ZeroEthSent();

        _buy(tokenAddress, msg.value, minTokensOut);
    }

    /**
     * @notice Sells tokens for a specified token address.
     * @param tokenAddress The address of the token to sell.
     * @param tokenAmount The amount of tokens to sell.
     * @param minEthOut The minimum amount of ETH to receive after fees, otherwise the sell reverts.
     */
    function sell(address tokenAddress, uint256 tokenAmount, uint256 minEthOut) external nonReentrant {
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
        if (ethAfterFee < minEthOut) revert SlippageExceeded();
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
     * @dev Shared buy logic for buy() and the creator's buy in create().
     * Buys stop at 99% of MAX_POOL_BALANCE, excess ETH is refunded to msg.sender,
     * and the token migrates to the DEX once the curve is complete.
     * @param tokenAddress The address of the token.
     * @param ethAmount The amount of ETH sent.
     * @param minTokensOut The minimum amount of tokens to receive.
     */
    function _buy(address tokenAddress, uint256 ethAmount, uint256 minTokensOut) internal {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        BondingCurveToken token = tokenInfo.token;

        uint256 currentEthBalance = tokenInfo.ethBalance;
        uint256 actualEthContribution;
        {
            uint256 remainingEthToMax = ninetyNinePercent > currentEthBalance ? ninetyNinePercent - currentEthBalance : 0;
            if (remainingEthToMax == 0) revert MaxPoolBalanceReached();

            uint256 feeDenominator = 1e18 - FEE_PERCENTAGE;
            uint256 maxActualEthContribution = (remainingEthToMax * 1e18) / feeDenominator;

            actualEthContribution = ethAmount > maxActualEthContribution ? maxActualEthContribution : ethAmount;
        }

        uint256 availableTokens = tokenInfo.tokenbalance;
        uint256 totalSupply = token.TRADING_SUPPLY() - availableTokens;

        // Calculate fee and ETH to be used for purchasing tokens
        uint256 fee = calculateFee(actualEthContribution, FEE_PERCENTAGE);
        uint256 ethForTokens = actualEthContribution - fee;

        // Calculate the number of tokens the user can buy with ethForTokens
        uint256 tokensToTransfer = bancorFormula.computeMintingAmountFromPrice(currentEthBalance, totalSupply, ethForTokens);

        // If tokensToTransfer exceeds availableTokens, charge only for the tokens that are left
        if (tokensToTransfer > availableTokens) {
            tokensToTransfer = availableTokens;
            uint256 priceForRemaining = bancorFormula.computePriceForMinting(currentEthBalance, totalSupply, tokensToTransfer);
            // Never charge more than the ETH that was actually sent (can only differ by rounding)
            if (priceForRemaining < ethForTokens) {
                ethForTokens = priceForRemaining;
                fee = calculateFee(ethForTokens, FEE_PERCENTAGE);
                actualEthContribution = ethForTokens + fee;
            }
        }

        if (tokensToTransfer < minTokensOut) revert SlippageExceeded();

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
        uint256 excessEth = ethAmount > actualEthContribution ? ethAmount - actualEthContribution : 0;
        if (excessEth > 0) {
            (bool sent, ) = msg.sender.call{value: excessEth}("");
            if (!sent) revert FailedToSendEth();
        }

        emit TokensBought(tokenAddress, msg.sender, ethForTokens, tokensToTransfer);

        if (shouldAddLiquidity(tokenInfo)) {
            _addLiquidity(tokenAddress);
        }
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

        // Unlock transfers so the tokens can move into the pair and trade freely from now on
        token.enableTransfers();

        // Add liquidity directly to the pair instead of through the router. The router reverts
        // if someone has donated WETH to the pair beforehand, which would block migration forever.
        // Token transfers were locked until now, so nobody can have minted LP in this pair.
        address pair = uniFactory.getPair(tokenAddress, address(weth));
        if (pair == address(0)) {
            pair = uniFactory.createPair(tokenAddress, address(weth));
            if (pair == address(0)) revert PairCreationFailed();
        }

        weth.deposit{value: ethForLiquidity}();
        if (!weth.transfer(pair, ethForLiquidity)) revert TokenTransferFailed();
        if (!token.transfer(pair, tokensForLiquidity)) revert TokenTransferFailed();
        IUniswapV2Pair(pair).mint(LP_BURN_ADDR);

        uint256 amountToken = tokensForLiquidity;
        uint256 amountETH = ethForLiquidity;

        // Any tokens left in the manager for this token (e.g. sent here by mistake) go to the deployer
        uint256 leftoverTokens = token.balanceOf(address(this));
        if (leftoverTokens > 0) {
            if (!token.transfer(tokenInfo.deployer, leftoverTokens)) revert TokenTransferFailed();
        }

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


    /**
    * @dev Checks if liquidity should be added based on token balance or ETH balance.
    * @param tokenInfo The TokenInfo struct containing token details.
    * @return True if tokenbalance is zero or ethBalance is >= 99% of MAX_POOL_BALANCE, else false.
    */
    function shouldAddLiquidity(TokenInfo storage tokenInfo) internal view returns (bool) {
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
}
