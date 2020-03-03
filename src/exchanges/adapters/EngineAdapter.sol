pragma solidity 0.6.4;
pragma experimental ABIEncoderV2;

import "../libs/ExchangeAdapter.sol";
import "../libs/OrderTaker.sol";
import "../../dependencies/WETH.sol";
import "../../engine/IEngine.sol";

/// @title EngineAdapter Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Trading adapter to Melon Engine
contract EngineAdapter is ExchangeAdapter, OrderTaker {
    /// @notice Extract arguments for risk management validations of a takeOrder call
    /// @param _encodedArgs Encoded parameters passed from client side
    /// @return rskMngAddrs needed addresses for risk management
    /// - [0] Maker address
    /// - [1] Taker address
    /// - [2] Maker asset
    /// - [3] Taker asset
    /// - [4] Maker fee asset
    /// - [5] Taker fee asset
    /// @return rskMngVals needed values for risk management
    /// - [0] Maker asset amount
    /// - [1] Taker asset amount
    /// - [2] Fill amount
    function extractTakeOrderRiskManagementArgs(
        bytes calldata _encodedArgs
    )
        external
        view
        override
        returns (address[6] memory, uint256[3] memory)
    {
        address[6] memory rskMngAddrs;
        uint256[3] memory rskMngVals;
        (
            address[2] memory orderAddresses,
            uint256[2] memory orderValues
        ) = __decodeTakeOrderArgs(_encodedArgs);

        rskMngAddrs = [
            address(0),
            address(0),
            orderAddresses[0],
            orderAddresses[1],
            address(0),
            address(0)
        ];
        rskMngVals = [
            orderValues[0],
            orderValues[1],
            orderValues[1]
        ];

        return (rskMngAddrs, rskMngVals);
    }

    /// @notice Buys Ether from the Melon Engine, selling MLN (takeOrder)
    /// @param _targetExchange Address of the Melon Engine
    /// @param _encodedArgs Encoded parameters passed from client side
    /// @param _fillData Encoded data to pass to OrderFiller
    function __fillTakeOrder(
        address _targetExchange,
        bytes memory _encodedArgs,
        bytes memory _fillData
    )
        internal
        override
        validateAndFinalizeFilledOrder(_targetExchange, _fillData)
    {
        (
            address[] memory fillAssets,
            uint256[] memory fillExpectedAmounts,
        ) = __decodeOrderFillData(_fillData);

        // Fill order on Engine
        uint256 preEthBalance = payable(address(this)).balance;
        IEngine(_targetExchange).sellAndBurnMln(fillExpectedAmounts[1]);
        uint256 ethFilledAmount = sub(payable(address(this)).balance, preEthBalance);

        // Return ETH to WETH
        WETH(payable(fillAssets[0])).deposit.value(ethFilledAmount)();
    }

    /// @notice Formats arrays of _fillAssets and their _fillExpectedAmounts for a takeOrder call
    /// @param _targetExchange Address of the Melon Engine
    /// @param _encodedArgs Encoded parameters passed from client side
    /// @return _fillAssets Assets to fill
    /// - [0] Maker asset (same as _orderAddresses[2])
    /// - [1] Taker asset (same as _orderAddresses[3])
    /// @return _fillExpectedAmounts Asset fill amounts
    /// - [0] Expected (min) quantity of WETH to receive
    /// - [1] Expected (max) quantity of MLN to spend
    /// @return _fillApprovalTargets Recipients of assets in fill order
    /// - [0] Taker (fund), set to address(0)
    /// - [1] Melon Engine (_targetExchange)
    function __formatFillTakeOrderArgs(
        address _targetExchange,
        bytes memory _encodedArgs
    )
        internal
        view
        override
        returns (address[] memory, uint256[] memory, address[] memory)
    {
        (
            address[2] memory orderAddresses,
            uint256[2] memory orderValues
        ) = __decodeTakeOrderArgs(_encodedArgs);

        address[] memory fillAssets = new address[](2);
        fillAssets[0] = orderAddresses[0]; // maker asset
        fillAssets[1] = orderAddresses[1]; // taker asset

        uint256[] memory fillExpectedAmounts = new uint256[](2);
        fillExpectedAmounts[0] = orderValues[0]; // maker fill amount
        fillExpectedAmounts[1] = orderValues[1]; // taker fill amount

        address[] memory fillApprovalTargets = new address[](2);
        fillApprovalTargets[0] = address(0); // Fund (Use 0x0)
        fillApprovalTargets[1] = _targetExchange; // Oasis Dex exchange

        return (fillAssets, fillExpectedAmounts, fillApprovalTargets);
    }

    /// @notice Validate the parameters of a takeOrder call
    /// @param _targetExchange Address of the Melon Engine
    /// @param _encodedArgs Encoded parameters passed from client side
    function __validateTakeOrderParams(
        address _targetExchange,
        bytes memory _encodedArgs
    )
        internal
        view
        override
    {
        (
            address[2] memory orderAddresses,
            uint256[2] memory orderValues
        ) = __decodeTakeOrderArgs(_encodedArgs);

        require(
            orderAddresses[0] == __getNativeAssetAddress(),
            "__validateTakeOrderParams: maker asset does not match nativeAsset"
        );
        require(
            orderAddresses[1] == __getMlnTokenAddress(),
            "__validateTakeOrderParams: taker asset does not match mlnToken"
        );
    }

    /// @notice Decode the parameters of a takeOrder call
    /// @param _encodedArgs Encoded parameters passed from client side
    /// @return orderAddresses needed addresses for an exchange to take an order
    /// - [0] Expected min ETH quantity (maker quantity)
    /// - [1] Expected MLN quantity (taker quantity)
    /// @return orderValues needed values for an exchange to take an order
    /// - [0] WETH token (maker asset)
    /// - [1] MLN token (taker asset)
    function __decodeTakeOrderArgs(
        bytes memory _encodedArgs
    )
        internal
        pure
        returns (
            address[2] memory orderAddresses,
            uint256[2] memory orderValues
        )
    {
        return abi.decode(
            _encodedArgs,
            (
                address[2],
                uint256[2]
            )
        );
    }
}
