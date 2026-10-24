// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AggregatorRouter } from "src/AggregatorRouter.sol";

struct SwapIntent {
    address tokenUserBuys;
    uint256 minAmountUserBuys;
    address tokenUserSells;
    uint256 amountUserSells;
}

struct FeeCollection {
    address feeCollectorAddress;
    uint256 feeBps;
    address referrerAddress;
    uint256 referrerFeeBps;
    bool isInTokenFee;
}

interface ISwapEntry {
    function executeSwap(SwapIntent calldata, FeeCollection calldata, bytes calldata) external payable returns (uint256);
}

interface IEntrypoint is ISwapEntry {
    function setRouter(address) external;
    function getRouter() external view returns (address);
}

/**
 * @dev On a copy of live LitVM: the swaps the website sends today, with the exact programs
 *      litvmswap/utils/programBuilder.js builds, through the points wrapper and the entrypoint. Each swap runs once
 *      with the router that is live now and once after the Safe points the entrypoint at the new router; the user
 *      must receive exactly the same amount.
 *
 *      LITVM_RPC_URL and LITVM_FORK_BLOCK override the defaults.
 */
contract AggregatorRouterForkTest is Test {
    address constant SAFE = 0x868b8B48db5DDE602D24960A606A5A8F93333bf9;
    address constant WRAPPER = 0xF664B56933f3cF0d7d69982b5A8eC9101b80059D;
    address constant ENTRYPOINT = 0x5E19EB2A6BA30892CCe33f93D7Fb24D498512266;
    address constant LIVE_ROUTER = 0x0624E93350bFfc5B3570589FCae68e2CaBe6c620;
    address constant VAULT = 0xF2DF37067a8Af0e9ae617c96C887B2FdA8eA3f10;
    address constant V2_FACTORY = 0x4680BCe1632824d30D2F53656dD610736c3e312e;
    address constant V3_FACTORY = 0xDE6763A041f8Fc94CA2EE5933736F78f6D1A11c5;
    address constant WZKLTC = 0x315374AA9b5536037Cc1Efeea2439CCC0913A77e;
    address constant ZKUSDC = 0xdf69970B2fE416339187aA41D39882e864984CE9;
    address constant ZKUSDT = 0xa338b743Ec494ebB8345f4B6F27ffC902b7EF5Aa;
    address constant ZKBTC = 0xca4914407868bc37ccbE324cA149DD475d39A2Bf;
    uint256 constant SITE_FEE_BPS = 15; // litvmswap/constants/dex.js PROTOCOL_FEE_BPS

    // Built by programBuilder.js for the pools below (wzkLTC/ZKUSDC V2 0x5Ab5…, V3 0.3% 0x24AB…,
    // wzkLTC/ZKBTC V3 0.3% 0x18aB…, wzkLTC/ZKUSDT V2 0x5826…).
    bytes constant USDC_TO_WZKLTC_V2 =
        hex"02df69970b2fe416339187aa41d39882e864984ce901ffff005ab5906cfbc21642a7f526521318ba33262e395401000bb8";
    bytes constant USDC_TO_WZKLTC_V3 =
        hex"02df69970b2fe416339187aa41d39882e864984ce901ffff0124abc8e68f659d4ca97192a5d4125dd834504c8e00";
    bytes constant NATIVE_TO_USDC_V3 =
        hex"0301ffff020101315374aa9b5536037cc1efeea2439ccc0913a77e01ffff0124abc8e68f659d4ca97192a5d4125dd834504c8e01";
    bytes constant NATIVE_TO_BTC_V3 =
        hex"0301ffff020101315374aa9b5536037cc1efeea2439ccc0913a77e01ffff0118abe5e68bdad5bfc5eea6fd1b48c550ad411ec801";
    bytes constant USDC_TO_NATIVE_V2 =
        hex"02df69970b2fe416339187aa41d39882e864984ce901ffff005ab5906cfbc21642a7f526521318ba33262e395401000bb801315374aa9b5536037cc1efeea2439ccc0913a77e01ffff0200";
    bytes constant USDT_TO_NATIVE_V2 =
        hex"02a338b743ec494ebb8345f4b6f27ffc902b7ef5aa01ffff00582674e9caa11d73880c51baeb29bfc5642c858d01000bb801315374aa9b5536037cc1efeea2439ccc0913a77e01ffff0200";

    AggregatorRouter router;
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("LITVM_RPC_URL", string("https://liteforge.rpc.caldera.xyz/infra-partner-http")),
            vm.envOr("LITVM_FORK_BLOCK", uint256(64_112_487))
        );
        assertEq(IEntrypoint(ENTRYPOINT).getRouter(), LIVE_ROUTER, "fork: entrypoint router");
        router = new AggregatorRouter(WZKLTC, V2_FACTORY, V3_FACTORY, SAFE);
        deal(ZKUSDC, user, 10_000 ether);
        deal(ZKUSDT, user, 10_000 ether);
        vm.deal(user, 1000 ether);
    }

    function _received(address token, address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20(token).balanceOf(who);
    }

    /// @dev One swap as the website sends it: the user calls the points wrapper, the fee goes to the vault.
    function _siteSwap(address entry, address tokenIn, uint256 amountIn, address tokenOut, bytes memory program)
        internal
        returns (uint256 got)
    {
        SwapIntent memory intent = SwapIntent(tokenOut, 1, tokenIn, amountIn);
        FeeCollection memory fees = FeeCollection(VAULT, SITE_FEE_BPS, address(0), 0, false);
        uint256 before = _received(tokenOut, user);
        vm.startPrank(user);
        if (tokenIn != address(0)) IERC20(tokenIn).approve(entry, amountIn);
        ISwapEntry(entry).executeSwap{ value: tokenIn == address(0) ? amountIn : 0 }(intent, fees, program);
        vm.stopPrank();
        got = _received(tokenOut, user) - before;
        assertGt(got, 0);
    }

    function _switchRouter() internal {
        vm.prank(SAFE);
        IEntrypoint(ENTRYPOINT).setRouter(address(router));
    }

    /// @dev Balances of the router, entrypoint and wrapper in the tokens a route touches, native last.
    function _holdings(address[3] memory tokens) internal view returns (uint256[12] memory h) {
        address[3] memory holders = [address(router), ENTRYPOINT, WRAPPER];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                h[i * 4 + j] = tokens[j] == address(0) ? 0 : IERC20(tokens[j]).balanceOf(holders[i]);
            }
            h[i * 4 + 3] = holders[i].balance;
        }
    }

    function _sameAsLiveRouter(address entry, address tokenIn, uint256 amountIn, address tokenOut, bytes memory program)
        internal
    {
        address[3] memory touched = [tokenIn, WZKLTC, tokenOut];
        uint256 snapshot = vm.snapshotState();
        uint256 viaLive = _siteSwap(entry, tokenIn, amountIn, tokenOut, program);
        vm.revertToState(snapshot);
        _switchRouter();
        uint256[12] memory before = _holdings(touched);
        uint256 viaNew = _siteSwap(entry, tokenIn, amountIn, tokenOut, program);
        assertEq(viaNew, viaLive, "new router pays the same as the live one");
        uint256[12] memory after_ = _holdings(touched);
        for (uint256 i; i < 12; ++i) {
            assertEq(after_[i], before[i], "router, entrypoint and wrapper keep nothing");
        }
    }

    function test_Fork_UsdcToWzkltc_V2() public {
        _sameAsLiveRouter(WRAPPER, ZKUSDC, 250 ether, WZKLTC, USDC_TO_WZKLTC_V2);
    }

    function test_Fork_UsdcToWzkltc_V3() public {
        _sameAsLiveRouter(WRAPPER, ZKUSDC, 250 ether, WZKLTC, USDC_TO_WZKLTC_V3);
    }

    function test_Fork_NativeToUsdc_V3() public {
        _sameAsLiveRouter(WRAPPER, address(0), 1 ether, ZKUSDC, NATIVE_TO_USDC_V3);
    }

    function test_Fork_NativeToBtc_V3() public {
        _sameAsLiveRouter(WRAPPER, address(0), 1 ether, ZKBTC, NATIVE_TO_BTC_V3);
    }

    function test_Fork_UsdcToNative_V2() public {
        _sameAsLiveRouter(WRAPPER, ZKUSDC, 250 ether, address(0), USDC_TO_NATIVE_V2);
    }

    function test_Fork_UsdtToNative_V2() public {
        _sameAsLiveRouter(WRAPPER, ZKUSDT, 250 ether, address(0), USDT_TO_NATIVE_V2);
    }

    function test_Fork_DirectThroughEntrypoint() public {
        _sameAsLiveRouter(ENTRYPOINT, ZKUSDC, 100 ether, WZKLTC, USDC_TO_WZKLTC_V3);
    }

    /// @dev Tokens sent to the new router by mistake stay there through real swaps and cannot be taken by others.
    function test_Fork_PrefundStaysPut() public {
        _switchRouter();
        deal(ZKUSDC, address(router), 5000 ether);
        _siteSwap(WRAPPER, address(0), 1 ether, ZKUSDC, NATIVE_TO_USDC_V3);
        _siteSwap(WRAPPER, ZKUSDC, 250 ether, address(0), USDC_TO_NATIVE_V2);
        assertEq(IERC20(ZKUSDC).balanceOf(address(router)), 5000 ether);

        address stranger = makeAddr("stranger");
        deal(ZKUSDT, stranger, 1 ether);
        vm.startPrank(stranger);
        IERC20(ZKUSDT).approve(address(router), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.NothingToSpend.selector, ZKUSDC));
        router.executeRoute(
            ZKUSDT, 1 ether, ZKUSDC, 0, abi.encodePacked(uint8(0x01), ZKUSDC, uint8(1), uint16(0xffff), uint8(0x00))
        );
        vm.stopPrank();

        vm.prank(SAFE);
        router.recover(ZKUSDC, SAFE, 5000 ether);
        assertEq(IERC20(ZKUSDC).balanceOf(SAFE) >= 5000 ether, true);
    }

    /// @dev The pool and balance checks cost some gas per swap; keep it well inside the 3.5M the site sends.
    function test_Fork_GasOverhead() public {
        uint256 snapshot = vm.snapshotState();
        uint256 g = gasleft();
        _siteSwap(WRAPPER, ZKUSDC, 250 ether, WZKLTC, USDC_TO_WZKLTC_V3);
        uint256 liveGas = g - gasleft();
        vm.revertToState(snapshot);
        _switchRouter();
        g = gasleft();
        _siteSwap(WRAPPER, ZKUSDC, 250 ether, WZKLTC, USDC_TO_WZKLTC_V3);
        uint256 newGas = g - gasleft();
        emit log_named_uint("live router, whole site swap (gas)", liveGas);
        emit log_named_uint("new router, whole site swap (gas)", newGas);
        assertLt(newGas, liveGas + 60_000, "overhead bound");
    }

    /// @dev A fake pool that copies a real pool's tokens and fee is still refused: it is not the factory's pool.
    function test_Fork_FakePoolRefused() public {
        _switchRouter();
        FakePool fake = new FakePool(WZKLTC, ZKUSDC, 3000);
        bytes memory program =
            abi.encodePacked(uint8(0x02), ZKUSDC, uint8(1), uint16(0xffff), uint8(0x01), address(fake), uint8(0));
        vm.startPrank(user);
        IERC20(ZKUSDC).approve(WRAPPER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.UnknownPool.selector, address(fake)));
        ISwapEntry(WRAPPER).executeSwap(
            SwapIntent(WZKLTC, 1, ZKUSDC, 1 ether), FeeCollection(VAULT, SITE_FEE_BPS, address(0), 0, false), program
        );
        vm.stopPrank();
    }
}

contract FakePool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address t0, address t1, uint24 f) {
        token0 = t0;
        token1 = t1;
        fee = f;
    }
}
