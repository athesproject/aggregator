//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// Types
import { SwapIntent, FeeCollection } from "src/entrypoint/AGGFlowEntrypointTypes.sol";

// Interfaces
interface IAGGFlowRouter {
    function executeRoute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        bytes memory program
    )
        external
        payable
        returns (uint256 amountOut);
}

/**
 * @title AGGFlowEntrypoint
 * @notice Simplified entrypoint for AGGFlow router with fee collection
 *
 * @dev Key features:
 *   - Direct integration with AGGFlow router
 *   - Flexible fee collection (input or output token)
 *   - Protocol and referrer fee support
 *   - Internal minAmountOut validation after fees
 *   - No automatic token sweeping (standard DEX router behavior)
 *
 * @dev Usage Example:
 *   SwapIntent memory swapIntent = SwapIntent({
 *     tokenUserBuys: 0x1234..., // Output token address
 *     minAmountUserBuys: 1000000, // Minimum output amount (after fees)
 *     tokenUserSells: 0x5678..., // Input token address (or address(0) for native)
 *     amountUserSells: 2000000 // Exact input amount
 *   });
 *
 *   FeeCollection memory feeCollection = FeeCollection({
 *     feeCollectorAddress: 0xABCD..., // API fee collector
 *     feeBps: 30, // 0.3% API fee
 *     referrerAddress: 0xEFGH..., // Referrer address
 *     referrerFeeBps: 20, // 0.2% referrer fee
 *     isInTokenFee: true // Take fees from input token
 *   });
 *
 *   bytes memory program = ...; // AGGFlow program bytes
 *
 *   uint256 amountOut = entrypoint.executeSwap{value: msg.value}(
 *     swapIntent,
 *     feeCollection,
 *     program
 *   );
 */
