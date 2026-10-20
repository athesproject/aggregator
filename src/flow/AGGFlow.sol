// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;


/**
 * @title  AGGFlowRouter
 * @notice Gas‑lean byte‑code DEX aggregator for Ethereum (eth + Weth) that can compose
 *         Uniswap‑V2 pools, Uniswap‑V3 pools (incl. Pancake V3), Curve pools,
 *         LiquidityBook (TraderJoe), PalindromeFi, native wrap/unwrap, and 
 *         any‑to‑any multi‑leg AGG/Crystal markets – all in one atomic transaction.
 *
 *         ➤ Invariant: router finishes with zero token balances (all residuals
 *           are swept back to the user).
 *
 *         ➤ Byte‑code route program op‑codes:
 *             0x01  PROCESS_ROUTER_ERC20 – use router's existing balance of a token, then distribute & swap.
 *             0x02  PROCESS_USER_ERC20   – on first encounter, pull `amountIn` of tokenIn from user, then distribute & swap.
 *             0x03  PROCESS_NATIVE       – use msg.value (ETH) as source, then distribute & swap.
 *             0x04  PROCESS_ONE_POOL     – single pool optimization; skip distribution, directly swap with amount=0 (uses pool balance delta).
 *             0x05  APPLY_PERMIT         – ERC‑2612 permit for upfront pull.
 *
 *         ➤ All swaps route output to address(this) (the router). Final balance is sent to msg.sender.
 */

// ────────────────────────────────────────────────────────────────────────────────
// ░░░  Libraries & Interfaces  ░░░
// ────────────────────────────────────────────────────────────────────────────────

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { AGGFlowErrors } from "./AGGFlowErrors.sol";

