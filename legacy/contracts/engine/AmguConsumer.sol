// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../prices/IValueInterpreter.sol";
import "../registry/IRegistry.sol";
import "./IEngine.sol";

/// @title AmguConsumer Base Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Inherit this to pay AMGU on a function call
abstract contract AmguConsumer {
    using SafeMath for uint256;

    event AmguPaid(address indexed payer, uint256 totalAmguPaidInEth, uint256 amguChargableGas);

    event IncentivePaid(address indexed payer, uint256 incentiveAmount);

    IRegistry public REGISTRY;

    constructor(address _registry) public {
        REGISTRY = IRegistry(_registry);
    }

    modifier amguPayable() {
        uint256 preGas = gasleft();
        _;
        uint256 postGas = gasleft();
        uint256 ethChargedForAmgu = __chargeAmgu(preGas.sub(postGas));
        __refundExtraEther(ethChargedForAmgu);
    }

    modifier amguPayableWithIncentive() {
        uint256 incentiveAmount = REGISTRY.incentive();
        require(
            msg.value >= incentiveAmount,
            "amguPayableWithIncentive: Insufficent value for incentive"
        );
        uint256 preGas = gasleft();
        _;
        uint256 postGas = gasleft();
        uint256 ethChargedForAmgu = __chargeAmgu(preGas.sub(postGas));
        uint256 totalEthCharged = ethChargedForAmgu.add(incentiveAmount);
        require(
            msg.value >= totalEthCharged,
            "amguPayableWithIncentive: Insufficent value for incentive + AMGU"
        );
        __refundExtraEther(incentiveAmount.add(ethChargedForAmgu));
        emit IncentivePaid(msg.sender, incentiveAmount);
    }

    /// @notice Deduct AMGU payment from eth sent with transaction
    /// @param _gasUsed Amount of gas for which to charge AMGU
    /// @return ethCharged_ Amount of eth charged for AMGU
    /// @dev skips price fetching if AMGU price is zero
    function __chargeAmgu(uint256 _gasUsed) private returns (uint256 ethCharged_) {
        uint256 mlnPerAmgu = IEngine(REGISTRY.engine()).getAmguPrice();
        if (mlnPerAmgu > 0) {
            uint256 mlnQuantity = mlnPerAmgu.mul(_gasUsed);
            (ethCharged_, ) = IValueInterpreter(REGISTRY.valueInterpreter())
                .calcCanonicalAssetValue(REGISTRY.MLN_TOKEN(), mlnQuantity, REGISTRY.WETH_TOKEN());
            require(msg.value >= ethCharged_, "__chargeAmgu: Insufficent value for AMGU");
            IEngine(REGISTRY.engine()).payAmguInEther{value: ethCharged_}();
            emit AmguPaid(msg.sender, ethCharged_, _gasUsed);
        }
        return ethCharged_;
    }

    /// @notice Send extra eth above charges back to the sender
    /// @param _totalEthCharged Total amount of eth charged for this transaction
    function __refundExtraEther(uint256 _totalEthCharged) private {
        require(
            msg.sender.send(msg.value.sub(_totalEthCharged)),
            "__refundExtraEther: Refund failed"
        );
    }
}