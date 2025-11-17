// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title Kipu Bank V3 - Uniswap Integration
 * @notice A secure banking contract that accepts any Uniswap V2 token and converts it to USDC.
 * @notice This contract is for educational purposes.
 * @author Tadini Gabriel
 * @custom:security Do not use in production.
 */

/*///////////////////////////////////
 * Imports
 ///////////////////////////////////*/
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Uniswap V2 Interfaces
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

contract KipuBankV3 is AccessControl {
    /*///////////////////////////////////
     * Type Declarations
     ///////////////////////////////////*/
    /// @notice Role for treasury management and bank limit administration.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Applies SafeERC20 secure functions to all IERC20 interactions.
    using SafeERC20 for IERC20;

    /*///////////////////////////////////
     * Inmutable variables - constants
     ///////////////////////////////////*/
    /// @notice The maximum total value (in USD equivalent, 6 decimals) the bank can hold.
    uint256 public immutable i_bankCapInUSD;

    /// @notice Decimal factor for internal accounting (1 * 10^6), simulating the USDC base.
    uint256 public constant INTERNAL_DECIMALS = 1 * 10 ** 6;

    /// @notice Special address used to represent native Ether in the internal accounting mapping.
    address public constant ETH_TOKEN_ADDRESS = address(0);

    /*///////////////////////////////////
     * Immutable Variables
     ///////////////////////////////////*/
    /// @notice The Uniswap V2 Router interface.
    IUniswapV2Router02 public immutable i_uniswapRouter;

    /// @notice The WETH (Wrapped ETH) token interface.
    IWETH public immutable i_weth;

    /// @notice The USDC token interface (our base asset).
    IERC20 public immutable i_usdc;

    /*///////////////////////////////////
     * State variables
     ///////////////////////////////////*/
    // @notice Nested mapping to store each user's balance per token.
    // @dev All deposits are credited to s_balances[user][USDC_ADDRESS].
    mapping(address => mapping(address => uint256)) public s_balances;

    // @notice The current total value (in USD/USDC equivalent) deposited in the bank.
    uint256 private s_totalDepositedInUSD;

    /// @notice Counter for the total number of successful deposits made.
    uint256 public s_depositCount;

    /*///////////////////////////////////
     * Events
     ///////////////////////////////////*/
    /// @notice Event emitted when a user successfully deposits (always credited as USDC).
    event DepositMade(
        address indexed user,
        address indexed tokenDeposited, // The original token deposited
        address indexed tokenCredited, // Will always be USDC
        uint256 amountDeposited, // Amount of the original token
        uint256 usdcValue // The USDC value credited
    );

    /// @notice Event emitted when any asset is successfully withdrawn by a user.
    event WithdrawalMade(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice Event emitted when a manager withdraws funds from the bank treasury.
    event TreasuryWithdrawal(
        address indexed manager,
        address indexed token,
        uint256 amount
    );

    /*///////////////////////////////////
     * Errors
     ///////////////////////////////////*/
    /// @notice Error thrown when a native or ERC20 transfer transaction fails.
    error KipuBank_TransferFailed();

    /// @notice Error thrown when the deposit exceeds the global limit in USD.
    error KipuBank_GlobalLimitExceeded(
        uint256 cap,
        uint256 current,
        uint256 depositValue
    );

    /// @notice Error thrown when a user attempts to withdraw more than their balance.
    error KipuBank_InsufficientFunds(
        address user,
        address token,
        uint256 actual,
        uint256 attempt
    );

    /// @notice Error if attempting to deposit ETH using the ERC20 function.
    error KipuBank_UseDepositETHForNativeToken();

    /// @notice Error if the Uniswap swap does not produce at least 1 wei of USDC.
    error KipuBank_SwapFailed();



    /*///////////////////////////////////
     * Modifiers
     ///////////////////////////////////*/
    /**
     * @notice Modifier that restricts function access to addresses with the MANAGER_ROLE.
     */
    modifier onlyManager() {
        // AccessControl provides the _checkRole function which handles the revert if the role is missing.
        _checkRole(MANAGER_ROLE, _msgSender());
        _;
    }

    /*///////////////////////////////////
     * Constructor
     ///////////////////////////////////*/
    /**
     * @notice Constructor for the KipuBankV3 contract.
     * @param _bankCapInUSD The maximum global cap of the bank, in USD (6 decimals).
     * @param _initialAdmin The initial administrator of the contract.
     * @param _router The address of the Uniswap V2 Router.
     * @param _usdc The address of the USDC token (6 decimals).
     * @param _weth The address of the WETH token.
     */
    constructor(
        uint256 _bankCapInUSD,
        address _initialAdmin,
        address _router,
        address _usdc,
        address _weth
    ) {
        // Initializes AccessControl and sets up roles.
        AccessControl._grantRole(
            AccessControl.DEFAULT_ADMIN_ROLE,
            _initialAdmin
        );
        AccessControl._grantRole(MANAGER_ROLE, _initialAdmin);

        i_bankCapInUSD = _bankCapInUSD;

        // V3 Configuration
        i_uniswapRouter = IUniswapV2Router02(_router);
        i_usdc = IERC20(_usdc);
        i_weth = IWETH(_weth);
    }

    /*///////////////////////////////////
     * Deposit Functions
     ///////////////////////////////////*/

    /// @notice Allows users to deposit native ETH, which will be converted to USDC.
    function depositETH() public payable {
        if (msg.value == 0) revert KipuBank_TransferFailed();
        _swapETHToUSDC(msg.value);
    }

    /**
     * @notice Allows users to deposit any ERC-20 token.
     * @dev If it is USDC, it is credited. If it is another token, it is swapped for USDC.
     * @param _token The address of the ERC-20 token to deposit.
     * @param _amount The amount of the token to deposit (in its native decimals).
     */
    function depositERC20(address _token, uint256 _amount) external {
        if (_token == ETH_TOKEN_ADDRESS) {
            revert KipuBank_UseDepositETHForNativeToken();
        }
        if (_amount == 0) revert KipuBank_TransferFailed();

        // 1. INTERACTION: Move tokens from the user to the contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // 2. DEPOSIT LOGIC
        if (_token == address(i_usdc)) {
            // If it's USDC, credit directly
            _creditUSDCBalance(msg.sender, _token, _amount, _amount);
        } else {
            // If it's another token, swap to USDC
            _swapTokenToUSDC(_token, _amount);
        }
    }

    /*///////////////////////////////////
     * Withdrawal Functions
     ///////////////////////////////////*/

    /**
     * @notice Allows users to withdraw their deposited assets.
     * @dev This function will only succeed if _token is USDC.
     * @param _token The token address to withdraw (will only work for USDC).
     * @param _amount The amount of the token to withdraw (in its native decimals).
     */
    function withdraw(address _token, uint256 _amount) external {
        // 1. Determine native decimals and convert the requested amount to the internal base (6 decimals)
        uint8 tokenDecimals = _token == ETH_TOKEN_ADDRESS
            ? 18
            : IERC20Metadata(_token).decimals();
        uint256 amountInInternalDecimals = _convertToInternalDecimals(
            _amount,
            tokenDecimals
        );

        // CHECKS: Verify sufficient internal balance
        // @dev This check will fail if a token != USDC is requested, as the balance will be 0.
        if (s_balances[msg.sender][_token] < amountInInternalDecimals) {
            revert KipuBank_InsufficientFunds(
                msg.sender,
                _token,
                s_balances[msg.sender][_token],
                amountInInternalDecimals
            );
        }

        // EFFECTS: Update internal accounting (CEI Pattern)
        s_balances[msg.sender][_token] -= amountInInternalDecimals;
        s_totalDepositedInUSD -= amountInInternalDecimals; // Reduce the total deposited

        // INTERACTION: Transfer the asset to the user (using the native amount)
        if (_token == ETH_TOKEN_ADDRESS) {
            // @dev This block is preserved, but will likely not be reached by a user
            // since their ETH balance will be 0.
            _transferEth(msg.sender, _amount);
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }

        emit WithdrawalMade(msg.sender, _token, _amount);
    }

    /*///////////////////////////////////
     * Administration Functions
     ///////////////////////////////////*/

    /**
     * @notice Allows a MANAGER to withdraw all funds from the bank treasury.
     * @dev Allows the manager to rescue USDC, ETH, or failed/stuck tokens.
     * @param _token The token address to withdraw (address(0) for ETH).
     */
    function managerWithdrawTreasury(address _token) external onlyManager {
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balance = address(this).balance;
            _transferEth(msg.sender, balance);
            emit TreasuryWithdrawal(msg.sender, _token, balance);
        } else {
            uint256 balance = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(msg.sender, balance);
            emit TreasuryWithdrawal(msg.sender, _token, balance);
        }
    }

    /*///////////////////////////////////
     * Internal & Private Functions
     ///////////////////////////////////*/

    /**
     * @notice Core internal logic for crediting USDC deposits.
     * @param _user The user receiving the credit.
     * @param _tokenIn The original token deposited (for the event).
     * @param _amountIn The original amount deposited (for the event).
     * @param _usdcAmount The amount of USDC (6 decimals) to credit.
     */
    function _creditUSDCBalance(
        address _user,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _usdcAmount
    ) private {
        // 1. CHECKS: Limit
        // The USD value is the USDC amount (both 6 decimals)
        uint256 usdValue = _usdcAmount;
        uint256 newTotalInUSD = s_totalDepositedInUSD + usdValue;

        // Check global cap
        if (newTotalInUSD > i_bankCapInUSD) {
            revert KipuBank_GlobalLimitExceeded(
                i_bankCapInUSD,
                s_totalDepositedInUSD,
                usdValue
            );
        }

        // 2. EFFECTS: Update state
        // Credit the user's USDC balance
        s_balances[_user][address(i_usdc)] += _usdcAmount;
        s_totalDepositedInUSD = newTotalInUSD;
        s_depositCount++;

        // 3. EMIT:
        emit DepositMade(
            _user,
            _tokenIn,
            address(i_usdc),
            _amountIn,
            usdValue
        );
    }

    /**
     * @notice Swaps native ETH for USDC using Uniswap V2.
     * @param _ethAmount The amount of ETH (wei) to swap.
     */
    function _swapETHToUSDC(uint256 _ethAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(i_weth);
        path[1] = address(i_usdc);

        // Executes the swap, sending the resulting USDC to this contract
        uint256[] memory amounts = i_uniswapRouter.swapExactETHForTokens{
            value: _ethAmount
        }(
            1, // amountOutMin: Minimum 1 wei of USDC to prevent failed swaps
            path,
            address(this),
            block.timestamp
        );

        uint256 usdcReceived = amounts[1];
        if (usdcReceived == 0) revert KipuBank_SwapFailed();

        // Credit the user's balance
        _creditUSDCBalance(
            msg.sender,
            ETH_TOKEN_ADDRESS,
            _ethAmount,
            usdcReceived
        );
    }

    /**
     * @notice Swaps an ERC20 token for USDC using Uniswap V2.
     * @param _token The token to swap.
     * @param _amount The amount of the token (native decimals) to swap.
     */
    function _swapTokenToUSDC(address _token, uint256 _amount) private {
        // 1. Approve the router to spend the token
        // We use forceApprove, the replacement for safeApprove in OpenZeppelin v5
        IERC20(_token).forceApprove(address(i_uniswapRouter), _amount);

        // 2. Prepare the path (Token -> USDC)
        address[] memory path = new address[](2);
        path[0] = _token;
        path[1] = address(i_usdc);

        // 3. Execute the swap
        uint256[] memory amounts = i_uniswapRouter.swapExactTokensForTokens(
            _amount,
            1, // amountOutMin: Minimum 1 wei of USDC
            path,
            address(this),
            block.timestamp
        );

        // 4. (Optional but good practice) Clear the approval
        IERC20(_token).forceApprove(address(i_uniswapRouter), 0);

        uint256 usdcReceived = amounts[1];
        if (usdcReceived == 0) revert KipuBank_SwapFailed();

        // 5. Credit the user's balance
        _creditUSDCBalance(msg.sender, _token, _amount, usdcReceived);
    }

    /*///////////////////////////////////
     * Internal & Private Functions
     ///////////////////////////////////*/

    /**
     * @notice Converts a token amount (in native decimals) to the internal base (6 decimals).
     * @dev Used by the `withdraw` function.
     */
    function _convertToInternalDecimals(
        uint256 _amount,
        uint8 _nativeDecimals
    ) internal pure returns (uint256) {
        uint8 internalDecimals = 6; // Internal accounting base

        if (_nativeDecimals == internalDecimals) {
            return _amount;
        } else if (_nativeDecimals < internalDecimals) {
            // Scale up
            return _amount * (10 ** (internalDecimals - _nativeDecimals));
        } else {
            // Scale down
            return _amount / (10 ** (_nativeDecimals - internalDecimals));
        }
    }

    /**
     * @notice Private function to securely transfer native ETH.
     * @dev Used by `withdraw` and `managerWithdrawTreasury`.
     */
    function _transferEth(address _recipient, uint256 _amount) private {
        (bool success, ) = _recipient.call{value: _amount}("");

        if (!success) {
            revert KipuBank_TransferFailed();
        }
    }

    /*////////////////////////
     * Receive & Fallback
     ////////////////////////*/
    /// @notice The `receive` function directs incoming ETH to the deposit logic.
    receive() external payable {
        depositETH();
    }
}