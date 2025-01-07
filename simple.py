from decimal import Decimal, getcontext, Overflow, DivisionByZero, InvalidOperation, ROUND_DOWN

target_eth_number = Decimal('4')  # Target total ETH to raise
total_tokens_number = Decimal('800000000')  # Total number of tokens (scaled down, no 1e18)

def calculateBondingParams(target_eth_number, total_tokens_number):
    # Define constants
    RESERVE_RATIO = Decimal('0.7')  # r = 7/10
    DECIMAL_PLACES = 18
    ONE_E18 = Decimal('1e18')

    # Convert input parameters to Decimal
    target_eth = Decimal(target_eth_number)
    total_tokens = Decimal(total_tokens_number)

    # Calculate exponent (1 / reserve_ratio)
    exponent = Decimal('1') / RESERVE_RATIO

    # Compute s_pow = total_tokens ** exponent
    s_pow = total_tokens ** exponent

    # Calculate m = (target_eth * exponent) / s_pow
    m = (target_eth * exponent) / s_pow

    # Quantize m to 18 decimal places without rounding up
    quantize_format = Decimal('1.' + '0' * DECIMAL_PLACES)
    m_full = m.quantize(quantize_format, rounding=ROUND_DOWN)

    # Multiply by 1e18 to get the final parameter 'a'
    a = m_full * ONE_E18

    return a, RESERVE_RATIO

result, reserve_ratio = calculateBondingParams(target_eth_number, total_tokens_number)

# Scale and print the RESERVE_RATIO
scaled_reserve_ratio = int(reserve_ratio * 1000000)
print(f"RESERVE_RATIO = {scaled_reserve_ratio}")

# Print the slope
print(f"slope = {result}")
