// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IRouterEntry {
    function executeRoute(address, uint256, address, uint256, bytes calldata) external payable returns (uint256);
}

/// @dev Uniswap V2 pair semantics: optimistic transfer out, then the 0.3% constant-product check.
contract MockV2Pair {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor() {
        factory = msg.sender;
    }

    function initialize(address t0, address t1) external {
        require(msg.sender == factory, "factory");
        token0 = t0;
        token1 = t1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function sync() public {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "output");
        (uint256 r0, uint256 r1) = (reserve0, reserve1);
        require(amount0Out < r0 && amount1Out < r1, "liquidity");
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 in1 = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "input");
        require((b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= r0 * r1 * 1_000_000, "K");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pair = address(new MockV2Pair());
        MockV2Pair(pair).initialize(t0, t1);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
    }
}

/**
 * @dev A V3-style pool with constant-product pricing. In Honest mode it behaves like Uniswap V3 for an exact-input
 *      swap: output to the recipient, callback for the input, then a check that the input arrived. The other modes
 *      are the malicious behaviours ATH-12 asks to test.
 */
contract MockV3Pool {
    using SafeERC20 for IERC20;

    enum Mode {
        Honest,
        AskMore,
        AskOutputToken,
        CallbackTwice,
        NoCallback,
        PartialFill,
        Reenter
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    Mode public mode;
    bytes public reenterCall;

    constructor(address t0, address t1, uint24 fee_) {
        token0 = t0;
        token1 = t1;
        fee = fee_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenterCall(bytes calldata data) external {
        reenterCall = data;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = uint256(amountSpecified);
        if (mode == Mode.PartialFill) amountIn /= 2;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 reserveIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 reserveOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        int256 owed = int256(amountIn);
        if (mode == Mode.AskMore) owed = int256(amountIn * 2);
        (amount0, amount1) = zeroForOne ? (owed, -int256(amountOut)) : (-int256(amountOut), owed);
        if (mode == Mode.AskOutputToken) (amount0, amount1) = (amount1, amount0);

        if (mode == Mode.Reenter) {
            (bool ok, bytes memory ret) = msg.sender.call(reenterCall);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        if (mode == Mode.NoCallback) return (amount0, amount1);

        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        if (mode == Mode.CallbackTwice) IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= balanceBefore + amountIn, "IIA");
    }
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address a, address b, uint24 fee) external returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pool = address(new MockV3Pool(t0, t1, fee));
        getPool[t0][t1][fee] = pool;
        getPool[t1][t0][fee] = pool;
    }
}
