// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVaultMain } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultMain.sol";

import { UniversalRouter } from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

import "@openzeppelin/contracts/access/Ownable.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

contract Arbitrage is Ownable {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;
    IVaultMain public immutable balancerVault;

    UniversalRouter public immutable uRouter;
    ISwapRouter public immutable pRouter;

    uint24 public constant poolFee = 500;
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    IWETH WETH = IWETH(WETH_ADDRESS);

    event Received(address sender, uint256 amount);

    event Log(string logmessage);
    event Log256(uint256 logmessage);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    fallback() external payable {
        emit Received(msg.sender, msg.value);
    }

    function refundUser(address payable user, uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Not enough balance");
        (bool success, ) = user.call{value: amount}("");
        require(success, "Refund failed");
    }

    function refundToken(address token, address user, uint256 amount) external onlyOwner {
        require(IERC20(token).balanceOf(address(this)) >= amount, "Not enough token balance");
        bool success = IERC20(token).transfer(user, amount);
        require(success, "Token refund failed");
    }

    constructor(ISwapRouter _pRouter, UniversalRouter _uRouter, address _poolManager, address _permit2, address _balancerVault) Ownable(msg.sender) {
        uRouter = UniversalRouter(_uRouter);
        pRouter = _pRouter;
        poolManager = IPoolManager(_poolManager);
        permit2 = IPermit2(_permit2);
        balancerVault = IVaultMain(_balancerVault);
    }

    function approveTokenWithPermit2(
        address token,
        uint160 amount,
        uint48 expiration,
        address _router
    ) public {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(_router), amount, expiration);
    }

    function executeFlashLoan(uint256 amount, address token0, address token1, bool startOnUniswap, PoolKey memory key) external onlyOwner {
        bytes memory userData = abi.encode(amount, token0, token1, startOnUniswap, key);
        balancerVault.unlock(abi.encodeWithSelector(this.receiveFlashLoan.selector, userData));
    }

    function receiveFlashLoan(bytes memory userData) external {
        require(msg.sender == address(balancerVault), "Unauthorized callback");

        // Decode flash loan amount
        (uint256 amount, address token0, address token1, bool startOnUniswap, PoolKey memory key) = abi.decode(userData, (uint256, address, address, bool, PoolKey));

        // Send some tokens from the vault to this contract (taking a flash loan)
        try balancerVault.sendTo(IERC20(token0), address(this), amount) {
        } catch {
            emit Log("failed to receive balancer vault tokens");
        }

        // Execute any logic with the borrowed funds (e.g., arbitrage, liquidation, etc.)
        approveTokenWithPermit2(token0, type(uint160).max, uint48(2147483647), address(uRouter));
        TransferHelper.safeApprove(token0, address(pRouter), type(uint160).max);
        approveTokenWithPermit2(token1, type(uint160).max, uint48(2147483647), address(uRouter));
        TransferHelper.safeApprove(token1, address(pRouter), type(uint160).max);

        if (startOnUniswap) {
            _Uniswap(key, uint160(amount), false, uRouter);
            WETH.deposit{value: address(this).balance}();
            TransferHelper.safeApprove(token1, address(pRouter), type(uint160).max);
            _UniswapV3(token1, token0, uint160(IERC20(token1).balanceOf(address(this))), pRouter);
        } else {
            _UniswapV3(token0, token1, uint160(amount), pRouter);
            TransferHelper.safeApprove(token0, address(this), type(uint160).max);
            WETH.withdraw(IERC20(token1).balanceOf(address(this)));
            _Uniswap(key, uint160(address(this).balance), true, uRouter);
        }

        // Repay the loan
        IERC20(token0).transfer(address(balancerVault), amount);

        // Settle the repayment
        balancerVault.settle(IERC20(token0), amount);
    }

    function _UniswapV3(
        address _token0,
        address _token1,
        uint160 _amountIn,
        ISwapRouter router
    ) internal {
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _token0,
                tokenOut: _token1,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        router.exactInputSingle(params);
    }

    function _Uniswap(
        PoolKey memory key,
        uint160 _amountIn,
        bool zeroForOne,
        UniversalRouter router
    ) internal returns (uint256 amountOut) {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(_amountIn),
                amountOutMinimum: uint128(0),
                hookData: bytes("")
            })
        );

        if (zeroForOne) {
            params[1] = abi.encode(key.currency0, _amountIn);
            params[2] = abi.encode(key.currency1, uint128(0));
        } else {
            params[1] = abi.encode(key.currency1, _amountIn);
            params[2] = abi.encode(key.currency0, uint128(0));
        }

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        router.execute(commands, inputs, block.timestamp);

        // Verify and return the output amount
        amountOut = IERC20(address(uint160(key.currency1.toId()))).balanceOf(address(this));
        return amountOut;
    }
}