contract AGGFlowEntrypoint is ReentrancyGuardTransient, Ownable {
    using SafeTransferLib for address;

    // Constants
    address internal constant NATIVE_TOKEN = address(0);

    // Router address (configurable by owner)
    address private AGGFlowRouter;

    // Events
    event AGGFlowSwap(
        address indexed user,
        address indexed referrer,
        address tokenIn,
        address tokenOut,
        bool isFeeInInput,
        uint256 amountIn,
        uint256 amountOut,
        uint256 referrerFeeBps,
        uint256 totalFeeBps
    );

    event FeeCollected(address feeCollector, uint256 amount, address referrer, uint256 referrerAmount, address user, address token);

    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    // Custom errors
    error AGGFlowEntrypoint_InvalidFeeStructure();
    error AGGFlowEntrypoint_InvalidFeeCollector();
    error AGGFlowEntrypoint_InvalidReferrer();
    error AGGFlowEntrypoint_BuyAndSellTokensAreSame();
    error AGGFlowEntrypoint_InsufficientNativeValue();
    error AGGFlowEntrypoint_InsufficientAmountAfterFees();
    error AGGFlowEntrypoint_InvalidRouter();

    /**
     * @notice Constructor
     * @param _owner Address of the initial owner
     * @param _AGGFlowRouter Address of the AGGFlow router contract
     */
    constructor(address _owner, address _AGGFlowRouter) Ownable(_owner) {
        if (_AGGFlowRouter == address(0)) {
            revert AGGFlowEntrypoint_InvalidRouter();
        }
        AGGFlowRouter = _AGGFlowRouter;
    }

    /**
     * @notice Get the current router address
     * @return The address of the current AGGFlow router
     */
    function getRouter() external view returns (address) {
        return AGGFlowRouter;
    }

    /**
     * @notice Set a new router address (owner only)
     * @param _newRouter Address of the new AGGFlow router contract
     */
    function setRouter(address _newRouter) external onlyOwner {
        if (_newRouter == address(0)) {
            revert AGGFlowEntrypoint_InvalidRouter();
        }
        
        address oldRouter = AGGFlowRouter;
        AGGFlowRouter = _newRouter;
        
        emit RouterUpdated(oldRouter, _newRouter);
    }

    /**
     * @notice Execute a swap through AGGFlow with fee collection
     * @dev The entrypoint handles all minAmountOut validation internally after fees are applied
     * @dev Tokens are transferred from msg.sender and sent back to msg.sender
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @param program The AGGFlow program bytes
     * @return amountOut The amount of tokens received by the user (after fees)
     */
    function executeSwap(
        SwapIntent calldata swapIntent,
        FeeCollection calldata feeCollection,
        bytes calldata program
    )
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        return _executeSwapInternal(swapIntent, feeCollection, program, msg.sender);
    }

    /**
     * @notice Execute a swap through AGGFlow with fee collection and send to a specific receiver
     * @dev The entrypoint handles all minAmountOut validation internally after fees are applied
     * @dev Tokens are transferred from msg.sender but sent to the specified receiver
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @param program The AGGFlow program bytes
     * @param receiver The address that will receive the output tokens
     * @return amountOut The amount of tokens received by the receiver (after fees)
     */
    function executeSwapWithReceiver(
        SwapIntent calldata swapIntent,
        FeeCollection calldata feeCollection,
        bytes calldata program,
        address receiver
    )
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        return _executeSwapInternal(swapIntent, feeCollection, program, receiver);
    }

    /**
     * @notice Internal function to execute a swap through AGGFlow
     * @dev Tokens are always transferred from msg.sender, but sent to the specified receiver
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @param program The AGGFlow program bytes
     * @param receiver The address that will receive the output tokens
     * @return amountOut The amount of tokens received by the receiver (after fees)
     */
    function _executeSwapInternal(
        SwapIntent calldata swapIntent,
        FeeCollection calldata feeCollection,
        bytes calldata program,
        address receiver
    )
        internal
        returns (uint256 amountOut)
    {
        // Validation
        if (swapIntent.tokenUserSells == swapIntent.tokenUserBuys) {
            revert AGGFlowEntrypoint_BuyAndSellTokensAreSame();
        }

        // Validate fee structure
        _validateFeeStructure(feeCollection);

        // Transfer sell token from user (always msg.sender to allow this to have infinite approvals)
        _transferTokensFromUser(swapIntent);

        // Handle fee collection and get effective swap amount
        uint256 effectiveAmountIn = _handleFeeCollection(swapIntent, feeCollection);

        // Execute AGGFlow swap
        uint256 totalAmountOut =
            _executeAGGFlowSwap(swapIntent.tokenUserSells, effectiveAmountIn, swapIntent.tokenUserBuys, program);

        // Handle output fees and transfer tokens to receiver
        amountOut = _handleOutputAndTransfer(swapIntent, feeCollection, totalAmountOut, receiver);

        // Emit event
        emit AGGFlowSwap(
            msg.sender,
            feeCollection.referrerAddress,
            swapIntent.tokenUserSells,
            swapIntent.tokenUserBuys,
            feeCollection.isInTokenFee,
            swapIntent.amountUserSells,
            amountOut,
            feeCollection.referrerFeeBps,
            feeCollection.feeBps + feeCollection.referrerFeeBps
        );
    }

    /**
     * @notice Validates the fee structure
     * @param feeCollection The FeeCollection struct to validate
     */
    function _validateFeeStructure(FeeCollection memory feeCollection) internal pure {
        // Ensure total fees don't exceed 100% (10000 basis points)
        uint256 totalFeeBps = feeCollection.feeBps + feeCollection.referrerFeeBps;
        if (totalFeeBps > 10_000) {
            revert AGGFlowEntrypoint_InvalidFeeStructure();
        }

        // If fee is set, ensure collector address is valid
        if (feeCollection.feeBps > 0 && feeCollection.feeCollectorAddress == address(0)) {
            revert AGGFlowEntrypoint_InvalidFeeCollector();
        }

        // If referrer fee is set, ensure referrer address is valid
        if (feeCollection.referrerFeeBps > 0 && feeCollection.referrerAddress == address(0)) {
            revert AGGFlowEntrypoint_InvalidReferrer();
        }
    }

    /**
     * @notice Transfers tokens from user to this contract
     * @param swapIntent The swap parameters
     */
    function _transferTokensFromUser(SwapIntent memory swapIntent) internal {
        if (swapIntent.tokenUserSells != NATIVE_TOKEN) {
            // Transfer ERC20 tokens
            SafeTransferLib.safeTransferFrom(
                swapIntent.tokenUserSells, msg.sender, address(this), swapIntent.amountUserSells
            );
        } else {
            // Validate native token amount
            if (msg.value < swapIntent.amountUserSells) {
                revert AGGFlowEntrypoint_InsufficientNativeValue();
            }
            // Refund excess native tokens
            if (msg.value > swapIntent.amountUserSells) {
                SafeTransferLib.safeTransferETH(msg.sender, msg.value - swapIntent.amountUserSells);
            }
        }
    }

    /**
     * @notice Handles fee collection and returns effective amount for swap
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @return effectiveAmountIn Amount available for swap after input fees
     */
    function _handleFeeCollection(
        SwapIntent memory swapIntent,
        FeeCollection memory feeCollection
    )
        internal
        returns (uint256 effectiveAmountIn)
    {
        if (feeCollection.isInTokenFee) {
            // Collect fees from input token and get actual amount collected
            uint256 totalFeeCollected = _collectInputTokenFees(swapIntent, feeCollection);

            // Calculate effective amount after fees using actual fees collected
            effectiveAmountIn = swapIntent.amountUserSells - totalFeeCollected;
        } else {
            // No input fees, use full amount
            effectiveAmountIn = swapIntent.amountUserSells;
        }
    }

    /**
     * @notice Collects fees from input token
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @return totalFeeCollected The actual total amount of fees collected
     */
    function _collectInputTokenFees(
        SwapIntent memory swapIntent,
        FeeCollection memory feeCollection
    )
        internal
        returns (uint256 totalFeeCollected)
    {
        if (feeCollection.feeBps == 0 && feeCollection.referrerFeeBps == 0) {
            return 0; // No fees to collect
        }

        // Calculate fee amounts
        uint256 mainFeeAmount = (swapIntent.amountUserSells * feeCollection.feeBps) / 10_000;
        uint256 referrerFeeAmount = (swapIntent.amountUserSells * feeCollection.referrerFeeBps) / 10_000;

        // Calculate total fee collected (avoids rounding discrepancies)
        totalFeeCollected = mainFeeAmount + referrerFeeAmount;

        // Transfer main fee
        if (mainFeeAmount > 0) {
            if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
                SafeTransferLib.safeTransferETH(feeCollection.feeCollectorAddress, mainFeeAmount);
            } else {
                SafeTransferLib.safeTransfer(
                    swapIntent.tokenUserSells, feeCollection.feeCollectorAddress, mainFeeAmount
                );
            }
        }

        // Transfer referrer fee
        if (referrerFeeAmount > 0) {
            if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
                SafeTransferLib.safeTransferETH(feeCollection.referrerAddress, referrerFeeAmount);
            } else {
                SafeTransferLib.safeTransfer(
                    swapIntent.tokenUserSells, feeCollection.referrerAddress, referrerFeeAmount
                );
            }
        }

        emit FeeCollected(feeCollection.feeCollectorAddress, mainFeeAmount, feeCollection.referrerAddress, referrerFeeAmount, msg.sender, swapIntent.tokenUserSells);
    }

    /**
     * @notice Executes the AGGFlow swap
     * @dev Passes 0 as minAmountOut to AGGFlow - validation is handled internally after fees
     * @param tokenIn Input token address
     * @param amountIn Input amount
     * @param tokenOut Output token address
     * @param program AGGFlow program bytes
     * @return amountOut Amount received from swap
     */
    function _executeAGGFlowSwap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        bytes memory program
    )
        internal
        returns (uint256 amountOut)
    {
        // Approve tokens to AGGFlow router if not native
        if (tokenIn != NATIVE_TOKEN) {
            SafeTransferLib.safeApprove(tokenIn, AGGFlowRouter, amountIn);
        }

        // Determine value to send
        uint256 value = tokenIn == NATIVE_TOKEN ? amountIn : 0;

        // Call AGGFlow router
        amountOut =
            IAGGFlowRouter(AGGFlowRouter).executeRoute{ value: value }(tokenIn, amountIn, tokenOut, 0, program);

        // Reset approval if not native
        if (tokenIn != NATIVE_TOKEN) {
            SafeTransferLib.safeApprove(tokenIn, AGGFlowRouter, 0);
        }
    }

    /**
     * @notice Handles output fees and transfers tokens to receiver
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @param totalAmountOut Total amount received from swap
     * @param receiver The address that will receive the output tokens
     * @return amountOut Net amount received by receiver
     */
    function _handleOutputAndTransfer(
        SwapIntent memory swapIntent,
        FeeCollection memory feeCollection,
        uint256 totalAmountOut,
        address receiver
    )
        internal
        returns (uint256 amountOut)
    {
        amountOut = totalAmountOut;

        // Calculate final amount after fees
        if (!feeCollection.isInTokenFee) {
            // Collect output token fees
            amountOut = _collectOutputTokenFees(swapIntent, feeCollection, totalAmountOut);
        }

        // Single validation check: ensure receiver receives at least minAmountUserBuys
        if (amountOut < swapIntent.minAmountUserBuys) {
            revert AGGFlowEntrypoint_InsufficientAmountAfterFees();
        }

        // Transfer output tokens to receiver
        if (swapIntent.tokenUserBuys == NATIVE_TOKEN) {
            SafeTransferLib.safeTransferETH(receiver, amountOut);
        } else {
            SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, receiver, amountOut);
        }
    }

    /**
     * @notice Collects fees from output token
     * @param swapIntent The swap parameters
     * @param feeCollection Fee collection configuration
     * @param totalAmountOut Total output amount before fees
     * @return Net amount after fees
     */
    function _collectOutputTokenFees(
        SwapIntent memory swapIntent,
        FeeCollection memory feeCollection,
        uint256 totalAmountOut
    )
        internal
        returns (uint256)
    {
        // Calculate fee amounts
        uint256 mainFeeAmount = (totalAmountOut * feeCollection.feeBps) / 10_000;
        uint256 referrerFeeAmount = (totalAmountOut * feeCollection.referrerFeeBps) / 10_000;
        uint256 totalFeeCollected = mainFeeAmount + referrerFeeAmount;

        // Transfer main fee
        if (mainFeeAmount > 0) {
            if (swapIntent.tokenUserBuys == NATIVE_TOKEN) {
                SafeTransferLib.safeTransferETH(feeCollection.feeCollectorAddress, mainFeeAmount);
            } else {
                SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, feeCollection.feeCollectorAddress, mainFeeAmount);
            }
        }

        // Transfer referrer fee
        if (referrerFeeAmount > 0) {
            if (swapIntent.tokenUserBuys == NATIVE_TOKEN) {
                SafeTransferLib.safeTransferETH(feeCollection.referrerAddress, referrerFeeAmount);
            } else {
                SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, feeCollection.referrerAddress, referrerFeeAmount);
            }
        }

        emit FeeCollected(feeCollection.feeCollectorAddress, mainFeeAmount, feeCollection.referrerAddress, referrerFeeAmount, msg.sender, swapIntent.tokenUserBuys);

        return totalAmountOut - totalFeeCollected;
    }

    /**
     * @notice Fallback function to receive native tokens
     */
    receive() external payable { }
}
