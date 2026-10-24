// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { AggregatorRouter } from "src/AggregatorRouter.sol";
import { MockERC20, FeeOnTransferToken, NoReturnToken, MockWETH } from "test/mocks/Tokens.sol";
import { MockV2Factory, MockV2Pair, MockV3Factory, MockV3Pool } from "test/mocks/Pools.sol";

/// @dev Builds route programs byte for byte like litvmswap/utils/programBuilder.js.
abstract contract ProgramBuilder {
    function _v2Leg(address pair, address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x00), pair, uint8(tokenIn < tokenOut ? 0 : 1), uint24(3000));
    }

    function _v3Leg(address pool, address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), pool, uint8(tokenIn < tokenOut ? 1 : 0));
    }

    function _userToken(address tokenIn, bytes memory leg) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x02), tokenIn, uint8(1), uint16(0xffff), leg);
    }

    function _routerToken(address token, bytes memory leg) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), token, uint8(1), uint16(0xffff), leg);
    }

    /// @dev native in: wrap everything, then swap the wrapped token
    function _nativeIn(address wrapped, bytes memory legFromWrapped) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(0x03), uint8(1), uint16(0xffff), uint8(0x02), uint8(1), _routerToken(wrapped, legFromWrapped)
        );
    }

    /// @dev native out: appended after the swap into the wrapped token
    function _unwrap(address wrapped) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), wrapped, uint8(1), uint16(0xffff), uint8(0x02), uint8(0));
    }
}

