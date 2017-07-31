pragma solidity ^0.4.11;

import "./dependencies/ERC20.sol";
import {ERC20 as Shares} from "./dependencies/ERC20.sol";
import "./assets/AssetProtocol.sol";
import "./dependencies/DBC.sol";
import "./dependencies/Owned.sol";
import "./dependencies/SafeMath.sol";
import "./universe/UniverseProtocol.sol";
import "./participation/ParticipationProtocol.sol";
import "./datafeeds/PriceFeedProtocol.sol";
import "./rewards/RewardsProtocol.sol";
import "./riskmgmt/RiskMgmtProtocol.sol";
import "./exchange/ExchangeProtocol.sol";
import "./VaultProtocol.sol";
import "./dependencies/Logger.sol";

/// @title Vault Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Simple vault
contract Vault is DBC, Owned, Shares, VaultProtocol {
    using SafeMath for uint256;

    // TYPES

    struct Prospectus { // Can be changed by Owner
      bool subscriptionAllowed;
      uint256 subscriptionFee; // Minimum threshold
      bool redeemalAllow;
      uint256 withdrawalFee;
    }

    struct Modules { // Can't be changed by Owner
        UniverseProtocol universe;
        ParticipationProtocol participation;
        RiskMgmtProtocol riskmgmt;
        RewardsProtocol rewards;
    }

    struct Calculations {
        uint256 gav;
        uint256 managementReward;
        uint256 performanceReward;
        uint256 unclaimedRewards;
        uint256 nav;
        uint256 sharePrice;
        uint256 totalSupply;
        uint256 timestamp;
    }

    // FIELDS

    uint256 public constant SUBSCRIBE_THRESHOLD = 1000;
    uint256 public constant SUBSCRIBE_FEE_DIVISOR = 100000; // << 10 ** decimals
    // Fields that are only changed in constructor
    string public name;
    string public symbol;
    uint public decimals;
    uint256 public baseUnitsPerShare; // One unit of share equals 10 ** decimals of base unit of shares
    address public melonAsset; // Adresss of Melon asset contract
    address public referenceAsset; // Performance measured against value of this asset
    // Fields that can be changed by functions
    Prospectus public prospectus;
    Modules public module;
    Calculations public atLastPayout;
    Logger public logger;

    // EVENTS

    // PRE, POST, INVARIANT CONDITIONS

    function isZero(uint256 x) internal returns (bool) { return 0 == x; }
    function isPastZero(uint256 x) internal returns (bool) { return 0 < x; }
    function balancesOfHolderAtLeast(address ofHolder, uint256 x) internal returns (bool) { return balances[ofHolder] >= x; }
    function atLeastThreshold(uint256 x) internal returns (bool) { return x >= SUBSCRIBE_THRESHOLD; }

    // CONSTANT METHODS

    function getReferenceAsset() constant returns (address) { return referenceAsset; }
    function getUniverseAddress() constant returns (address) { return module.universe; }
    function getDecimals() constant returns (uint) { return decimals; }
    function getBaseUnitsPerShare() constant returns (uint) { return baseUnitsPerShare; }

    // CONSTANT METHODS - ACCOUNTING

    /// Pre: numShares denominated in [base unit of referenceAsset], baseUnitsPerShare not zero
    /// Post: priceInRef denominated in [base unit of referenceAsset]
    function priceForNumShares(uint256 numShares) constant returns (uint256)
    {
        var (, , , , , sharePrice) = performCalculations();
        return numShares.mul(sharePrice).div(baseUnitsPerShare);
    }

    /// Pre: numShares denominated in [base unit of referenceAsset], baseUnitsPerShare not zero
    /// Post: priceInRef denominated in [base unit of referenceAsset]
    function subscribePriceForNumShares(uint256 numShares) constant returns (uint256)
    {
        return priceForNumShares(numShares)
          .mul(SUBSCRIBE_FEE_DIVISOR.sub(prospectus.subscriptionFee))
          .div(SUBSCRIBE_FEE_DIVISOR); // [base unit of referenceAsset]
    }

    /// Pre: None
    /// Post: Gav, managementReward, performanceReward, unclaimedRewards, nav, sharePrice denominated in [base unit of referenceAsset]
    function performCalculations() constant returns (uint, uint, uint, uint, uint, uint) {
        uint256 gav = calcGav(); // Reflects value indepentent of fees
        var (managementReward, performanceReward, unclaimedRewards) = calcUnclaimedRewards(gav);
        uint256 nav = calcNav(gav, unclaimedRewards);
        uint256 sharePrice = isPastZero(totalSupply) ? calcValuePerShare(nav) : baseUnitsPerShare; // Handle potential division through zero by defining a default value
        return (gav, managementReward, performanceReward, unclaimedRewards, nav, sharePrice);
    }

    /// Pre: Gross asset value and sum of all applicable and unclaimed fees has been calculated
    /// Post: Net asset value denominated in [base unit of referenceAsset]
    function calcNav(uint256 gav, uint256 unclaimedRewards) constant returns (uint256 nav) { nav = gav.sub(unclaimedRewards); }

    /// Pre: Gross asset value has been calculated
    /// Post: The sum and its individual parts of all applicable fees denominated in [base unit of referenceAsset]
    function calcUnclaimedRewards(uint256 gav) constant returns (uint256 managementReward, uint256 performanceReward, uint256 unclaimedRewards) {
        uint256 timeDifference = now.sub(atLastPayout.timestamp);
        managementReward = module.rewards.calculateManagementReward(timeDifference, gav);
        performanceReward = 0;
        if (totalSupply != 0) {
            uint256 currSharePrice = calcValuePerShare(gav);
            if (currSharePrice > atLastPayout.sharePrice) {
              performanceReward = module.rewards.calculatePerformanceReward(currSharePrice - atLastPayout.sharePrice, totalSupply);
            }
        }
        unclaimedRewards = managementReward.add(performanceReward);
    }

    /// Pre: Non-zero share supply; value denominated in [base unit of referenceAsset]
    /// Post: Share price denominated in [base unit of referenceAsset * base unit of share / base unit of share] == [base unit of referenceAsset]
    function calcValuePerShare(uint256 value)
        constant
        pre_cond(isPastZero(totalSupply))
        returns (uint256 valuePerShare)
    {
        valuePerShare = value.mul(baseUnitsPerShare).div(totalSupply);
    }

    /// Pre: Decimals in assets must be equal to decimals in PriceFeed for all entries in Universe
    /// Post: Gross asset value denominated in [base unit of referenceAsset]
    function calcGav() constant returns (uint256 gav) {
        /* Rem 1:
         *  All prices are relative to the referenceAsset price. The referenceAsset must be
         *  equal to quoteAsset of corresponding PriceFeed.
         * Rem 2:
         *  For this version, the referenceAsset is set as EtherToken.
         *  The price of the EtherToken relative to Ether is defined to always be equal to one.
         * Rem 3:
         *  price input unit: [Wei / ( Asset * 10**decimals )] == Base unit amount of referenceAsset per base unit of asset
         *  vaultHoldings input unit: [Asset * 10**decimals] == Base unit amount of asset this vault holds
         *    ==> vaultHoldings * price == value of asset holdings of this vault relative to referenceAsset price.
         *  where 0 <= decimals <= 18 and decimals is a natural number.
         */
        uint256 numAssignedAssets = module.universe.numAssignedAssets();
        for (uint256 i = 0; i < numAssignedAssets; ++i) {
            // Holdings
            address ofAsset = address(module.universe.assetAt(i));
            AssetProtocol Asset = AssetProtocol(ofAsset);
            uint256 assetHoldings = Asset.balanceOf(this); // Amount of asset base units this vault holds
            uint256 assetDecimals = Asset.getDecimals();
            // Price
            PriceFeedProtocol Price = PriceFeedProtocol(address(module.universe.priceFeedAt(i)));
            address quoteAsset = Price.getQuoteAsset();
            assert(referenceAsset == quoteAsset); // See Remark 1
            uint256 assetPrice;
            if (ofAsset == quoteAsset) {
              assetPrice = 10 ** uint(assetDecimals); // See Remark 2
            } else {
              assetPrice = Price.getPrice(ofAsset); // Asset price given quoted to referenceAsset (and 'quoteAsset') price
            }
            gav = gav.add(assetHoldings.mul(assetPrice).div(10 ** uint(assetDecimals))); // Sum up product of asset holdings of this vault and asset prices
            logger.logPortfolioContent(assetHoldings, assetPrice, assetDecimals);
        }
    }

    // NON-CONSTANT METHODS

    function Vault(
        address ofManager,
        string withName,
        string withSymbol,
        uint withDecimals,
        address ofMelonAsset,
        address ofUniverse,
        address ofParticipation,
        address ofRiskMgmt,
        address ofRewards,
        address ofLogger
    ) {
        logger = Logger(ofLogger);
        logger.addPermission(this);
        owner = ofManager;
        name = withName;
        symbol = withSymbol;
        decimals = withDecimals;
        melonAsset = ofMelonAsset;
        baseUnitsPerShare = 10 ** decimals;
        atLastPayout = Calculations({
            gav: 0,
            managementReward: 0,
            performanceReward: 0,
            unclaimedRewards: 0,
            nav: 0,
            sharePrice: baseUnitsPerShare,
            totalSupply: totalSupply,
            timestamp: now
        });
        module.universe = UniverseProtocol(ofUniverse);
        referenceAsset = module.universe.getReferenceAsset();
        melonAsset = module.universe.getMelonAsset();
        // Assert referenceAsset is equal to quoteAsset in all assigned PriceFeeds
        uint256 numAssignedAssets = module.universe.numAssignedAssets();
        for (uint256 i = 0; i < numAssignedAssets; ++i) {
            PriceFeedProtocol Price = PriceFeedProtocol(address(module.universe.priceFeedAt(i)));
            address quoteAsset = Price.getQuoteAsset();
            require(referenceAsset == quoteAsset);
        }
        module.participation = ParticipationProtocol(ofParticipation);
        module.riskmgmt = RiskMgmtProtocol(ofRiskMgmt);
        module.rewards = RewardsProtocol(ofRewards);
    }

    // NON-CONSTANT METHODS - PARTICIPATION

    // Pre: Fee multiplied by SUBSCRIBE_FEE_DIVISOR
    // Post: New subscription fee is set
    function setSubscriptionFee(uint256 newFee) pre_cond(atLeastThreshold(newFee)) { prospectus.subscriptionFee = newFee; }

    /// Pre: Investor pre-approves spending of vault's reference asset to this contract, denominated in [base unit of referenceAsset]
    /// Post: Subscribe in this fund by creating shares
    // TODO check comment
    // TODO mitigate `spam` attack
    /* Rem:
     *  This can be seen as a non-persistent all or nothing limit order, where:
     *  amount == numShares and price == numShares/offeredAmount [Shares / Reference Asset]
     */
    function subscribe(uint256 numShares, uint256 offeredValue)
        pre_cond(module.participation.isSubscriberPermitted(msg.sender, numShares))
        pre_cond(module.participation.isSubscribePermitted(msg.sender, numShares))
    {
        if (isZero(numShares)) {
            subscribeUsingSlice(numShares);
        } else {
            uint256 actualValue = subscribePriceForNumShares(numShares); // [base unit of referenceAsset]
            assert(offeredValue >= actualValue); // Sanity Check
            assert(AssetProtocol(referenceAsset).transferFrom(msg.sender, this, actualValue));  // Transfer value
            createShares(msg.sender, numShares); // Accounting
            logger.logSubscribed(msg.sender, now, numShares);
        }
    }

    /// Pre:  Redeemer has at least `numShares` shares; redeemer approved this contract to handle shares
    /// Post: Redeemer lost `numShares`, and gained `numShares * value` reference tokens
    // TODO mitigate `spam` attack
    function redeem(uint256 numShares, uint256 requestedValue)
        pre_cond(isPastZero(numShares))
        pre_cond(module.participation.isRedeemPermitted(msg.sender, numShares))

    {
        uint256 actualValue = priceForNumShares(numShares); // [base unit of referenceAsset]
        assert(requestedValue <= actualValue); // Sanity Check
        assert(AssetProtocol(referenceAsset).transfer(msg.sender, actualValue)); // Transfer value
        annihilateShares(msg.sender, numShares); // Accounting
        logger.logRedeemed(msg.sender, now, numShares);
    }

    /// Pre: Approved spending of all assets with non-empty asset holdings;
    /// Post: Transfer percentage of all assets from Vault to Investor and annihilate numShares of shares.
    /// Note: Independent of running price feed!
    function subscribeUsingSlice(uint256 numShares)
        pre_cond(isPastZero(totalSupply))
        pre_cond(isPastZero(numShares))
    {
        allocateSlice(numShares);
        logger.logSubscribed(msg.sender, now, numShares);
    }

    /// Pre: Recipient owns shares
    /// Post: Transfer percentage of all assets from Vault to Investor and annihilate numShares of shares.
    /// Note: Independent of running price feed!
    function redeemUsingSlice(uint256 numShares)
        pre_cond(balancesOfHolderAtLeast(msg.sender, numShares))
    {
        separateSlice(numShares);
        logger.logRedeemed(msg.sender, now, numShares);
    }

    /// Pre: Allocation: Pre-approve spending for all non empty vaultHoldings of Assets, numShares denominated in [base units ]
    /// Post: Transfer ownership percentage of all assets to/from Vault
    function allocateSlice(uint256 numShares)
        internal
    {
        uint256 numAssignedAssets = module.universe.numAssignedAssets();
        for (uint256 i = 0; i < numAssignedAssets; ++i) {
            AssetProtocol Asset = AssetProtocol(address(module.universe.assetAt(i)));
            uint256 vaultHoldings = Asset.balanceOf(this); // Amount of asset base units this vault holds
            if (vaultHoldings == 0) continue;
            uint256 allocationAmount = vaultHoldings.mul(numShares).div(totalSupply); // ownership percentage of msg.sender
            uint256 senderHoldings = Asset.balanceOf(msg.sender); // Amount of asset sender holds
            require(senderHoldings >= allocationAmount);
            // Transfer allocationAmount of Assets
            assert(Asset.transferFrom(msg.sender, this, allocationAmount)); // Send funds from investor to vault
        }
        // Issue _after_ external calls
        createShares(msg.sender, numShares);
    }

    /// Pre: Allocation: Approve spending for all non empty vaultHoldings of Assets
    /// Post: Transfer ownership percentage of all assets to/from Vault
    function separateSlice(uint256 numShares)
        internal
    {
        // Current Value
        uint256 prevTotalSupply = totalSupply.sub(atLastPayout.unclaimedRewards);
        assert(isPastZero(prevTotalSupply));
        // Destroy _before_ external calls to prevent reentrancy
        annihilateShares(msg.sender, numShares);
        // Transfer separationAmount of Assets
        uint256 numAssignedAssets = module.universe.numAssignedAssets();
        for (uint256 i = 0; i < numAssignedAssets; ++i) {
            AssetProtocol Asset = AssetProtocol(address(module.universe.assetAt(i)));
            uint256 vaultHoldings = Asset.balanceOf(this); // EXTERNAL CALL: Amount of asset base units this vault holds
            if (vaultHoldings == 0) continue;
            uint256 separationAmount = vaultHoldings.mul(numShares).div(prevTotalSupply); // ownership percentage of msg.sender
            // EXTERNAL CALL
            assert(Asset.transfer(msg.sender, separationAmount)); // EXTERNAL CALL: Send funds from vault to investor
        }
    }

    function createShares(address recipient, uint256 numShares)
        internal
    {
        totalSupply = totalSupply.add(numShares);
        addShares(recipient, numShares);
    }

    function annihilateShares(address recipient, uint256 numShares)
        internal
    {
        totalSupply = totalSupply.sub(numShares);
        subShares(recipient, numShares);
    }

    function addShares(address recipient, uint256 numShares) internal {
        balances[recipient] = balances[recipient].add(numShares);
    }

    function subShares(address recipient, uint256 numShares) internal {
        balances[recipient] = balances[recipient].sub(numShares);
    }

    // NON-CONSTANT METHODS - MANAGING

    /// Pre: Sufficient balance and spending has been approved
    /// Post: Make offer on selected Exchange
    function makeOrder(ExchangeProtocol onExchange,
        uint256 sell_how_much, ERC20 sell_which_token,
        uint256 buy_how_much,  ERC20 buy_which_token
    )
        pre_cond(isOwner())
        pre_cond(module.riskmgmt.isExchangeMakePermitted(onExchange,
            sell_how_much, sell_which_token,
            buy_how_much, buy_which_token)
        )
        returns (uint256 id)
    {
        requireIsWithinKnownUniverse(onExchange, sell_which_token, buy_which_token);
        approveSpending(sell_which_token, onExchange, sell_how_much);
        id = onExchange.make(sell_how_much, sell_which_token, buy_how_much, buy_which_token);
    }

    /// Pre: Active offer (id) and valid buy amount on selected Exchange
    /// Post: Take offer on selected Exchange
    function takeOrder(ExchangeProtocol onExchange, uint256 id, uint256 wantedBuyAmount)
        pre_cond(isOwner())
        returns (bool)
    {
        // Inverse variable terminology! Buying what another person is selling
        var (
            offeredBuyAmount, offeredBuyToken,
            offeredSellAmount, offeredSellToken
        ) = onExchange.getOrder(id);
        require(wantedBuyAmount <= offeredBuyAmount);
        requireIsWithinKnownUniverse(onExchange, offeredSellToken, offeredBuyToken);
        var orderOwner = onExchange.getOwner(id);
        require(module.riskmgmt.isExchangeTakePermitted(onExchange,
            offeredSellAmount, offeredSellToken,
            offeredBuyAmount, offeredBuyToken,
            orderOwner)
        );
        uint256 wantedSellAmount = wantedBuyAmount.mul(offeredSellAmount).div(offeredBuyAmount);
        approveSpending(offeredSellToken, onExchange, wantedSellAmount);
        return onExchange.take(id, wantedBuyAmount);
    }

    /// Pre: Active offer (id) with owner of this contract on selected Exchange
    /// Post: Cancel offer on selected Exchange
    function cancelOrder(ExchangeProtocol onExchange, uint256 id)
        pre_cond(isOwner())
        returns (bool)
    {
        return onExchange.cancel(id);
    }

    /// Pre: Universe has been defined
    /// Post: Whether buying and selling of tokens are allowed at given exchange
    function requireIsWithinKnownUniverse(address onExchange, address sell_which_token, address buy_which_token)
        internal
    {
        // Asset pair defined in Universe and contains referenceAsset
        require(module.universe.assetAvailability(buy_which_token));
        require(module.universe.assetAvailability(sell_which_token));
        require(buy_which_token == referenceAsset || sell_which_token == referenceAsset); // One asset must be referenceAsset
        require(buy_which_token != referenceAsset || sell_which_token != referenceAsset); // Pair must consists of diffrent assets
        // Exchange assigned to tokens in Universe
        require(onExchange == module.universe.assignedExchange(buy_which_token));
        require(onExchange == module.universe.assignedExchange(sell_which_token));
    }

    /// Pre: To Exchange needs to be approved to spend Tokens on the Managers behalf
    /// Post: Token specific exchange as registered in universe, approved to spend ofToken
    function approveSpending(ERC20 ofToken, address onExchange, uint256 amount)
        internal
    {
        assert(ofToken.approve(onExchange, amount));
        logger.logSpendingApproved(ofToken, onExchange, amount);
    }

    // NON-CONSTANT METHODS - REWARDS

    /// Pre: Only Owner
    /// Post: Unclaimed fees of manager are converted into shares of the Owner of this fund.
    function convertUnclaimedRewards()
        pre_cond(isOwner())
    {
        var (
            gav,
            managementReward,
            performanceReward,
            unclaimedRewards,
            nav,
            sharePrice
        ) = performCalculations();
        assert(isPastZero(gav));

        // Accounting: Allocate unclaimedRewards to this fund
        uint256 numShares = totalSupply.mul(unclaimedRewards).div(gav);
        addShares(owner, numShares);
        // Update Calculations
        atLastPayout = Calculations({
          gav: gav,
          managementReward: managementReward,
          performanceReward: performanceReward,
          unclaimedRewards: unclaimedRewards,
          nav: nav,
          sharePrice: sharePrice,
          totalSupply: totalSupply,
          timestamp: now
        });

        logger.logRewardsConverted(now, numShares, unclaimedRewards);
        logger.logCalculationUpdate(now, managementReward, performanceReward, nav, sharePrice, totalSupply);
    }
}
