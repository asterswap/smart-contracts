// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPancakeRouter02 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function getAmountsOut(uint amountIn, address[] calldata path)
        external view returns (uint[] memory amounts);

    function WETH() external pure returns (address);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract AsterswapCOM {
    // ─── State ───────────────────────────────────
    address public owner;
    address public feeRecipient;
    uint256 public feeRate;       // basis points (50 = 0.5%, max 500 = 5%)
    uint256 public referrerRate;  // basis points out of 10000, portion of fee going to referrer
                                  // e.g. 3000 = referrer gets 30% of the platform fee

    IPancakeRouter02 public immutable router;
    address public immutable WBNB;

    bool private _locked;

    // ─── Referral tracking ───────────────────────
    // Stores cumulative input amount (in native token units) routed via each referrer
    mapping(address => uint256) public referralVolume;

    // ─── Anonymous referral code registry ────────
    // Users register a random bytes32 code once. Links show the code, not the address.
    mapping(bytes32 => address) public codeToAddress;
    mapping(address => bytes32) public addressToCode;

    // ─── Events ──────────────────────────────────
    event SwapBuy(address indexed user, uint256 bnbIn, uint256 fee, uint256 tokensOut);
    event SwapSell(address indexed user, uint256 tokensIn, uint256 bnbOut, uint256 fee);
    event SwapTokenToToken(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 fee);
    event FeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);
    event ReferrerRateUpdated(uint256 newRate);
    event ReferralPaid(address indexed referrer, address indexed user, uint256 amount, address token);
    event ReferralCodeRegistered(address indexed user, bytes32 indexed code);
    event OwnershipTransferred(address indexed prev, address indexed next);

    // ─── Modifiers ───────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrancy");
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ─────────────────────────────
    constructor(address _router, address _feeRecipient, uint256 _feeRate) {
        require(_feeRate <= 500, "Fee max 5%");
        require(_feeRecipient != address(0), "Invalid recipient");

        owner = msg.sender;
        router = IPancakeRouter02(_router);
        WBNB = router.WETH();
        feeRecipient = _feeRecipient;
        feeRate = _feeRate;
        referrerRate = 3000; // 30% of platform fee goes to referrer by default
    }

    // ─── Internal: split and dispatch a BNB fee ──
    /**
     * @dev Splits `fee` BNB between feeRecipient and referrer.
     *      If referrer is address(0) or referrer == user, full fee goes to feeRecipient.
     * @param fee      Total fee amount in BNB (wei)
     * @param referrer Address of the referrer (can be address(0))
     * @param user     The swapping user (used for anti-self-referral check)
     */
    function _dispatchBNBFee(uint256 fee, address referrer, address user) internal {
        if (fee == 0) return;

        bool hasReferrer = referrer != address(0) && referrer != user;
        if (hasReferrer) {
            uint256 referrerShare = (fee * referrerRate) / 10000;
            uint256 protocolShare = fee - referrerShare;

            if (protocolShare > 0) {
                (bool feeOk, ) = feeRecipient.call{value: protocolShare}("");
                require(feeOk, "Fee transfer failed");
            }
            if (referrerShare > 0) {
                (bool refOk, ) = referrer.call{value: referrerShare}("");
                require(refOk, "Referral transfer failed");
                emit ReferralPaid(referrer, user, referrerShare, address(0));
            }
        } else {
            (bool feeOk, ) = feeRecipient.call{value: fee}("");
            require(feeOk, "Fee transfer failed");
        }
    }

    // ─── Internal: split and dispatch a token fee ─
    /**
     * @dev Splits `fee` token amount between feeRecipient and referrer.
     * @param token    ERC20 token address
     * @param fee      Total fee in token units
     * @param referrer Address of the referrer (can be address(0))
     * @param user     The swapping user (used for anti-self-referral check)
     */
    function _dispatchTokenFee(address token, uint256 fee, address referrer, address user) internal {
        if (fee == 0) return;

        bool hasReferrer = referrer != address(0) && referrer != user;
        if (hasReferrer) {
            uint256 referrerShare = (fee * referrerRate) / 10000;
            uint256 protocolShare = fee - referrerShare;

            if (protocolShare > 0) {
                bool feeOk = IERC20(token).transfer(feeRecipient, protocolShare);
                require(feeOk, "Fee transfer failed");
            }
            if (referrerShare > 0) {
                bool refOk = IERC20(token).transfer(referrer, referrerShare);
                require(refOk, "Referral transfer failed");
                emit ReferralPaid(referrer, user, referrerShare, token);
            }
        } else {
            bool feeOk = IERC20(token).transfer(feeRecipient, fee);
            require(feeOk, "Fee transfer failed");
        }
    }

    // ══════════════════════════════════════════════
    // ║  BUY: BNB → Token                         ║
    // ══════════════════════════════════════════════
    /**
     * @notice Swap BNB for tokens. Fee is deducted from BNB before the swap.
     * @param tokenOut      The token to receive (e.g. ASTER)
     * @param amountOutMin  Minimum tokens to receive (slippage protection)
     * @param deadline      Unix timestamp deadline
     * @param referrer      Referrer wallet address — pass address(0) if none
     */
    function swapBNBForTokens(
        address tokenOut,
        uint256 amountOutMin,
        uint256 deadline,
        address referrer
    ) external payable nonReentrant {
        require(msg.value > 0, "No BNB sent");

        // Calculate fee and swap amount
        uint256 fee = (msg.value * feeRate) / 10000;
        uint256 swapAmount = msg.value - fee;

        // Dispatch fee (split between protocol and referrer)
        _dispatchBNBFee(fee, referrer, msg.sender);

        // Track referral volume
        if (referrer != address(0) && referrer != msg.sender) {
            referralVolume[referrer] += msg.value;
        }

        // Build path: WBNB → Token
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = tokenOut;

        // Execute swap — tokens go directly to user
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmount}(
            amountOutMin,
            path,
            msg.sender,
            deadline
        );

        emit SwapBuy(msg.sender, msg.value, fee, amountOutMin);
    }

    // ══════════════════════════════════════════════
    // ║  SELL: Token → BNB                         ║
    // ══════════════════════════════════════════════
    /**
     * @notice Swap tokens for BNB. Fee is deducted from BNB output after the swap.
     * @dev User must approve this contract first.
     * @param tokenIn       The token to sell (e.g. ASTER)
     * @param amountIn      Amount of tokens to sell
     * @param amountOutMin  Minimum BNB to receive after fee (slippage protection)
     * @param deadline      Unix timestamp deadline
     * @param referrer      Referrer wallet address — pass address(0) if none
     */
    function swapTokensForBNB(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address referrer
    ) external nonReentrant {
        require(amountIn > 0, "No tokens sent");

        // Transfer tokens from user (handles fee-on-transfer tokens)
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 actualAmount = IERC20(tokenIn).balanceOf(address(this)) - balBefore;
        require(actualAmount > 0, "Zero tokens received");

        // Approve router to spend tokens
        IERC20(tokenIn).approve(address(router), actualAmount);

        // Build path: Token → WBNB
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = WBNB;

        // Swap — BNB comes to this contract first (so we can take fee)
        uint256 bnbBefore = address(this).balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            actualAmount,
            0, // check after fee
            path,
            address(this),
            deadline
        );
        uint256 bnbReceived = address(this).balance - bnbBefore;

        // Take fee from BNB output
        uint256 fee = (bnbReceived * feeRate) / 10000;
        uint256 userAmount = bnbReceived - fee;
        require(userAmount >= amountOutMin, "Slippage exceeded");

        // Dispatch fee (split between protocol and referrer)
        _dispatchBNBFee(fee, referrer, msg.sender);

        // Track referral volume
        if (referrer != address(0) && referrer != msg.sender) {
            referralVolume[referrer] += bnbReceived;
        }

        // Send BNB to user
        (bool ok, ) = msg.sender.call{value: userAmount}("");
        require(ok, "BNB transfer failed");

        emit SwapSell(msg.sender, amountIn, userAmount, fee);
    }

    // ══════════════════════════════════════════════
    // ║  TOKEN TO TOKEN (e.g. USDT → ASTER)        ║
    // ══════════════════════════════════════════════
    /**
     * @notice Swap tokens for tokens (e.g., USDT to ASTER). Fee is deducted from input token.
     * @dev User must approve this contract to spend `tokenIn` first.
     * @param tokenIn       The token to sell (e.g., USDT)
     * @param tokenOut      The token to buy (e.g., ASTER)
     * @param amountIn      Amount of tokens to sell
     * @param amountOutMin  Minimum tokens to receive (slippage protection)
     * @param deadline      Unix timestamp deadline
     * @param referrer      Referrer wallet address — pass address(0) if none
     */
    function swapTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address referrer
    ) external nonReentrant {
        require(amountIn > 0, "No tokens sent");

        // Transfer tokens from user to contract
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 actualAmountIn = IERC20(tokenIn).balanceOf(address(this)) - balBefore;
        require(actualAmountIn > 0, "Zero tokens received");

        // Calculate fee in tokenIn
        uint256 fee = (actualAmountIn * feeRate) / 10000;
        uint256 swapAmount = actualAmountIn - fee;

        // Dispatch token fee (split between protocol and referrer)
        _dispatchTokenFee(tokenIn, fee, referrer, msg.sender);

        // Track referral volume (denominated in tokenIn units)
        if (referrer != address(0) && referrer != msg.sender) {
            referralVolume[referrer] += actualAmountIn;
        }

        // Approve router to spend tokens
        IERC20(tokenIn).approve(address(router), swapAmount);

        // Build path: TokenIn → WBNB → TokenOut
        address[] memory path;
        if (tokenIn == WBNB || tokenOut == WBNB) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = WBNB;
            path[2] = tokenOut;
        }

        // Execute swap — tokens go directly to user
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            swapAmount,
            amountOutMin,
            path,
            msg.sender,
            deadline
        );

        emit SwapTokenToToken(msg.sender, tokenIn, tokenOut, amountIn, fee);
    }

    // ══════════════════════════════════════════════
    // ║  QUOTES (read-only)                        ║
    // ══════════════════════════════════════════════

    /// @notice Get estimated tokens out for a BNB buy (after fee)
    function quoteBuy(uint256 bnbAmount, address tokenOut) external view returns (uint256) {
        uint256 swapAmount = bnbAmount - (bnbAmount * feeRate) / 10000;
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = tokenOut;
        uint256[] memory amounts = router.getAmountsOut(swapAmount, path);
        return amounts[1];
    }

    /// @notice Get estimated BNB out for a token sell (after fee)
    function quoteSell(uint256 tokenAmount, address tokenIn) external view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = WBNB;
        uint256[] memory amounts = router.getAmountsOut(tokenAmount, path);
        uint256 bnbOut = amounts[1];
        return bnbOut - (bnbOut * feeRate) / 10000;
    }

    /// @notice Get estimated TokenOut for TokenIn (Token to Token swap, after fee)
    function quoteTokenToToken(uint256 amountIn, address tokenIn, address tokenOut) external view returns (uint256) {
        uint256 swapAmount = amountIn - (amountIn * feeRate) / 10000;
        address[] memory path;
        
        if (tokenIn == WBNB || tokenOut == WBNB) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            // Route through WBNB
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = WBNB;
            path[2] = tokenOut;
        }

        uint256[] memory amounts = router.getAmountsOut(swapAmount, path);
        return amounts[path.length - 1];
    }

    // ══════════════════════════════════════════════
    // ║  ADMIN                                     ║
    // ══════════════════════════════════════════════

    // ══════════════════════════════════════════════
    // ║  REFERRAL CODE REGISTRY                    ║
    // ══════════════════════════════════════════════

    /**
     * @notice Register an anonymous referral code bound to msg.sender.
     *         The code must be a random bytes32 generated client-side.
     *         Calling again replaces the previous code (old code is freed).
     * @param code  Random bytes32 — frontend uses first 8 bytes as URL shortcode
     */
    function registerReferralCode(bytes32 code) external {
        require(code != bytes32(0), "Invalid code");
        require(codeToAddress[code] == address(0), "Code already taken");
        // Free old code if any
        bytes32 oldCode = addressToCode[msg.sender];
        if (oldCode != bytes32(0)) {
            delete codeToAddress[oldCode];
        }
        codeToAddress[code] = msg.sender;
        addressToCode[msg.sender] = code;
        emit ReferralCodeRegistered(msg.sender, code);
    }

    // ══════════════════════════════════════════════
    // ║  ADMIN                                     ║
    // ══════════════════════════════════════════════

    function setFeeRate(uint256 _newFee) external onlyOwner {
        require(_newFee <= 500, "Fee max 5%");
        feeRate = _newFee;
        emit FeeUpdated(_newFee);
    }

    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        feeRecipient = _newRecipient;
        emit FeeRecipientUpdated(_newRecipient);
    }

    /**
     * @notice Update the portion of the platform fee going to referrers.
     * @param _newRate Basis points out of 10000 (e.g. 3000 = 30% of fee to referrer)
     *                 Max 5000 (50% of fee) to always keep majority for protocol.
     */
    function setReferrerRate(uint256 _newRate) external onlyOwner {
        require(_newRate <= 5000, "Referrer rate max 50%");
        referrerRate = _newRate;
        emit ReferrerRateUpdated(_newRate);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Withdraw stuck BNB (emergency only)
    function emergencyWithdrawBNB() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        require(ok, "Withdraw failed");
    }

    /// @notice Withdraw stuck tokens (emergency only)
    function emergencyWithdrawToken(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "No balance");
        IERC20(token).transfer(owner, bal);
    }

    receive() external payable {}
}
