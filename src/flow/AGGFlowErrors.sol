// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library AGGFlowErrors {
    error Paused();
    error ApproveResetFailed();
    error ApproveFailed();
    error InvalidOpCode();
    error InvalidTokenForWrap();
    error InvalidTokenForUnwrap();
    error InvalidPoolType();
    error UniV3CallbackMissed();
    error ZeroRouterBalance();
    error TokenMismatch();
    error InsufficientNativeBalance();
    error SlippageExceeded();
    error NativeSendFailed();
    error UniV3CallbackInvalidSource();
    error UniV3CallbackNegativeAmount();
    error Uint96Overflow();
    error Int256Overflow();
}
