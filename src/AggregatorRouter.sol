// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    )
        external
        returns (int256 amount0, int256 amount1);
}

/**
 * @title  AggregatorRouter
 * @notice Executes a swap route over LitVMSwap's own V2 pairs and V3 pools, with wrapping and unwrapping of the
 *         native token, in one transaction. The fee-enforcing entrypoint calls it; anyone may call it directly.
 *
 * Route program (the byte format the website and partner API already build):
 *
 *   op   0x01 <token:20>   spend what this call holds of `token`
 *        0x02 <token:20>   spend the caller's input; `token` must be `tokenIn`
 *        0x03              spend what this call holds of the native token
 *   then <legs:1>, and for each leg <share:2> <leg>. A share is out of 65535; the last leg takes the rest.
 *   leg  0x00 <pair:20> <direction:1> <fee:3>   V2 swap; direction 0 = token0 to token1. The fee field is not
 *                                               used: LitVMSwap V2 pairs always charge 0.3%.
 *        0x01 <pool:20> <zeroForOne:1>          V3 exact-input swap
 *        0x02 <wrap:1>                          1 = wrap native into the wrapped token, 0 = unwrap
 *
 * Accounting: a route can only spend what this call brought in (the caller's input) or produced (swap outputs),
 * both measured as balance changes. Tokens that were already in the router are never spent or paid out. A route
 * must end holding nothing but `tokenOut`, and exactly that amount goes to the caller.
 *
 * Pools: every pair and pool must come from the configured V2 or V3 factory, and a V3 pool may only ask, once, for
 * the input token and at most the amount of its leg.
 */