contract AggregatorRouterTest is Test, ProgramBuilder {
    AggregatorRouter router;
    MockERC20 a;
    MockERC20 b;
    MockERC20 c;
    MockWETH weth;
    FeeOnTransferToken fot;
    NoReturnToken nrt;
    MockV2Factory v2f;
    MockV3Factory v3f;

    MockV2Pair pairAB;
    MockV2Pair pairBW;
    MockV2Pair pairFA;
    MockV2Pair pairNA;
    MockV3Pool poolAB;
    MockV3Pool poolBC;
    MockV3Pool poolWA;
    MockV3Pool poolFA;
    MockV3Pool evil; // registered in the factory, behaviour switched per test

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    uint256 constant LIQ = 1_000_000 ether;
    uint256 constant PREFUND = 777 ether;

    function setUp() public {
        a = new MockERC20("A");
        b = new MockERC20("B");
        c = new MockERC20("C");
        weth = new MockWETH();
        fot = new FeeOnTransferToken();
        nrt = new NoReturnToken();
        v2f = new MockV2Factory();
        v3f = new MockV3Factory();
        router = new AggregatorRouter(address(weth), address(v2f), address(v3f), owner);

        pairAB = MockV2Pair(v2f.createPair(address(a), address(b)));
        pairBW = MockV2Pair(v2f.createPair(address(b), address(weth)));
        pairFA = MockV2Pair(v2f.createPair(address(fot), address(a)));
        pairNA = MockV2Pair(v2f.createPair(address(nrt), address(a)));
        _seedV2(pairAB);
        _seedV2(pairBW);
        _seedV2(pairFA);
        _seedV2(pairNA);

        poolAB = MockV3Pool(v3f.createPool(address(a), address(b), 3000));
        poolBC = MockV3Pool(v3f.createPool(address(b), address(c), 3000));
        poolWA = MockV3Pool(v3f.createPool(address(weth), address(a), 500));
        poolFA = MockV3Pool(v3f.createPool(address(fot), address(a), 3000));
        evil = MockV3Pool(v3f.createPool(address(a), address(b), 10_000));
        _seedV3(poolAB);
        _seedV3(poolBC);
        _seedV3(poolWA);
        _seedV3(poolFA);
        _seedV3(evil);

        a.mint(user, 1000 ether);
        b.mint(user, 1000 ether);
        fot.mint(user, 1000 ether);
        nrt.mint(user, 1000 ether);
        vm.deal(user, 1000 ether);
        vm.startPrank(user);
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        fot.approve(address(router), type(uint256).max);
        nrt.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────── helpers ────────────────────────────

    function _fund(address token, address to, uint256 amount) internal {
        if (token == address(weth)) {
            vm.deal(address(this), amount);
            weth.deposit{ value: amount }();
            weth.transfer(to, amount);
        } else if (token == address(nrt)) {
            nrt.mint(to, amount);
        } else {
            MockERC20(token).mint(to, amount);
        }
    }

    function _seedV2(MockV2Pair pair) internal {
        _fund(pair.token0(), address(pair), LIQ);
        _fund(pair.token1(), address(pair), LIQ);
        pair.sync();
    }

    function _seedV3(MockV3Pool pool) internal {
        _fund(pool.token0(), address(pool), LIQ);
        _fund(pool.token1(), address(pool), LIQ);
    }

    function _prefundRouter() internal {
        a.mint(address(router), PREFUND);
        b.mint(address(router), PREFUND);
        c.mint(address(router), PREFUND);
        _fund(address(weth), address(router), PREFUND);
        vm.deal(address(router), PREFUND); // forced native, as by selfdestruct
    }

    function _assertPrefundUntouched() internal view {
        assertEq(a.balanceOf(address(router)), PREFUND, "A prefund");
        assertEq(b.balanceOf(address(router)), PREFUND, "B prefund");
        assertEq(c.balanceOf(address(router)), PREFUND, "C prefund");
        assertEq(weth.balanceOf(address(router)), PREFUND, "WETH prefund");
        assertEq(address(router).balance, PREFUND, "native prefund");
    }

    function _assertRouterEmpty() internal view {
        assertEq(a.balanceOf(address(router)), 0);
        assertEq(b.balanceOf(address(router)), 0);
        assertEq(c.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    function _v2Quote(MockV2Pair pair, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = tokenIn == pair.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    function _v3Quote(MockV3Pool pool, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        address tokenOut = tokenIn == pool.token0() ? pool.token1() : pool.token0();
        uint256 rIn = IERC20(tokenIn).balanceOf(address(pool));
        uint256 rOut = IERC20(tokenOut).balanceOf(address(pool));
        return (amountIn * 997 * rOut) / (rIn * 1000 + amountIn * 997);
    }

    function _route(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut, bytes memory program)
        internal
        returns (uint256)
    {
        vm.prank(user);
        return router.executeRoute(tokenIn, amountIn, tokenOut, minOut, program);
    }

    function _routeNative(uint256 amountIn, address tokenOut, bytes memory program) internal returns (uint256) {
        vm.prank(user);
        return router.executeRoute{ value: amountIn }(address(0), amountIn, tokenOut, 1, program);
    }

    // ──────────────────────────── routes the website builds ────────────────────────────

    function test_V2_ERC20ToERC20() public {
        uint256 expected = _v2Quote(pairAB, address(a), 10 ether);
        uint256 before = b.balanceOf(user);
        uint256 out = _route(address(a), 10 ether, address(b), expected, _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))));
        assertEq(out, expected);
        assertEq(b.balanceOf(user) - before, expected);
        _assertRouterEmpty();
    }

    function test_V2_ReverseDirection() public {
        uint256 expected = _v2Quote(pairAB, address(b), 10 ether);
        uint256 out = _route(address(b), 10 ether, address(a), 1, _userToken(address(b), _v2Leg(address(pairAB), address(b), address(a))));
        assertEq(out, expected);
        _assertRouterEmpty();
    }

    function test_V3_ERC20ToERC20_BothDirections() public {
        uint256 expected = _v3Quote(poolAB, address(a), 10 ether);
        uint256 out = _route(address(a), 10 ether, address(b), 1, _userToken(address(a), _v3Leg(address(poolAB), address(a), address(b))));
        assertEq(out, expected);
        expected = _v3Quote(poolAB, address(b), 5 ether);
        out = _route(address(b), 5 ether, address(a), 1, _userToken(address(b), _v3Leg(address(poolAB), address(b), address(a))));
        assertEq(out, expected);
        _assertRouterEmpty();
    }

    function test_NativeIn_V2() public {
        uint256 expected = _v2Quote(pairBW, address(weth), 3 ether);
        uint256 before = b.balanceOf(user);
        uint256 out = _routeNative(3 ether, address(b), _nativeIn(address(weth), _v2Leg(address(pairBW), address(weth), address(b))));
        assertEq(out, expected);
        assertEq(b.balanceOf(user) - before, expected);
        _assertRouterEmpty();
    }

    function test_NativeIn_V3() public {
        uint256 expected = _v3Quote(poolWA, address(weth), 3 ether);
        uint256 out = _routeNative(3 ether, address(a), _nativeIn(address(weth), _v3Leg(address(poolWA), address(weth), address(a))));
        assertEq(out, expected);
        _assertRouterEmpty();
    }

    function test_NativeOut_V2() public {
        uint256 expected = _v2Quote(pairBW, address(b), 4 ether);
        uint256 before = user.balance;
        bytes memory program = abi.encodePacked(
            _userToken(address(b), _v2Leg(address(pairBW), address(b), address(weth))), _unwrap(address(weth))
        );
        uint256 out = _route(address(b), 4 ether, address(0), expected, program);
        assertEq(out, expected);
        assertEq(user.balance - before, expected);
        _assertRouterEmpty();
    }

    function test_NativeOut_V3() public {
        uint256 expected = _v3Quote(poolWA, address(a), 4 ether);
        bytes memory program = abi.encodePacked(
            _userToken(address(a), _v3Leg(address(poolWA), address(a), address(weth))), _unwrap(address(weth))
        );
        uint256 out = _route(address(a), 4 ether, address(0), 1, program);
        assertEq(out, expected);
        _assertRouterEmpty();
    }

    function test_WrapOnly_And_UnwrapOnly() public {
        bytes memory wrapOnly = abi.encodePacked(uint8(0x03), uint8(1), uint16(0xffff), uint8(0x02), uint8(1));
        assertEq(_routeNative(2 ether, address(weth), wrapOnly), 2 ether);
        assertEq(weth.balanceOf(user), 2 ether);
        vm.prank(user);
        weth.approve(address(router), 2 ether);
        bytes memory unwrapOnly = abi.encodePacked(uint8(0x02), address(weth), uint8(1), uint16(0xffff), uint8(0x02), uint8(0));
        assertEq(_route(address(weth), 2 ether, address(0), 2 ether, unwrapOnly), 2 ether);
        _assertRouterEmpty();
    }

    function test_SplitRoute_TwoLegs() public {
        uint256 total = 20 ether;
        uint256 first = (total * 30_000) / 65_535;
        uint256 expected = _v2Quote(pairAB, address(a), first) + _v3Quote(poolAB, address(a), total - first);
        bytes memory program = abi.encodePacked(
            uint8(0x02), address(a), uint8(2),
            uint16(30_000), _v2Leg(address(pairAB), address(a), address(b)),
            uint16(0), _v3Leg(address(poolAB), address(a), address(b))
        );
        assertEq(_route(address(a), total, address(b), 1, program), expected);
        _assertRouterEmpty();
    }

    function test_MultiHop_V2ThenV3() public {
        uint256 mid = _v2Quote(pairAB, address(a), 10 ether);
        uint256 expected = _v3Quote(poolBC, address(b), mid);
        bytes memory program = abi.encodePacked(
            _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))),
            _routerToken(address(b), _v3Leg(address(poolBC), address(b), address(c)))
        );
        assertEq(_route(address(a), 10 ether, address(c), 1, program), expected);
        _assertRouterEmpty();
    }

    function test_RouteEvent() public {
        uint256 expected = _v2Quote(pairAB, address(a), 1 ether);
        vm.expectEmit(address(router));
        emit AggregatorRouter.Route(user, address(a), address(b), 1 ether, expected);
        _route(address(a), 1 ether, address(b), 1, _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))));
    }

    function test_SlippageExceeded() public {
        uint256 expected = _v2Quote(pairAB, address(a), 1 ether);
        bytes memory program = _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b)));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.SlippageExceeded.selector, expected, expected + 1));
        _route(address(a), 1 ether, address(b), expected + 1, program);
    }

    // ──────────────────────────── ATH-02: only this call's funds ────────────────────────────

    function test_ATH02_EmptyProgramReverts() public {
        _prefundRouter();
        vm.expectRevert(AggregatorRouter.EmptyProgram.selector);
        vm.prank(stranger);
        router.executeRoute(address(a), 1, address(a), 0, "");
        _assertPrefundUntouched();
    }

    function test_ATH02_ZeroAmountReverts() public {
        _prefundRouter();
        bytes memory program = _routerToken(address(b), _v2Leg(address(pairAB), address(b), address(a)));
        vm.expectRevert(AggregatorRouter.InvalidAmount.selector);
        vm.prank(stranger);
        router.executeRoute(address(a), 0, address(b), 0, program);
        _assertPrefundUntouched();
    }

    function test_ATH02_CannotSpendPrefundedToken() public {
        _prefundRouter();
        // The caller pays 1 wei of A, then tries to spend the router's B and native balances.
        bytes memory spendB = abi.encodePacked(
            _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))),
            _routerToken(address(c), _v3Leg(address(poolBC), address(c), address(b)))
        );
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.NothingToSpend.selector, address(c)));
        _route(address(a), 1 ether, address(b), 0, spendB);

        bytes memory spendNative = abi.encodePacked(uint8(0x03), uint8(1), uint16(0xffff), uint8(0x02), uint8(1));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.NothingToSpend.selector, address(0)));
        _route(address(a), 1 ether, address(weth), 0, abi.encodePacked(
            _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))), spendNative
        ));
        _assertPrefundUntouched();
    }

    function test_ATH02_PayoutExcludesPrefund() public {
        _prefundRouter();
        uint256 expected = _v2Quote(pairAB, address(a), 10 ether);
        uint256 out = _route(address(a), 10 ether, address(b), 1, _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))));
        assertEq(out, expected, "only the swap output is paid");
        _assertPrefundUntouched();
    }

    function test_ATH02_ForcedNativeIsNotPaidOut() public {
        _prefundRouter();
        uint256 expected = _v2Quote(pairBW, address(b), 4 ether);
        uint256 before = user.balance;
        bytes memory program = abi.encodePacked(
            _userToken(address(b), _v2Leg(address(pairBW), address(b), address(weth))), _unwrap(address(weth))
        );
        assertEq(_route(address(b), 4 ether, address(0), 1, program), expected);
        assertEq(user.balance - before, expected);
        _assertPrefundUntouched();
    }

    function test_ATH02_NativeInIgnoresForcedNative() public {
        _prefundRouter();
        uint256 expected = _v2Quote(pairBW, address(weth), 1 ether);
        assertEq(_routeNative(1 ether, address(b), _nativeIn(address(weth), _v2Leg(address(pairBW), address(weth), address(b)))), expected);
        _assertPrefundUntouched();
    }

    function test_ATH02_TokenInEqualsTokenOut() public {
        _prefundRouter();
        uint256 mid = _v2Quote(pairAB, address(a), 10 ether);
        uint256 back = _v3Quote(poolAB, address(b), mid);
        bytes memory program = abi.encodePacked(
            _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))),
            _routerToken(address(b), _v3Leg(address(poolAB), address(b), address(a)))
        );
        uint256 before = a.balanceOf(user);
        assertEq(_route(address(a), 10 ether, address(a), 1, program), back);
        assertEq(a.balanceOf(user), before - 10 ether + back);
        _assertPrefundUntouched();
    }

    function test_ATH02_UnspentIntermediateReverts() public {
        bytes memory program = _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b)));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.UnspentBalance.selector, address(b)));
        _route(address(a), 1 ether, address(c), 0, program);
    }

    function test_ATH02_NativeValueMustMatch() public {
        bytes memory erc20 = _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b)));
        vm.expectRevert(AggregatorRouter.InvalidNativeValue.selector);
        vm.prank(user);
        router.executeRoute{ value: 1 }(address(a), 1 ether, address(b), 0, erc20);

        bytes memory native = _nativeIn(address(weth), _v2Leg(address(pairBW), address(weth), address(b)));
        vm.expectRevert(AggregatorRouter.InvalidNativeValue.selector);
        vm.prank(user);
        router.executeRoute{ value: 1 ether - 1 }(address(0), 1 ether, address(b), 0, native);
    }

    function test_ATH02_UserTokenMustBeTokenIn() public {
        bytes memory program = _userToken(address(b), _v2Leg(address(pairAB), address(b), address(a)));
        vm.expectRevert(AggregatorRouter.TokenMismatch.selector);
        _route(address(a), 1 ether, address(a), 0, program);
    }

    function test_ATH02_SharesCannotOverspend() public {
        // Two legs claiming 100% each: the first leg takes everything, the last has nothing left.
        bytes memory program = abi.encodePacked(
            uint8(0x02), address(a), uint8(2),
            uint16(0xffff), _v2Leg(address(pairAB), address(a), address(b)),
            uint16(0xffff), _v3Leg(address(poolAB), address(a), address(b))
        );
        vm.expectRevert(AggregatorRouter.InvalidAmount.selector);
        _route(address(a), 1 ether, address(b), 0, program);
    }

    function testFuzz_ATH02_SplitNeverSpendsMoreThanInput(uint16 share, uint96 amount) public {
        amount = uint96(bound(amount, 1e7, 100 ether));
        uint256 first = (uint256(amount) * share) / 65_535;
        vm.assume(first >= 1e6 && amount - first >= 1e6);
        _prefundRouter();
        uint256 before = a.balanceOf(user);
        bytes memory program = abi.encodePacked(
            uint8(0x02), address(a), uint8(2),
            uint16(share), _v2Leg(address(pairAB), address(a), address(b)),
            uint16(0), _v3Leg(address(poolAB), address(a), address(b))
        );
        _route(address(a), amount, address(b), 1, program);
        assertEq(before - a.balanceOf(user), amount);
        _assertPrefundUntouched();
    }

    // ──────────────────────────── ATH-12: pools and callbacks ────────────────────────────

    function test_ATH12_PoolNotFromFactory() public {
        MockV3Pool rogue = new MockV3Pool(address(a) < address(b) ? address(a) : address(b), address(a) < address(b) ? address(b) : address(a), 3000);
        _seedV3(rogue);
        bytes memory program = _userToken(address(a), _v3Leg(address(rogue), address(a), address(b)));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.UnknownPool.selector, address(rogue)));
        _route(address(a), 1 ether, address(b), 0, program);

        MockV2Pair rogueV2 = new MockV2Pair();
        rogueV2.initialize(address(a) < address(b) ? address(a) : address(b), address(a) < address(b) ? address(b) : address(a));
        _seedV2(rogueV2);
        program = _userToken(address(a), _v2Leg(address(rogueV2), address(a), address(b)));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.UnknownPool.selector, address(rogueV2)));
        _route(address(a), 1 ether, address(b), 0, program);
    }

    function test_ATH12_PoolWithoutCode() public {
        address eoa = makeAddr("not a pool");
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.UnknownPool.selector, eoa));
        _route(address(a), 1 ether, address(b), 0, _userToken(address(a), _v3Leg(eoa, address(a), address(b))));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.UnknownPool.selector, eoa));
        _route(address(a), 1 ether, address(b), 0, _userToken(address(a), _v2Leg(eoa, address(a), address(b))));
    }

    function test_ATH12_WrongTokenForPool() public {
        // A leg from the right pool but in the wrong direction for the token being spent.
        bytes memory program = abi.encodePacked(
            uint8(0x02), address(a), uint8(1), uint16(0xffff),
            uint8(0x01), address(poolAB), uint8(address(a) < address(b) ? 0 : 1)
        );
        vm.expectRevert(AggregatorRouter.TokenMismatch.selector);
        _route(address(a), 1 ether, address(b), 0, program);
    }

    function _evilRoute(MockV3Pool.Mode mode, bytes memory expectedRevert) internal {
        _prefundRouter();
        evil.setMode(mode);
        bytes memory program = _userToken(address(a), _v3Leg(address(evil), address(a), address(b)));
        vm.expectRevert(expectedRevert);
        _route(address(a), 1 ether, address(b), 0, program);
        _assertPrefundUntouched();
    }

    function test_ATH12_CallbackAsksMoreThanTheLeg() public {
        _evilRoute(MockV3Pool.Mode.AskMore, abi.encodeWithSelector(AggregatorRouter.InvalidCallbackAmount.selector));
    }

    function test_ATH12_CallbackAsksForTheOutputToken() public {
        _evilRoute(MockV3Pool.Mode.AskOutputToken, abi.encodeWithSelector(AggregatorRouter.InvalidCallbackAmount.selector));
    }

    function test_ATH12_SecondCallbackRejected() public {
        _evilRoute(MockV3Pool.Mode.CallbackTwice, abi.encodeWithSelector(AggregatorRouter.UnexpectedCallback.selector));
    }

    function test_ATH12_MissingCallback() public {
        _evilRoute(MockV3Pool.Mode.NoCallback, abi.encodeWithSelector(AggregatorRouter.CallbackMissing.selector));
    }

    function test_ATH12_PartialFillRejected() public {
        _evilRoute(MockV3Pool.Mode.PartialFill, abi.encodeWithSelector(AggregatorRouter.PartialFill.selector));
    }

    function test_ATH12_NestedRouteRejected() public {
        evil.setReenterCall(abi.encodeCall(
            AggregatorRouter.executeRoute,
            (address(b), 1, address(a), 0, _routerToken(address(b), _v2Leg(address(pairAB), address(b), address(a))))
        ));
        _evilRoute(MockV3Pool.Mode.Reenter, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
    }

    function test_ATH12_CallbackOutsideASwap() public {
        _prefundRouter();
        vm.expectRevert(AggregatorRouter.UnexpectedCallback.selector);
        vm.prank(address(poolAB));
        router.uniswapV3SwapCallback(1 ether, 0, "");
        vm.expectRevert(AggregatorRouter.UnexpectedCallback.selector);
        router.uniswapV3SwapCallback(1 ether, 0, "");
        _assertPrefundUntouched();
    }

    // ──────────────────────────── ATH-17: program decoding ────────────────────────────

    /// @dev Every prefix of a valid program fails with a defined error: MalformedProgram inside a field, and
    ///      UnspentBalance where the cut falls between two complete ops (the wrapped native is left unspent).
    function test_ATH17_EveryTruncationFailsCleanly() public {
        bytes[3] memory programs = [
            _userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))),
            _userToken(address(a), _v3Leg(address(poolAB), address(a), address(b))),
            _nativeIn(address(weth), _v2Leg(address(pairBW), address(weth), address(b)))
        ];
        for (uint256 p; p < programs.length; ++p) {
            bytes memory full = programs[p];
            for (uint256 len = 1; len < full.length; ++len) {
                bytes memory cut = new bytes(len);
                for (uint256 i; i < len; ++i) cut[i] = full[i];
                bytes memory expected = abi.encodeWithSelector(AggregatorRouter.MalformedProgram.selector);
                if (p == 2 && len == 6) {
                    expected = abi.encodeWithSelector(AggregatorRouter.UnspentBalance.selector, address(weth));
                }
                vm.expectRevert(expected);
                if (p == 2) _routeNative(1 ether, address(b), cut);
                else _route(address(a), 1 ether, address(b), 0, cut);
            }
        }
    }

    function test_ATH17_TrailingBytesRejected() public {
        bytes memory program = abi.encodePacked(_userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))), uint8(0x01));
        vm.expectRevert(AggregatorRouter.MalformedProgram.selector);
        _route(address(a), 1 ether, address(b), 0, program);
        program = abi.encodePacked(_userToken(address(a), _v2Leg(address(pairAB), address(a), address(b))), uint8(0x00));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.InvalidOpCode.selector, 0));
        _route(address(a), 1 ether, address(b), 0, program);
    }

    function test_ATH17_InvalidOpLegAndFlags() public {
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.InvalidOpCode.selector, 0x04));
        _route(address(a), 1 ether, address(b), 0, abi.encodePacked(uint8(0x04), address(a)));
        vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.InvalidOpCode.selector, 0x05));
        _route(address(a), 1 ether, address(b), 0, abi.encodePacked(uint8(0x05)));
        // Curve, AGG, Crystal, PalindromeFi and LiquidityBook legs are not supported.
        for (uint8 leg = 3; leg <= 7; ++leg) {
            vm.expectRevert(abi.encodeWithSelector(AggregatorRouter.InvalidLegType.selector, leg));
            _route(address(a), 1 ether, address(b), 0, abi.encodePacked(uint8(0x02), address(a), uint8(1), uint16(0xffff), leg, address(pairAB)));
        }
        vm.expectRevert(AggregatorRouter.MalformedProgram.selector); // V2 direction 2
        _route(address(a), 1 ether, address(b), 0, abi.encodePacked(uint8(0x02), address(a), uint8(1), uint16(0xffff), uint8(0), address(pairAB), uint8(2), uint24(3000)));
        vm.expectRevert(AggregatorRouter.MalformedProgram.selector); // wrap flag 2 (the old custom-WETH override)
        _routeNative(1 ether, address(weth), abi.encodePacked(uint8(0x03), uint8(1), uint16(0xffff), uint8(0x02), uint8(3), address(a)));
        vm.expectRevert(AggregatorRouter.MalformedProgram.selector); // zero legs
        _route(address(a), 1 ether, address(b), 0, abi.encodePacked(uint8(0x02), address(a), uint8(0)));
    }

    function test_ATH17_ProgramTooLong() public {
        bytes memory program = new bytes(router.MAX_PROGRAM_LENGTH() + 1);
        vm.expectRevert(AggregatorRouter.ProgramTooLong.selector);
        _route(address(a), 1 ether, address(b), 0, program);
    }

    function _isRouterError(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 s = bytes4(reason);
        return s == AggregatorRouter.EmptyProgram.selector || s == AggregatorRouter.ProgramTooLong.selector
            || s == AggregatorRouter.MalformedProgram.selector || s == AggregatorRouter.InvalidOpCode.selector
            || s == AggregatorRouter.InvalidLegType.selector || s == AggregatorRouter.TokenMismatch.selector
            || s == AggregatorRouter.NothingToSpend.selector || s == AggregatorRouter.TooManyTokens.selector
            || s == AggregatorRouter.UnknownPool.selector || s == AggregatorRouter.InvalidAmount.selector
            || s == AggregatorRouter.SlippageExceeded.selector || s == AggregatorRouter.UnspentBalance.selector
            || s == AggregatorRouter.PartialFill.selector || s == AggregatorRouter.CallbackMissing.selector
            || s == AggregatorRouter.InvalidCallbackAmount.selector || s == AggregatorRouter.UnexpectedCallback.selector;
    }

    /// @dev Arbitrary bytes: a defined error or a complete valid route, and the prefund is never touched.
    function testFuzz_ATH17_ArbitraryProgram(bytes calldata program) public {
        _prefundRouter();
        vm.prank(user);
        try router.executeRoute(address(a), 1 ether, address(b), 0, program) returns (uint256 out) {
            assertGt(out, 0);
        } catch (bytes memory reason) {
            assertTrue(_isRouterError(reason), "undefined revert");
        }
        _assertPrefundUntouched();
    }

    /// @dev A valid opening followed by arbitrary bytes, to reach the leg decoders.
    function testFuzz_ATH17_ValidHeaderArbitraryTail(uint8 legKind, bytes calldata tail) public {
        _prefundRouter();
        bytes memory program = abi.encodePacked(uint8(0x02), address(a), uint8(1), uint16(0xffff), uint8(legKind % 4), tail);
        vm.prank(user);
        try router.executeRoute(address(a), 1 ether, address(b), 0, program) returns (uint256 out) {
            assertGt(out, 0);
        } catch (bytes memory reason) {
            assertTrue(_isRouterError(reason), "undefined revert");
        }
        _assertPrefundUntouched();
    }

    // ──────────────────────────── ATH-08: real amounts ────────────────────────────

    function test_ATH08_FeeOnTransferInputThroughV2() public {
        uint256 amount = 10 ether;
        uint256 received = amount - amount / 100; // the router gets 99%
        uint256 atPair = received - received / 100; // and the pair 99% of that
        uint256 expected = _v2Quote(pairFA, address(fot), atPair);
        vm.expectEmit(address(router));
        emit AggregatorRouter.Route(user, address(fot), address(a), received, expected);
        uint256 out = _route(address(fot), amount, address(a), 1, _userToken(address(fot), _v2Leg(address(pairFA), address(fot), address(a))));
        assertEq(out, expected);
        assertEq(fot.balanceOf(address(router)), 0);
    }

    function test_ATH08_FeeOnTransferInputThroughV3Reverts() public {
        bytes memory program = _userToken(address(fot), _v3Leg(address(poolFA), address(fot), address(a)));
        vm.expectRevert(bytes("IIA"));
        _route(address(fot), 10 ether, address(a), 0, program);
    }

    function test_ATH08_FeeOnTransferOutput() public {
        // The pair sends X, the router receives 99% of X and pays exactly what it received; the user gets 99% of that.
        uint256 sent = _v2Quote(pairFA, address(a), 10 ether);
        uint256 atRouter = sent - sent / 100;
        uint256 before = fot.balanceOf(user);
        uint256 out = _route(address(a), 10 ether, address(fot), 1, _userToken(address(a), _v2Leg(address(pairFA), address(a), address(fot))));
        assertEq(out, atRouter);
        assertEq(fot.balanceOf(user) - before, atRouter - atRouter / 100);
        assertEq(fot.balanceOf(address(router)), 0);
    }

    function test_ATH08_NoReturnToken() public {
        uint256 expected = _v2Quote(pairNA, address(nrt), 5 ether);
        assertEq(_route(address(nrt), 5 ether, address(a), 1, _userToken(address(nrt), _v2Leg(address(pairNA), address(nrt), address(a)))), expected);
        uint256 back = _v2Quote(pairNA, address(a), 1 ether);
        assertEq(_route(address(a), 1 ether, address(nrt), 1, _userToken(address(a), _v2Leg(address(pairNA), address(a), address(nrt)))), back);
        assertEq(nrt.balanceOf(address(router)), 0);
    }

    // ──────────────────────────── native, owner, constructor ────────────────────────────

    function test_ReceiveOnlyFromWrappedNative() public {
        vm.prank(user);
        (bool ok,) = address(router).call{ value: 1 ether }("");
        assertFalse(ok);
    }

    function test_RecoverOnlyOwner() public {
        _prefundRouter();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.recover(address(a), stranger, 1);

        vm.expectEmit(address(router));
        emit AggregatorRouter.Recovered(address(a), user, PREFUND);
        vm.prank(owner);
        router.recover(address(a), user, PREFUND);
        assertEq(a.balanceOf(user), 1000 ether + PREFUND);

        uint256 before = user.balance;
        vm.prank(owner);
        router.recover(address(0), user, PREFUND);
        assertEq(user.balance - before, PREFUND);

        vm.expectRevert(AggregatorRouter.InvalidAddress.selector);
        vm.prank(owner);
        router.recover(address(b), address(0), 1);
    }

    function test_ConstructorChecks() public {
        vm.expectRevert(AggregatorRouter.InvalidAddress.selector);
        new AggregatorRouter(makeAddr("eoa"), address(v2f), address(v3f), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AggregatorRouter(address(weth), address(v2f), address(v3f), address(0));
        assertEq(router.version(), "2.0.0");
        assertEq(router.owner(), owner);
        assertEq(router.WRAPPED_NATIVE(), address(weth));
        assertEq(router.V2_FACTORY(), address(v2f));
        assertEq(router.V3_FACTORY(), address(v3f));
    }
}
