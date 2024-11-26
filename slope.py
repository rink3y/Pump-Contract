# this script is to calcute and find the slope to use when deploying the BancorBondingCurve.sol contract
# might look like this - example ==>>

#    Reserve Ratio (%) |     Slope (m) [Scientific Notation] |       Slope (m) [Full Decimal] |    Exponent (n)
# -------------------------------------------------------------------------------------------------------------
#                50.00 | 7.81250E-15                         | 0.000000000000007812           | 1.000000       
#                60.00 | 6.04374E-12                         | 0.000000000006043740           | 0.666666       
#                70.00 | 6.82562E-10                         | 0.000000000682562000           | 0.428571       
#                80.00 | 2.32267E-8                          | 0.000000023226700000           | 0.250000       
#                90.00 | 3.55939E-7                          | 0.000000355939000000           | 0.111111   
#bancor max weight ranges from 0 to like in the percentage ( start from 10% to 100% )
#in this smart contract the best range start from 0.5 to 0.9 ( same as 50% - 90% in the above table but i prefer 70% or 0.7)

import math
from decimal import Decimal, getcontext, Overflow, DivisionByZero, InvalidOperation, ROUND_DOWN
import matplotlib.pyplot as plt

#  precision high enough to handle large exponentiations and maintain accuracy
getcontext().prec = 1000  # 1000 decimal places

def calculate_slope(target_eth_raised, total_tokens, reserve_ratio):
    """
    Calculate the exponent (n) and slope (m) given the target ETH raised, total tokens, and reserve ratio.

    Parameters:
    - target_eth_raised (Decimal): Target ETH to raise (b)
    - total_tokens (Decimal): Total number of tokens (s)
    - reserve_ratio (Decimal): Reserve ratio (r) as a decimal (e.g., 0.1 for 10%)

    Returns:
    - n (Decimal): Calculated exponent (n) with high precision
    - m (Decimal): Calculated slope (m) with high precision
    """
    if not (Decimal('0') < reserve_ratio < Decimal('1')):
        raise ValueError("Reserve ratio must be between 0 and 1 (exclusive).")

    try:
        # Calculate n = (1/r) - 1
        n = (Decimal('1') / reserve_ratio) - Decimal('1')

        # Calculate s^(n+1) using high-precision arithmetic
        exponent = n + Decimal('1')  # Which is 1/r
        s_pow = total_tokens ** exponent

        # Calculate slope m
        m = (target_eth_raised * (n + Decimal('1'))) / s_pow

        return n, m
    except (Overflow, DivisionByZero, InvalidOperation) as e:
        raise OverflowError(f"Calculation overflowed: {e}")

def format_decimal_from_scientific(m_scientific, decimal_places=18):
    """
    Convert a scientific notation string to its full decimal representation with fixed decimal places.

    Parameters:
    - m_scientific (str): The slope in scientific notation (e.g., '6.04374E-12')
    - decimal_places (int): Number of decimal places for the full decimal representation

    Returns:
    - m_full_str (str): The full decimal representation as a string
    """
    mantissa_str, exponent_str = m_scientific.split('E')
    exponent = int(exponent_str)
    mantissa = Decimal(mantissa_str)

    # Shift decimal point based on exponent
    m_full = mantissa * (Decimal('10') ** exponent)

    # Create quantize format string (e.g., '1.000000000000000000' for 18 decimal places)
    quantize_str = '1.' + '0' * decimal_places

    # Quantize to the desired number of decimal places without rounding up
    m_full = m_full.quantize(Decimal(quantize_str), rounding=ROUND_DOWN)

    return f"{m_full:.{decimal_places}f}"

def format_n(n, decimal_places=6):
    """
    Format the exponent n with fixed decimal places.

    Parameters:
    - n (Decimal): The exponent value
    - decimal_places (int): Number of decimal places for formatting

    Returns:
    - n_str (str): The formatted exponent as a string
    """
    quantize_str = '1.' + '0' * decimal_places
    n_formatted = n.quantize(Decimal(quantize_str), rounding=ROUND_DOWN)
    return f"{n_formatted:.{decimal_places}f}"

def main():
    # Parameters for the simulation
    target_eth_raised = Decimal('2500')  # Target total ETH to raise
    total_tokens = Decimal('800000000')  # Total number of tokens (scaled down, no 1e18)

    # Define reserve ratios as decimals from 0.5 to 0.9 (50% to 90%)
    reserve_ratios = [Decimal(i) / Decimal('10') for i in range(5, 10)]  # 0.5 to 0.9

    # Lists to store results
    slopes = []
    exponents_n = []
    valid_reserve_ratios = []

    # Define the number of decimal places for full decimal representation and exponent
    decimal_places_m = 18
    decimal_places_n = 6

    # Print header with scientific notation, full decimal representations, and exponent n
    header = (
        f"{'Reserve Ratio (%)':>20} | "
        f"{'Slope (m) [Scientific Notation]':>35} | "
        f"{'Slope (m) [Full Decimal]':>30} | "
        f"{'Exponent (n)':>15}"
    )
    print(header)
    print("-" * len(header))

    for r in reserve_ratios:
        try:
            n, m = calculate_slope(target_eth_raised, total_tokens, r)
            slopes.append(m)
            exponents_n.append(n)
            valid_reserve_ratios.append(r)

            # Format m in scientific notation with 5 decimal places
            m_scientific = f"{m:.5E}"

            # Convert m_scientific to m_full with exact digits
            m_full = format_decimal_from_scientific(m_scientific, decimal_places_m)

            # Format exponent n with fixed decimal places
            n_formatted = format_n(n, decimal_places_n)

            print(
                f"{(r * 100):20.2f} | "
                f"{m_scientific:35} | "
                f"{m_full:30} | "
                f"{n_formatted:15}"
            )
        except OverflowError as oe:
            print(
                f"{(r * 100):20.2f} | "
                f"{'Overflow':>35} | "
                f"{'Overflow':>30} | "
                f"{'Overflow':>15}"
            )
        except ValueError as ve:
            print(
                f"{(r * 100):20.2f} | "
                f"{'Error: ' + str(ve):>35} | "
                f"{'Error: ' + str(ve):>30} | "
                f"{'Error: ' + str(ve):>15}"
            )

    # ploting the result
    plt.figure(figsize=(12, 7))

    slopes_float = [float(m) if m > Decimal('1e-300') else 0 for m in slopes]

    plt.plot(
        [float(r * 100) for r in valid_reserve_ratios],
        slopes_float,
        marker='o',
        linestyle='-',
        color='b'
    )

    plt.title('Slope (m) vs Reserve Ratio (r)')
    plt.xlabel('Reserve Ratio (%)')
    plt.ylabel('Slope (m)')
    plt.yscale('log') 
    plt.grid(True, which="both", ls="--")
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    main()
