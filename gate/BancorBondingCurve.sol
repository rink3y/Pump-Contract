// SPDX-License-Identifier: MIT
//https://github.com/PaulRBerg/prb-math/blob/v2.5.0

pragma solidity ^0.8.26;

import "./BancorFormula.sol";
import "./math/PRBMathSD59x18.sol"; 
import "./math/PRBMathUD60x18.sol";


// based on https://medium.com/relevant-community/bonding-curves-in-depth-intuition-parametrization-d3905a681e0a
contract BancorBondingCurve is BancorFormula {
    using PRBMathSD59x18 for int256;
    using PRBMathUD60x18 for uint256;
    
    uint256 public immutable slope;
    uint32 public immutable reserveRatio;

    // reserveRatio = connectorWeight, but is scaled by MAX_WEIGHT (1000000)
    // also note that unscaled reserveRatio = 1 / (n+1), so a reserveRatio 1000000 means n=0, reserveRatio=2000000 means n=1, and so on
    // slope (denoted as m in the article) is only relevant when supply = 0. When supply is non-zero, the price for minting k tokens can be fully determined by current balance and supply
    constructor(uint256 _slope, uint32 _reserveRatio) {
        slope = _slope;
        reserveRatio = _reserveRatio;
    }

    // buy function
    /**
     * @notice Calculate the amount of collateral (ETH) required to mint a specific number of tokens.
     * @param b The current collateral balance in the bonding curve.
     * @param supply The current total supply of the token.
     * @param k The number of tokens to mint.
     * @return p The price (in collateral) required to mint `k` tokens.
     */
    function computePriceForMinting(uint256 b, uint256 supply, uint256 k) public view returns (uint256 p) {
        if (supply == 0) {
            // Use custom calculation for zero supply
            uint256 r = uint256(reserveRatio);
            uint256 m = slope;
            return computeP(k, r, m);
        }
        // Use Bancor's sale return calculation when supply is non-zero
        return calculateSaleReturn(supply + k, b, reserveRatio, k);
    }

    /**
     * @notice Computes the number of tokens that can be minted for a given amount of collateral.
     * @param b The current collateral balance in the bonding curve.
     * @param supply The current total supply of the token.
     * @param p The amount of collateral provided.
     * @return k The number of tokens that can be minted with `p` collateral.
     */
    function computeMintingAmountFromPrice(uint256 b, uint256 supply, uint256 p) public view returns (uint256 k) {
        if (supply == 0) {
            // uint256 result;
            // uint8 precision;
            // (result, precision) = power(p * MAX_WEIGHT, reserveRatio * slope, reserveRatio, MAX_WEIGHT);
            // return (result >> precision) * 1e18;
            // Custom formula when supply is zero: s = (p / (r * m))^r
            // Adjusted for integer math: s = (p * MAX_WEIGHT / (r * m))^(r / MAX_WEIGHT)

            uint256 baseNumerator = p * MAX_WEIGHT; // p * MAX_WEIGHT
            uint256 baseDenominator = uint256(reserveRatio) * slope; // r * m

            require(baseDenominator > 0, "Invalid base denominator");

            uint32 expNumerator = reserveRatio; // r
            uint32 expDenominator = MAX_WEIGHT; // 1,000,000

            /**
             * Compute s = (baseNumerator / baseDenominator)^(expNumerator / expDenominator)
             */
            return computeS(
            int256(baseNumerator),
            int256(baseDenominator),
            int256(uint256(expNumerator)),
            int256(uint256(expDenominator))
            );
        }
        return calculatePurchaseReturn(supply, b, reserveRatio, p);
    }

    // sell function
    /**
     * @notice Computes the amount of collateral refunded when burning a specific number of tokens.
     * @param b The current collateral balance in the bonding curve.
     * @param supply The current total supply of the token.
     * @param k The number of tokens to burn.
     * @return p The amount of collateral refunded for burning `k` tokens.
     */
    function computeRefundForBurning(uint256 b, uint256 supply, uint256 k) public view returns (uint256 p) {
        if (supply == k) {
            return b;
        }
        return calculateSaleReturn(supply, b, reserveRatio, k);
    }

    /**
     * @notice Computes the number of tokens that must be burned to receive a specific collateral refund.
     * @param b The current collateral balance in the bonding curve.
     * @param supply The current total supply of the token.
     * @param p The desired collateral refund.
     * @return k The number of tokens that must be burned to receive `p` collateral.
     */
    function computeBurningAmountFromRefund(uint256 b, uint256 supply, uint256 p) public view returns (uint256 k) {
        if (b == p) {
            return supply;
        }
        return calculatePurchaseReturn(supply, b - p, reserveRatio, p);
    }

    // helpers for buys

    /*
     * @dev Computes the deposit amount using the formula p = (r * m) * s^(1/r) or p = (r * m) * sqrt[r]{s} .
     * @param _tokenAmount Amount of tokens desired (s).
     * @param _reserveRatio Reserve ratio (r).
     * @param _slope Slope parameter (m).
     * @return Amount of reserve tokens(ETH) needed (p).
     */
    function computeP(
        uint256 s,
        uint256 r,
        uint256 m
    ) public pure returns (uint256 p) {
        // Calculate the exponentiation with high precision
        // s is scaled by 1e18, so s^(1/r) is also scaled by 1e18
        // 1e6 = MAX_WEIGHT
        uint256 exponentiation = PRBMathUD60x18.pow(s, (1e18 * 1e6) / r); // (s)^(1/r)
        
        // Calculate the deposit amount with correct scaling
        // p = (r * m * s^(1/r)) / 1e24
        // 1e6 (from reserveRatio) * 1e18 (fixed-point) = 1e24
        p = (r * m * exponentiation) / 1e24;
    }


    //test compute - worked 
    function computeS(
        int256 baseNumerator,
        int256 baseDenominator,
        int256 expNumerator,
        int256 expDenominator
    ) public pure returns (uint256 s) {
        // here i compute the base fraction
        int256 baseFraction = baseNumerator.div(baseDenominator);

        // then compute the exponent fraction
        int256 expFraction = expNumerator.div(expDenominator);

        // also compute the exponentiation
        int256 result = baseFraction.pow(expFraction);

        // result is non-negative
        require(result >= 0, "Result must be non-negative");

        // Convert the result to uint256
        s = uint256(result);
    }
}