contract AggregatorRouter is Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address internal constant NATIVE = address(0);

    uint256 public constant MAX_PROGRAM_LENGTH = 1024;
    uint256 internal constant MAX_TOKENS = 8;
    uint256 internal constant SHARE_DENOMINATOR = 65_535;

    uint8 internal constant OP_ROUTER_TOKEN = 0x01;
    uint8 internal constant OP_USER_TOKEN = 0x02;
    uint8 internal constant OP_NATIVE = 0x03;

    uint8 internal constant LEG_V2 = 0x00;
    uint8 internal constant LEG_V3 = 0x01;
    uint8 internal constant LEG_WRAP = 0x02;

    // TickMath.MIN_SQRT_RATIO + 1 and TickMath.MAX_SQRT_RATIO - 1
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    address public immutable WRAPPED_NATIVE;
    address public immutable V2_FACTORY;
    address public immutable V3_FACTORY;

    // The V3 swap in progress: set right before pool.swap, cleared by the one callback it may make.
    address private transient _callbackPool;
    address private transient _callbackToken;
    bool private transient _callbackZeroForOne;
    uint256 private transient _callbackMaxAmount;
    uint256 private transient _callbackPaid;

    /// @dev What this call may spend, per token. The native token is `NATIVE`.
    struct Ledger {
        address[MAX_TOKENS] tokens;
        uint256[MAX_TOKENS] amounts;
        uint256 size;
    }

    event Route(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidNativeValue();
    error EmptyProgram();
    error ProgramTooLong();
    error MalformedProgram();
    error InvalidOpCode(uint8 op);
    error InvalidLegType(uint8 leg);
    error TokenMismatch();
    error NothingToSpend(address token);
    error TooManyTokens();
    error UnknownPool(address pool);
    error UnexpectedCallback();
    error InvalidCallbackAmount();
    error CallbackMissing();
    error PartialFill();
    error UnspentBalance(address token);
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error NativeNotAccepted();
    error NativeTransferFailed();

    constructor(address wrappedNative, address v2Factory, address v3Factory, address owner_) Ownable(owner_) {
        if (wrappedNative.code.length == 0 || v2Factory.code.length == 0 || v3Factory.code.length == 0) {
            revert InvalidAddress();
        }
        WRAPPED_NATIVE = wrappedNative;
        V2_FACTORY = v2Factory;
        V3_FACTORY = v3Factory;
    }

    // ──────────────────────────── Swaps ────────────────────────────

    /**
     * @param tokenIn       Input token, `address(0)` for native (then `msg.value` must equal `amountIn`)
     * @param amountIn      Amount pulled from the caller (who must have approved it)
     * @param tokenOut      Output token, `address(0)` for native
     * @param minAmountOut  Minimum paid to the caller
     * @param program       Route program, see the contract notes
     * @return amountOut    Amount of `tokenOut` paid to the caller
     */
    function executeRoute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        bytes calldata program
    )
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (program.length == 0) revert EmptyProgram();
        if (program.length > MAX_PROGRAM_LENGTH) revert ProgramTooLong();
        if (amountIn == 0) revert InvalidAmount();

        Ledger memory ledger;
        uint256 received;
        if (tokenIn == NATIVE) {
            if (msg.value != amountIn) revert InvalidNativeValue();
            received = amountIn;
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            received = IERC20(tokenIn).balanceOf(address(this)) - balanceBefore;
            if (received == 0) revert InvalidAmount();
        }
        _credit(ledger, tokenIn, received);

        _run(program, ledger, tokenIn);

        amountOut = _take(ledger, tokenOut);
        for (uint256 i; i < ledger.size; ++i) {
            if (ledger.amounts[i] != 0) revert UnspentBalance(ledger.tokens[i]);
        }
        if (amountOut == 0 || amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        _send(tokenOut, msg.sender, amountOut);
        emit Route(msg.sender, tokenIn, tokenOut, received, amountOut);
    }

    /// @notice Pays the pool of the V3 swap in progress. Anything else reverts.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address pool = _callbackPool;
        if (pool == address(0) || msg.sender != pool) revert UnexpectedCallback();
        _callbackPool = address(0);

        bool zeroForOne = _callbackZeroForOne;
        int256 owedDelta = zeroForOne ? amount0Delta : amount1Delta;
        int256 otherDelta = zeroForOne ? amount1Delta : amount0Delta;
        if (owedDelta <= 0 || otherDelta > 0) revert InvalidCallbackAmount();
        // casting to 'uint256' is safe because owedDelta is positive (checked above)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(owedDelta);
        if (owed > _callbackMaxAmount) revert InvalidCallbackAmount();

        _callbackPaid = owed;
        IERC20(_callbackToken).safeTransfer(pool, owed);
    }

    // ──────────────────────────── Owner ────────────────────────────

    /**
     * @notice Returns tokens someone sent to the router by mistake. A route never leaves anything behind, so this
     *         cannot reach a swap's funds. The owner is the Safe, then the timelock.
     */
    function recover(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        _send(token, to, amount);
        emit Recovered(token, to, amount);
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    /// @dev Native arrives only when the wrapped token pays out an unwrap.
    receive() external payable {
        if (msg.sender != WRAPPED_NATIVE) revert NativeNotAccepted();
    }

    // ──────────────────────────── Route execution ────────────────────────────

    function _run(bytes calldata program, Ledger memory ledger, address tokenIn) private {
        uint256 pos;
        while (pos < program.length) {
            uint8 op;
            (op, pos) = _readUint8(program, pos);

            address token;
            if (op == OP_ROUTER_TOKEN) {
                (token, pos) = _readAddress(program, pos);
            } else if (op == OP_USER_TOKEN) {
                (token, pos) = _readAddress(program, pos);
                if (token != tokenIn) revert TokenMismatch();
            } else if (op == OP_NATIVE) {
                token = NATIVE;
            } else {
                revert InvalidOpCode(op);
            }

            uint256 total = _take(ledger, token);
            if (total == 0) revert NothingToSpend(token);

            uint8 legs;
            (legs, pos) = _readUint8(program, pos);
            if (legs == 0) revert MalformedProgram();

            uint256 left = total;
            for (uint256 i; i < legs; ++i) {
                uint16 share;
                (share, pos) = _readUint16(program, pos);
                uint256 amount = i + 1 == legs ? left : (total * share) / SHARE_DENOMINATOR;
                if (amount == 0) revert InvalidAmount();
                if (amount > left) revert MalformedProgram();
                left -= amount;
                pos = _leg(program, pos, ledger, token, amount);
            }
        }
    }

    function _leg(
        bytes calldata program,
        uint256 pos,
        Ledger memory ledger,
        address token,
        uint256 amount
    )
        private
        returns (uint256)
    {
        uint8 kind;
        uint8 flag;
        address pool;
        (kind, pos) = _readUint8(program, pos);
        if (kind == LEG_V2) {
            (pool, pos) = _readAddress(program, pos);
            (flag, pos) = _readUint8(program, pos);
            pos = _skip(program, pos, 3);
            if (flag > 1) revert MalformedProgram();
            _swapV2(ledger, pool, flag == 0, token, amount);
        } else if (kind == LEG_V3) {
            (pool, pos) = _readAddress(program, pos);
            (flag, pos) = _readUint8(program, pos);
            if (flag > 1) revert MalformedProgram();
            _swapV3(ledger, pool, flag == 1, token, amount);
        } else if (kind == LEG_WRAP) {
            (flag, pos) = _readUint8(program, pos);
            if (flag > 1) revert MalformedProgram();
            _wrapOrUnwrap(ledger, flag == 1, token, amount);
        } else {
            revert InvalidLegType(kind);
        }
        return pos;
    }

    /// @param zeroForOne true swaps token0 for token1
    function _swapV2(Ledger memory ledger, address pair, bool zeroForOne, address tokenIn, uint256 amount) private {
        if (pair.code.length == 0) revert UnknownPool(pair);
        address token0 = IV2Pair(pair).token0();
        address token1 = IV2Pair(pair).token1();
        if (IV2Factory(V2_FACTORY).getPair(token0, token1) != pair) revert UnknownPool(pair);
        if (tokenIn != (zeroForOne ? token0 : token1)) revert TokenMismatch();
        address tokenOut = zeroForOne ? token1 : token0;

        (uint112 reserve0, uint112 reserve1,) = IV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        IERC20(tokenIn).safeTransfer(pair, amount);
        // What the pair actually received, so tokens that take a fee on transfer are priced correctly.
        uint256 amountInWithFee = (IERC20(tokenIn).balanceOf(pair) - reserveIn) * 997;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        if (amountOut == 0) revert InvalidAmount();

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        IV2Pair(pair).swap(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, address(this), "");
        _credit(ledger, tokenOut, IERC20(tokenOut).balanceOf(address(this)) - balanceBefore);
    }

    function _swapV3(Ledger memory ledger, address pool, bool zeroForOne, address tokenIn, uint256 amount) private {
        if (pool.code.length == 0) revert UnknownPool(pool);
        address token0 = IV3Pool(pool).token0();
        address token1 = IV3Pool(pool).token1();
        if (IV3Factory(V3_FACTORY).getPool(token0, token1, IV3Pool(pool).fee()) != pool) revert UnknownPool(pool);
        if (tokenIn != (zeroForOne ? token0 : token1)) revert TokenMismatch();
        if (amount > uint256(type(int256).max)) revert InvalidAmount();
        // casting to 'int256' is safe because amount <= type(int256).max (checked above)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = int256(amount);
        address tokenOut = zeroForOne ? token1 : token0;

        _callbackPool = pool;
        _callbackToken = tokenIn;
        _callbackZeroForOne = zeroForOne;
        _callbackMaxAmount = amount;
        _callbackPaid = 0;

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        IV3Pool(pool).swap(
            address(this), zeroForOne, amountSpecified, zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT, ""
        );
        if (_callbackPool != address(0)) revert CallbackMissing();
        // An exact-input swap that stops early (the pool ran out of liquidity) would leave input behind.
        if (_callbackPaid != amount) revert PartialFill();
        _credit(ledger, tokenOut, IERC20(tokenOut).balanceOf(address(this)) - balanceBefore);
    }

    function _wrapOrUnwrap(Ledger memory ledger, bool wrap, address token, uint256 amount) private {
        address wrapped = WRAPPED_NATIVE;
        if (wrap) {
            if (token != NATIVE) revert TokenMismatch();
            uint256 balanceBefore = IERC20(wrapped).balanceOf(address(this));
            IWrappedNative(wrapped).deposit{ value: amount }();
            _credit(ledger, wrapped, IERC20(wrapped).balanceOf(address(this)) - balanceBefore);
        } else {
            if (token != wrapped) revert TokenMismatch();
            uint256 balanceBefore = address(this).balance;
            IWrappedNative(wrapped).withdraw(amount);
            _credit(ledger, NATIVE, address(this).balance - balanceBefore);
        }
    }

    function _send(address token, address to, uint256 amount) private {
        if (token == NATIVE) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ──────────────────────────── Ledger ────────────────────────────

    function _credit(Ledger memory ledger, address token, uint256 amount) private pure {
        if (amount == 0) return;
        uint256 size = ledger.size;
        for (uint256 i; i < size; ++i) {
            if (ledger.tokens[i] == token) {
                ledger.amounts[i] += amount;
                return;
            }
        }
        if (size == MAX_TOKENS) revert TooManyTokens();
        ledger.tokens[size] = token;
        ledger.amounts[size] = amount;
        ledger.size = size + 1;
    }

    /// @dev Returns and clears what the ledger holds of `token`.
    function _take(Ledger memory ledger, address token) private pure returns (uint256 amount) {
        for (uint256 i; i < ledger.size; ++i) {
            if (ledger.tokens[i] == token) {
                amount = ledger.amounts[i];
                ledger.amounts[i] = 0;
                return amount;
            }
        }
    }

    // ──────────────────────────── Program reader ────────────────────────────
    // Every read checks that the bytes exist, so a truncated program fails with MalformedProgram.

    function _readUint8(bytes calldata program, uint256 pos) private pure returns (uint8 value, uint256 next) {
        next = pos + 1;
        if (next > program.length) revert MalformedProgram();
        value = uint8(program[pos]);
    }

    function _readUint16(bytes calldata program, uint256 pos) private pure returns (uint16 value, uint256 next) {
        next = pos + 2;
        if (next > program.length) revert MalformedProgram();
        value = uint16(bytes2(program[pos:next]));
    }

    function _readAddress(bytes calldata program, uint256 pos) private pure returns (address value, uint256 next) {
        next = pos + 20;
        if (next > program.length) revert MalformedProgram();
        value = address(bytes20(program[pos:next]));
    }

    function _skip(bytes calldata program, uint256 pos, uint256 length) private pure returns (uint256 next) {
        next = pos + length;
        if (next > program.length) revert MalformedProgram();
    }
}
