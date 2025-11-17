# KipuBank V3: DeFi-Integrated Vault (Uniswap V2)

This repository presents the `KipuBankV3` smart contract, an advanced iteration of the decentralized banking vault. This version integrates directly with the **Uniswap V2 protocol**, transforming the bank from a multi-asset holding vault into a streamlined, DeFi-native application.

It enables users to deposit **native ETH or any ERC-20 token**, automatically **swaps them to USDC**, and credits the user's balance in the bank's single reserve asset.

## High-Level Upgrades & Rationale

`KipuBankV3` evolves from passive, oracle-priced storage to an active, protocol-integrated vault. The core principle is to **standardize all deposits into USDC**, which simplifies accounting, risk management, and enforcement of the bank's global cap.

* **Uniswap V2 Integration:** The contract no longer relies on a Chainlink price oracle. Instead, it uses the Uniswap V2 Router to perform real-time swaps. This "just-in-time" conversion acts as both the price discovery and asset consolidation mechanism.
* **USDC as the Sole Reserve Asset:** All deposits (ETH, DAI, LINK, etc.) are automatically converted to USDC. The bank's internal accounting and the `i_bankCapInUSD` now apply *directly* to the total USDC balance, removing all volatility risk from the bank's treasury.
* **Streamlined Deposit Logic:**
    * `depositETH()` & `receive()` use `swapExactETHForTokens`.
    * `depositERC20()` checks if the token is USDC (credits directly) or another token (uses `swapExactTokensForTokens`).
* **Preserved Access Control:** OpenZeppelin's `AccessControl` is maintained, with the `MANAGER_ROLE` governing treasury functions. The `withdraw` function is also preserved, but by design, it will now only succeed for withdrawing USDC.

## ⚙️ Deployment and Initialization Instructions

The `KipuBankV3` contract is designed for deployment on an EVM-compatible testnet like **Sepolia**.

### Deployment Parameters

The contract requires **five** constructor arguments to link it to the DeFi ecosystem and configure its security:

| Parameter | Type | Example Value (Sepolia) | Purpose |
| :--- | :--- | :--- | :--- |
| `_bankCapInUSD` | `uint256` | `1000000000000` | The **maximum total value (in 6 decimals USD)** the bank can hold. |
| `_initialAdmin` | `address` | `0x...` | The wallet address receiving the `DEFAULT_ADMIN_ROLE` and `MANAGER_ROLE`. |
| `_router` | `address` | `0xC5321161A7466D74B70A37634038424B2755D9C0` | The **Uniswap V2 Router** address. |
| `_usdc` | `address` | `0x1c7D4B196Cb0C7B01d743Fbc6116399B403B0364` | The **USDC token address** (6 decimals). |
| `_weth` | `address` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` | The **Wrapped ETH (WETH)** address. |

## How to Interact with KipuBank V3

### Function | Type | Purpose | Key Check
| :--- | :--- | :--- | :--- |
| **`depositETH()`** | `public payable` | Deposit native ETH. | Automatically swaps ETH for USDC and credits the user's USDC balance. |
| **`depositERC20(...)`** | `external` | Deposit any ERC-20 token (requires prior `approve`). | If USDC, credits directly. If *any other token*, swaps it to USDC and credits the resulting amount. |
| **`withdraw(...)`** | `external` | Withdraw deposited assets. | **Will only succeed if `_token` is the USDC address**, as all user balances are held in USDC. |

### Administration (MANAGER_ROLE)

* **`managerWithdrawTreasury(address _token)`:** Allows a manager to sweep the treasury balance. This is critical for withdrawing the bank's primary USDC holdings or rescuing any other tokens accidentally sent or failed during a swap.

## 📐 Design Decisions & Trade-offs

The primary design shift introduces a reliance on **Uniswap V2** instead of a price oracle.

1.  **Reliance on Protocol & Liquidity:** The bank's health is now tied to the liveness of the Uniswap V2 Router and the liquidity of the relevant pairs (e.g., WETH/USDC, DAI/USDC). Price discovery and conversion happen in a single atomic transaction.
2.  **Slippage Handling:** To maintain simple deposit functions, the `amountOutMin` for all swaps is hardcoded to `1`. This is a significant trade-off: it prevents a swap from failing entirely (0 output), but it **does not protect the user from high price slippage** in volatile markets or low-liquidity pools. A production-grade contract would require the user to pass their own `_amountOutMin` parameter.
3.  **Withdrawal Function:** The V2 function signature `withdraw(address _token, ...)` was intentionally preserved. This maintains interface consistency but creates a specific user experience: users *must* call `withdraw(USDC_ADDRESS, ...)` to retrieve their funds, as calls for any other token will fail with `KipuBank_InsufficientFunds`.