// Minimal interfaces we need ----------------------------------------------------

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    // added for single-pool optimisation
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    )
        external
        returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IWEth {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IOrderBook {
    function placeAndExecuteMarketBuy(
        uint96 quoteAmount,
        uint256 minAmountOut,
        bool isMargin,
        bool isFillOrKill
    )
        external
        payable
        returns (uint256 amountOut);

    function placeAndExecuteMarketSell(
        uint96 size,
        uint256 minAmountOut,
        bool isMargin,
        bool isFillOrKill
    )
        external
        payable
        returns (uint256 amountOut);
}

interface ICrystal {
    function marketOrder(
        bool isBuy,
        bool isExactInput,
        bool isFromCaller,
        bool isToCaller,
        uint256 orderType,
        uint256 size,
        uint256 worstPrice,
        address caller,
        address referrer
    )
        external
        returns (uint256 amountIn, uint256 amountOut, uint256 id);
}

interface ICurveStableSwap {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

interface ICurveCrypto {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

interface ICurveLegacy {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable;
}

interface IPalindromeFi {
    function quoteAndSwap(
        bool tokenInIsBase,
        uint256 amountIn,
        uint256 minOut,
        address to
    )
        external
        returns (uint256 amountOut);
}

interface ILBPair {
    function swap(bool swapForY, address to) external returns (bytes32 amountsOut);
}

// ───────────────────────────── Libraries ───────────────────────────────────────

library Approve {
    function _call(IERC20 token, bytes4 sel, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(sel, spender, amount));
        return ok && (data.length == 0 || abi.decode(data, (bool)));
    }

    function approveMax(IERC20 token, address spender, uint256 amount) internal {
        if (!_call(token, token.approve.selector, spender, amount)) {
            // Some tokens (e.g. USDT) require setting to 0 first
            require(_call(token, token.approve.selector, spender, 0), AGGFlowErrors.ApproveResetFailed());
            require(_call(token, token.approve.selector, spender, amount), AGGFlowErrors.ApproveFailed());
        }
    }
}

/**
 * @dev In‑memory stream reader identical to LiFi’s but trimmed to used ops only.
 */
/**
 * @notice Simple read stream
 */
library InputStream {
    /**
     * @notice Creates stream from data
     * @param data data
     */
    function create(bytes memory data) internal pure returns (uint256 stream) {
        assembly {
            stream := mload(0x40)
            mstore(0x40, add(stream, 64))
            mstore(stream, data)
            let length := mload(data)
            mstore(add(stream, 32), add(data, length))
        }
    }

    /**
     * @notice Checks if stream is not empty
     * @param stream stream
     */
    function isNotEmpty(uint256 stream) internal pure returns (bool) {
        uint256 pos;
        uint256 finish;
        assembly {
            pos := mload(stream)
            finish := mload(add(stream, 32))
        }
        return pos < finish;
    }

    /**
     * @notice Reads uint8 from the stream
     * @param stream stream
     */
    function readUint8(uint256 stream) internal pure returns (uint8 res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 1)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads uint16 from the stream
     * @param stream stream
     */
    function readUint16(uint256 stream) internal pure returns (uint16 res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 2)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads uint24 from the stream
     * @param stream stream
     */
    function readUint24(uint256 stream) internal pure returns (uint24 res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 3)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads uint32 from the stream
     * @param stream stream
     */
    function readUint32(uint256 stream) internal pure returns (uint32 res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 4)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads uint256 from the stream
     * @param stream stream
     */
    function readUint(uint256 stream) internal pure returns (uint256 res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 32)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads bytes32 from the stream
     * @param stream stream
     */
    function readBytes32(uint256 stream) internal pure returns (bytes32 res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 32)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads address from the stream
     * @param stream stream
     */
    function readAddress(uint256 stream) internal pure returns (address res) {
        assembly {
            let pos := mload(stream)
            pos := add(pos, 20)
            res := mload(pos)
            mstore(stream, pos)
        }
    }

    /**
     * @notice Reads bytes from the stream
     * @param stream stream
     */
    function readBytes(uint256 stream) internal pure returns (bytes memory res) {
        assembly {
            let pos := mload(stream)
            res := add(pos, 32)
            let length := mload(res)
            mstore(stream, add(res, length))
        }
    }
}

// ───────────────────────────── Router Contract ────────────────────────────────

contract AGGFlowRouter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Approve for IERC20;

    // Sentinel addresses --------------------------------------------------------
    address internal constant NATIVE = address(0); // ETH (native)
    address internal constant IMPOSSIBLE = address(1);
    address internal constant INTERNAL_SRC = address(2);

    // Uniswap‑V2 direction constants
    uint8 private constant DIRECTION_TOKEN0_TO_TOKEN1 = 0;
    uint8 private constant UNIV2_DIR_TOKEN1_TO_TOKEN0 = 1;

    // Uniswap‑V3 tick limit constants
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739 + 1;
    uint160 private constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341 - 1;

    // Immutable WETH address (passed in constructor)
    address public immutable WETH;

    constructor(address _weth) {
        WETH = _weth;
    }

    // ───────────────────────── Entry Point ─────────────────────────────────────

    event Route(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    function executeRoute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        bytes memory program
    )
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        uint256 ptr = InputStream.create(program);
        uint256 runAmt;
        address currentToken = tokenIn;

        bool pulled = false; // ensures we pull from user only once

        while (InputStream.isNotEmpty(ptr)) {
            uint8 op = InputStream.readUint8(ptr);
            if (op == 0) break;

            if (op == 0x01) {
                // @note erc20 token is already in router for this case
                // PROCESS_ROUTER_ERC20 ------------------------------------------------
                currentToken = InputStream.readAddress(ptr);
                runAmt = _bal(currentToken, address(this));
                require(runAmt > 0, AGGFlowErrors.ZeroRouterBalance());
                _distributeAndSwap(ptr, currentToken, runAmt);
            } else if (op == 0x02) {
                // @note token pull mechanism (first token only)
                // PROCESS_USER_ERC20 ---------------------------------------------
                address declared = InputStream.readAddress(ptr);
                require(declared == currentToken, AGGFlowErrors.TokenMismatch());
                if (!pulled) {
                    if (currentToken == NATIVE) {
                        require(msg.value == amountIn, AGGFlowErrors.InsufficientNativeBalance());
                    } else {
                        IERC20(currentToken).safeTransferFrom(msg.sender, address(this), amountIn);
                    }
                    pulled = true;
                    runAmt = amountIn;
                }

                _distributeAndSwap(ptr, declared, runAmt);
            } else if (op == 0x03) {
                // @note native token is already in router for this case
                // PROCESS_NATIVE -------------------------------------------------
                runAmt = address(this).balance; // includes msg.value
                _distributeAndSwap(ptr, NATIVE, runAmt);
            } else if (op == 0x04) {
                // @note no distribution optimization
                // PROCESS_ONE_POOL ----------------------------------------------
                address tkn = InputStream.readAddress(ptr);
                _swap(ptr, tkn, 0); // INTERNAL_SRC sentinel inside swaps
            } else if (op == 0x05) {
                // @note permit before pull (first token only)
                _applyPermit(ptr);
            } else {
                revert AGGFlowErrors.InvalidOpCode();
            }
        }

        amountOut = _bal(tokenOut, address(this));
        require(amountOut >= minAmountOut, AGGFlowErrors.SlippageExceeded());
        _send(tokenOut, msg.sender, amountOut);

        emit Route(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ─────────────────────────── Helpers ───────────────────────────────────────

    function _bal(address token, address who) private view returns (uint256) {
        return token == NATIVE ? who.balance : IERC20(token).balanceOf(who);
    }

    function _send(address token, address to, uint256 amt) private {
        if (token == NATIVE) {
            (bool ok,) = to.call{ value: amt }("");
            require(ok, AGGFlowErrors.NativeSendFailed());
        } else {
            IERC20(token).safeTransfer(to, amt);
        }
    }

    // ───────────────────── ERC‑2612 permit  (opcode 0x06) ─────────────────────

    function _applyPermit(uint256 ptr) private {
        address token = InputStream.readAddress(ptr);
        uint256 value = InputStream.readUint(ptr);
        uint256 deadline = InputStream.readUint(ptr);
        uint8 v = InputStream.readUint8(ptr);
        bytes32 r = bytes32(InputStream.readUint(ptr));
        bytes32 s = bytes32(InputStream.readUint(ptr));
        IERC20Permit(token).permit(msg.sender, address(this), value, deadline, v, r, s);
    }

    // ────────────────────── Distribution Block ────────────────────────────────

    function _distributeAndSwap(uint256 ptr, address tokenIn, uint256 amountTotal) private {
        uint256 amountRemaining = amountTotal;
        uint8 num = InputStream.readUint8(ptr);
        for (uint256 i; i < num;) {
            uint16 share = InputStream.readUint16(ptr);
            uint256 amt = (amountTotal * share) / 65_535;
            if (i == num - 1) {
                amt = amountRemaining;
            }
            amountRemaining -= amt;
            _swap(ptr, tokenIn, amt);
            unchecked {
                ++i;
            }
        }
    }

    // ─────────────────────────── Swaps ─────────────────────────────────────────

    uint8 private constant PT_UNIV2 = 0;
    uint8 private constant PT_UNIV3 = 1;
    uint8 private constant PT_WRAP = 2;
    uint8 private constant PT_AGG = 3;
    uint8 private constant PT_CRYSTAL = 4;
    uint8 private constant PT_CURVE = 5;
    uint8 private constant PT_PALINDROME_FI = 6;
    uint8 private constant PT_LIQUIDITY_BOOK = 7;

    function _swap(uint256 ptr, address tokenIn, uint256 amountIn) private {
        uint8 pType = InputStream.readUint8(ptr);
        if (pType == PT_UNIV2) {
            _swapUniV2(ptr, tokenIn, amountIn);
        } else if (pType == PT_UNIV3) {
            _swapUniV3(ptr, tokenIn, amountIn);
        } else if (pType == PT_WRAP) {
            _wrapNative(ptr, tokenIn, amountIn);
        } else if (pType == PT_AGG) {
            _swapAGG(ptr, tokenIn, amountIn);
        } else if (pType == PT_CRYSTAL) {
            _swapCrystal(ptr, tokenIn, amountIn);
        } else if (pType == PT_CURVE) {
            _swapCurve(ptr, tokenIn, amountIn);
        } else if (pType == PT_PALINDROME_FI) {
            _swapPalindromeFi(ptr, tokenIn, amountIn);
        } else if (pType == PT_LIQUIDITY_BOOK) {
            _swapLiquidityBook(ptr, tokenIn, amountIn);
        } else {
            revert AGGFlowErrors.InvalidPoolType();
        }
    }

    // ───── Litvmswap v3 style ----------------------------------------------------
    function _swapUniV2(uint256 ptr, address tokenIn, uint256 amountIn) private {
        address pool = InputStream.readAddress(ptr);
        uint8 dir = InputStream.readUint8(ptr);
        uint24 fee = InputStream.readUint24(ptr);

        // determine effective input when router pre-loaded pool (single-pool optimisation)
        if (amountIn == 0) {
            // token already in pool – compute delta balance
            address actualToken = dir == 1 ? IUniswapV2Pair(pool).token1() : IUniswapV2Pair(pool).token0();
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pool).getReserves();
            uint256 reserveIn = dir == 1 ? r1 : r0;
            uint256 balanceIn = IERC20(actualToken).balanceOf(pool);
            amountIn = balanceIn - reserveIn;
            tokenIn = actualToken;
        } else {
            // regular path – push tokens to pool first
            IERC20(tokenIn).safeTransfer(pool, amountIn);
        }

        // fetch reserves AFTER any transfer above to avoid stale view
        (uint112 res0, uint112 res1,) = IUniswapV2Pair(pool).getReserves();
        (uint256 reserveIn2, uint256 reserveOut) = dir == DIRECTION_TOKEN0_TO_TOKEN1 ? (res0, res1) : (res1, res0);
        uint256 realIn = IERC20(tokenIn).balanceOf(pool) - reserveIn2;
        uint256 amtInWithFee = realIn * (1_000_000 - fee);
        uint256 amtOut = (amtInWithFee * reserveOut) / (reserveIn2 * 1_000_000 + amtInWithFee);
        (uint256 amt0Out, uint256 amt1Out) =
            dir == DIRECTION_TOKEN0_TO_TOKEN1 ? (uint256(0), amtOut) : (amtOut, uint256(0));

        IUniswapV2Pair(pool).swap(amt0Out, amt1Out, address(this), "");
    }

    // ───── Uniswap V3 style ----------------------------------------------------
    address private lastPool = IMPOSSIBLE;
    address private lastTokenIn = IMPOSSIBLE;

    function _swapUniV3(uint256 ptr, address tokenIn, uint256 amountIn) private {
        if (amountIn > uint256(type(int256).max)) revert AGGFlowErrors.Int256Overflow();
        address pool = InputStream.readAddress(ptr);
        bool dir = InputStream.readUint8(ptr) != 0;

        lastPool = pool;
        lastTokenIn = tokenIn;
        IUniswapV3Pool(pool).swap(
            address(this), dir, int256(amountIn), dir ? MIN_SQRT_RATIO : MAX_SQRT_RATIO, ""
        );
        require(lastPool == IMPOSSIBLE, AGGFlowErrors.UniV3CallbackMissed());
    }

    // UniV3 callback -----------------------------------------------------------
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata /* data */) public {
        require(msg.sender == lastPool, AGGFlowErrors.UniV3CallbackInvalidSource());
        int256 amt = a0 > 0 ? a0 : a1;
        require(amt > 0, AGGFlowErrors.UniV3CallbackNegativeAmount());
        
        address tokenIn = lastTokenIn;
        lastPool = IMPOSSIBLE;
        lastTokenIn = IMPOSSIBLE;
        
        IERC20(tokenIn).safeTransfer(msg.sender, uint256(amt));
    }

    // ───── Pancake V3 callback ------------------------------------------------
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function zfV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function capricornCLSwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
    uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
}

    // ───── Wrap / Unwrap -------------------------------------------------------
    function _wrapNative(uint256 ptr, address tokenIn, uint256 amountIn) private {
        uint8 flags = InputStream.readUint8(ptr);
        bool wrap = flags & 1 == 1;
        bool overrideAddr = flags & 2 == 2;
        address weth = overrideAddr ? InputStream.readAddress(ptr) : WETH;

        if (wrap) {
            require(tokenIn == NATIVE, AGGFlowErrors.InvalidTokenForWrap());
            IWEth(weth).deposit{ value: amountIn }();
        } else {
            require(tokenIn == weth, AGGFlowErrors.InvalidTokenForUnwrap());
            IWEth(weth).withdraw(amountIn);
        }
    }

    // ───── AGG single-market swap -----------------------------------------
    function _swapAGG(uint256 ptr, address tokenIn, uint256 amountIn) private {
        address market = InputStream.readAddress(ptr);
        bool isBuy = InputStream.readUint8(ptr) != 0;
        uint32 pricePrecision = InputStream.readUint32(ptr);

        uint96 sizePrecision = uint96(InputStream.readUint(ptr));
        uint8 tokenDecimals = InputStream.readUint8(ptr);

        // compute OrderBook parameter ---------------------------------------
        uint256 divisor = 10 ** tokenDecimals;
        uint96 param =
            isBuy ? _toU96((amountIn * pricePrecision) / divisor) : _toU96((amountIn * sizePrecision) / divisor);

        uint256 value = tokenIn == NATIVE ? amountIn : 0;

        // approve src token to market when ERC-20 ---------------------------
        if (tokenIn != NATIVE) {
            IERC20(tokenIn).approveMax(market, amountIn);
        }

        if (isBuy) {
            IOrderBook(market).placeAndExecuteMarketBuy{ value: value }(param, 0, false, true);
        } else {
            IOrderBook(market).placeAndExecuteMarketSell{ value: value }(param, 0, false, true);
        }
    }

    // ───── Crystal single-market swap --------------------------------------
    function _swapCrystal(uint256 ptr, address tokenIn, uint256 amountIn) private {
        address market = InputStream.readAddress(ptr);
        bool isBuy = InputStream.readUint8(ptr) != 0;
        uint256 orderType = InputStream.readUint(ptr);

        // approve src token to market when ERC-20 ---------------------------
        if (tokenIn != NATIVE) {
            IERC20(tokenIn).approveMax(market, amountIn);
        }

        uint256 worstPrice = isBuy ? type(uint256).max : 0;

        ICrystal(market).marketOrder(
            isBuy,
            true, // isExactInput = true
            false, // isFromCaller = false
            false, // isToCaller = false
            orderType,
            amountIn, // size = amountIn
            worstPrice,
            address(this), // caller
            address(this) // referrer(router is the referrer)
        );
    }

    /**
     * @notice Curve pool swap. Legacy pools that don't return amountOut and have native coins are not supported
     * @param ptr [pool, poolType, fromIndex, toIndex] where poolType: 0=stableswap, 1=crypto
     * @param tokenIn Input token
     * @param amountIn Amount of tokenIn to take for swap
     */
    function _swapCurve(uint256 ptr, address tokenIn, uint256 amountIn) private {
        address pool = InputStream.readAddress(ptr);
        uint8 poolType = InputStream.readUint8(ptr); // 0 = stableswap, 1 = crypto
        int128 fromIndex = int8(InputStream.readUint8(ptr));
        int128 toIndex = int8(InputStream.readUint8(ptr));

        if (poolType == 0) {
            // Stableswap pool - use standard interface
            uint256 amountOut;
            if (tokenIn == NATIVE) {
                amountOut = ICurveStableSwap(pool).exchange{ value: amountIn }(fromIndex, toIndex, amountIn, 0);
            } else {
                IERC20(tokenIn).approveMax(pool, amountIn);
                amountOut = ICurveStableSwap(pool).exchange(fromIndex, toIndex, amountIn, 0);
            }
        } else if (poolType == 1) {
            // Crypto pool - use ICurveCrypto interface with uint256 parameters
            uint256 amountOut;
            if (tokenIn == NATIVE) {
                amountOut = ICurveCrypto(pool).exchange{ value: amountIn }(
                    uint256(uint128(fromIndex)), // Convert int128 to uint256
                    uint256(uint128(toIndex)), // Convert int128 to uint256
                    amountIn,
                    0 // min_dy
                );
            } else {
                IERC20(tokenIn).approveMax(pool, amountIn);
                amountOut = ICurveCrypto(pool).exchange(
                    uint256(uint128(fromIndex)), // Convert int128 to uint256
                    uint256(uint128(toIndex)), // Convert int128 to uint256
                    amountIn,
                    0 // min_dy
                );
            }
        } else {
            revert("Invalid Curve pool type");
        }
    }

    // ───── PalindromeFi swap ------------------------------------------------
    function _swapPalindromeFi(uint256 ptr, address tokenIn, uint256 amountIn) private {
        // Read pool address and tokenInIsBase
        address pool = InputStream.readAddress(ptr);
        bool tokenInIsBase = InputStream.readUint8(ptr) != 0;

        // Approve tokenIn to pool
        IERC20(tokenIn).approveMax(pool, amountIn);

        // Execute Swap Operation
        IPalindromeFi(pool).quoteAndSwap(tokenInIsBase, amountIn, 0, address(this));
    }

    // ───── LiquidityBook swap(TraderJoe/BeanExchange) ------------------------------------------------
    function _swapLiquidityBook(uint256 ptr, address tokenIn, uint256 amountIn) private {
        address pool = InputStream.readAddress(ptr);
        bool swapForY = InputStream.readUint8(ptr) != 0;

        // Approve tokenIn to pool
        IERC20(tokenIn).safeTransfer(pool, amountIn);

        // Execute Swap Operation
        ILBPair(pool).swap(swapForY, address(this));
    }
    // ─────────────────────────── Utils ─────────────────────────────────────────

    function _toU96(uint256 x) private pure returns (uint96 y) {
        require((y = uint96(x)) == x, AGGFlowErrors.Uint96Overflow());
    }

    // fallback to receive ETH when unwrapping
    receive() external payable { }
}
