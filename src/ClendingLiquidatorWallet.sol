// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import "./SmartWallet.sol";

/// @notice Minimal EIP-3156 flash lender interface (Maker-style).
interface IERC3156FlashLender {
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);

    function maxFlashLoan(address token) external view returns (uint256);

    function flashFee(address token, uint256 amount) external view returns (uint256);
}

/// @notice Minimal EIP-3156 flash borrower interface.
interface IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}

/// @notice Minimal Uniswap V2 pair interface for CORE/DAI swaps.
interface IUniswapV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
}

/// @notice Interface for the Clending protocol at 0x54B276C8a484eBF2a244D933AF5FFaf595ea58c5.
/// @dev This is derived directly from `clendingabi.json` and intentionally kept minimal
///      to the functions used by this wallet.
interface IClending {
    function DAI() external view returns (IERC20);

    function CORE_TOKEN() external view returns (IERC20);

    function coreDAO() external view returns (IERC20);

    function repayLoan(IERC20 token, uint256 amount) external;

    function reclaimAllCollateral() external;

    /// @notice Returns the total DAI-denominated debt for a given user.
    /// @dev Matches the signature from `clendingabi.json`.
    function userTotalDebt(address user) external view returns (uint256);
}

/// @title ClendingLiquidatorWallet
/// @notice EIP-7702-compatible wallet that can flash-mint DAI, repay a Clending loan,
///         reclaim collateral (COREDAO + CORE_TOKEN), and sell CORE_TOKEN into a
///         Uniswap V2 CORE/DAI pool to obtain DAI for loan repayment.
/// @dev This contract is designed to be used as the implementation for a 7702 authorization,
///      similar to `SmartWallet` in this repository.
contract ClendingLiquidatorWallet is SmartWallet, IERC3156FlashBorrower {
    /// @notice Flash lender (Maker-style DAI lender).
    IERC3156FlashLender public immutable daiLender;

    /// @notice Clending protocol instance.
    IClending public immutable clending;

    /// @notice Uniswap V2 pair used to convert CORE_TOKEN to WETH.
    IUniswapV2Pair public immutable coreWethPair;

    /// @notice Uniswap V2 pair used to convert WETH to DAI.
    IUniswapV2Pair public immutable daiWethPair;

    /// @notice Magic return value required by EIP-3156.
    bytes32 public constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(
        address _daiLender,
        address _clending,
        address _coreWethPair,
        address _daiWethPair
    ) {
        require(_daiLender != address(0), "Invalid DAI lender");
        require(_clending != address(0), "Invalid Clending");
        require(_coreWethPair != address(0), "Invalid CORE/WETH pair");
        require(_daiWethPair != address(0), "Invalid DAI/WETH pair");

        daiLender = IERC3156FlashLender(_daiLender);
        clending = IClending(_clending);
        coreWethPair = IUniswapV2Pair(_coreWethPair);
        daiWethPair = IUniswapV2Pair(_daiWethPair);
    }

    /// -----------------------------------------------------------------------
    /// Owner entrypoint to start the flash-mint liquidation sequence
    /// -----------------------------------------------------------------------

    /// @notice Initiate a flash loan from the DAI lender to repay this wallet's
    ///         debt on Clending and reclaim its collateral.
    /// @param daiAmountToBorrow Amount of DAI to flash-mint/borrow.
    /// @param minProfitDai      Minimum DAI profit (beyond principal+fee) expected.
    function flashRepayAndReclaim(uint256 daiAmountToBorrow, uint256 minProfitDai) external onlyOwner {
        IERC20 daiToken = clending.DAI();

        uint256 maxLoan = daiLender.maxFlashLoan(address(daiToken));
        require(daiAmountToBorrow <= maxLoan, "Requested flash loan too large");

        // Encode all data needed in the callback.
        bytes memory data = abi.encode(
            msg.sender, // initiatorOwner
            daiAmountToBorrow,
            minProfitDai
        );

        bool ok = daiLender.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(daiToken),
            daiAmountToBorrow,
            data
        );
        require(ok, "flashLoan failed");
    }

    /// -----------------------------------------------------------------------
    /// IERC3156FlashBorrower callback
    /// -----------------------------------------------------------------------

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // Only the configured DAI lender can call this.
        require(msg.sender == address(daiLender), "Unauthorized lender");
        IERC20 daiToken = clending.DAI();
        require(token == address(daiToken), "Unsupported token");

        // Decode callback data
        (address initiatorOwner, uint256 daiAmountToBorrow, uint256 minProfitDai) =
            abi.decode(data, (address, uint256, uint256));

        // Basic consistency checks: these do not guarantee profitability but
        // they ensure the loan terms didn't change unexpectedly.
        require(initiatorOwner == initiator || initiator == address(this), "Unexpected initiator");
        require(daiAmountToBorrow == amount, "Amount mismatch");

        // --------------------------------------------------------------------
        // 1. Repay loan on Clending using flash-minted DAI
        // --------------------------------------------------------------------
        daiToken.approve(address(clending), amount);
        clending.repayLoan(daiToken, amount);

        // --------------------------------------------------------------------
        // 2. Reclaim collateral (COREDAO + CORE_TOKEN)
        // --------------------------------------------------------------------
        clending.reclaimAllCollateral();

        IERC20 coreToken = clending.CORE_TOKEN();

        uint256 coreTokenBalance = coreToken.balanceOf(address(this));

        // --------------------------------------------------------------------
        // 3. Sell CORE_TOKEN into Uniswap V2 pools CORE/WETH and WETH/DAI
        // --------------------------------------------------------------------
        if (coreTokenBalance > 0) {
            _swapCoreForDai(coreToken, daiToken, coreTokenBalance);
        }

        // --------------------------------------------------------------------
        // 4. Repay flash loan + fee and optionally forward profit to owner
        // --------------------------------------------------------------------
        uint256 daiBalanceNow = daiToken.balanceOf(address(this));
        // Ensure we meet the minimum profit requirement as well.
        require(
            daiBalanceNow >= amount + fee + minProfitDai,
            "Insufficient DAI including profit"
        );

        daiToken.approve(address(daiLender), amount + fee);

        uint256 profit = daiBalanceNow - (amount + fee);
        if (profit > 0) {
            daiToken.transfer(owner, profit);
        }

        return CALLBACK_SUCCESS;
    }

    /// @dev Internal helper to swap CORE_TOKEN for DAI using CORE/WETH and WETH/DAI pools.
    function _swapCoreForDai(
        IERC20 coreToken,
        IERC20 daiToken,
        uint256 coreTokenBalance
    ) internal {
        uint256 wethAmount = _swapCoreForWeth(coreToken, coreTokenBalance);
        if (wethAmount > 0) {
            _swapWethForDai(daiToken, wethAmount);
        }
    }

    /// @dev Swap CORE_TOKEN for WETH via the CORE/WETH pair.
    function _swapCoreForWeth(
        IERC20 coreToken,
        uint256 coreTokenBalance
    ) internal returns (uint256 wethOut) {
        IUniswapV2Pair pair = coreWethPair;

        address token0 = pair.token0();
        address token1 = pair.token1();

        require(
            token0 == address(coreToken) || token1 == address(coreToken),
            "CORE/WETH pair mismatch"
        );

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        bool coreIsToken0 = token0 == address(coreToken);

        if (coreIsToken0) {
            reserveIn = reserve0;
            reserveOut = reserve1;
        } else {
            reserveIn = reserve1;
            reserveOut = reserve0;
        }

        require(reserveIn > 0 && reserveOut > 0, "Empty CORE/WETH reserves");

        uint256 amountInWithFee = coreTokenBalance * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        wethOut = numerator / denominator;
        require(wethOut > 0, "Insufficient WETH out");

        coreToken.transfer(address(pair), coreTokenBalance);

        if (coreIsToken0) {
            pair.swap(0, wethOut, address(this), new bytes(0));
        } else {
            pair.swap(wethOut, 0, address(this), new bytes(0));
        }
    }

    /// @dev Swap WETH for DAI via the WETH/DAI pair.
    function _swapWethForDai(
        IERC20 daiToken,
        uint256 wethAmount
    ) internal returns (uint256 daiOut) {
        IUniswapV2Pair pair = daiWethPair;

        address token0 = pair.token0();
        address token1 = pair.token1();

        // Determine which token is WETH by exclusion (the other is DAI).
        require(
            token0 == address(daiToken) || token1 == address(daiToken),
            "DAI/WETH pair mismatch"
        );

        address wethAddress = token0 == address(daiToken) ? token1 : token0;
        IERC20 weth = IERC20(wethAddress);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        bool wethIsToken0 = token0 == wethAddress;

        if (wethIsToken0) {
            reserveIn = reserve0;
            reserveOut = reserve1;
        } else {
            reserveIn = reserve1;
            reserveOut = reserve0;
        }

        require(reserveIn > 0 && reserveOut > 0, "Empty DAI/WETH reserves");

        uint256 amountInWithFee = wethAmount * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        daiOut = numerator / denominator;
        require(daiOut > 0, "Insufficient DAI out");

        weth.transfer(address(pair), wethAmount);

        if (wethIsToken0) {
            pair.swap(0, daiOut, address(this), new bytes(0));
        } else {
            pair.swap(daiOut, 0, address(this), new bytes(0));
        }
    }
}


