//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

struct SwapIntent {
    address tokenUserBuys;
    uint256 minAmountUserBuys;
    address tokenUserSells;
    uint256 amountUserSells;
}

struct FeeCollection {
    address feeCollectorAddress; // Address to receive the main fee (API)
    uint256 feeBps; // Fee in basis points for the main collector
    address referrerAddress; // Address to receive the referrer fee (external apps)
    uint256 referrerFeeBps; // Referrer fee in basis points
    bool isInTokenFee; // true = take fee in input token (tokenUserSells), false = take fee in output token
        // (tokenUserBuys)
}
