// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { ERC20DecimalsMock } from "../mocks/ERC20DecimalsMock.sol";
import { NoReturnERC20Mock } from "../mocks/NoReturnERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";

/// @notice Tests collateral with non-18 token decimals, non-8 feed decimals, and non-standard ERC20 return values.
contract DSCEngineDecimalsTest is Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;

    ERC20Mock public weth; // 18 decimals, 8-decimal feed
    ERC20DecimalsMock public wbtc; // 8 decimals, 8-decimal feed
    ERC20DecimalsMock public link; // 18 decimals, 18-decimal feed
    NoReturnERC20Mock public usdt; // 6 decimals, 8-decimal feed, no return values

    MockV3Aggregator public ethUsdFeed;
    MockV3Aggregator public btcUsdFeed;
    MockV3Aggregator public linkUsdFeed;
    MockV3Aggregator public usdtUsdFeed;

    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 30_000e8;
    int256 public constant LINK_USD_PRICE = 20e18;
    int256 public constant USDT_USD_PRICE = 1e8;

    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");

    function setUp() public {
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        wbtc = new ERC20DecimalsMock("Wrapped BTC", "WBTC", 8);
        link = new ERC20DecimalsMock("Chainlink", "LINK", 18);
        usdt = new NoReturnERC20Mock();

        ethUsdFeed = new MockV3Aggregator(8, ETH_USD_PRICE);
        btcUsdFeed = new MockV3Aggregator(8, BTC_USD_PRICE);
        linkUsdFeed = new MockV3Aggregator(18, LINK_USD_PRICE);
        usdtUsdFeed = new MockV3Aggregator(8, USDT_USD_PRICE);

        address[] memory tokens = new address[](4);
        tokens[0] = address(weth);
        tokens[1] = address(wbtc);
        tokens[2] = address(link);
        tokens[3] = address(usdt);
        address[] memory feeds = new address[](4);
        feeds[0] = address(ethUsdFeed);
        feeds[1] = address(btcUsdFeed);
        feeds[2] = address(linkUsdFeed);
        feeds[3] = address(usdtUsdFeed);

        dsc = new DecentralizedStableCoin();
        dsce = new DSCEngine(tokens, feeds, address(dsc));
        dsc.transferOwnership(address(dsce));
    }

    ////////////////////
    // Price helpers  //
    ////////////////////

    function testCachesDecimals() public {
        assertEq(dsce.getTokenDecimals(address(wbtc)), 8);
        assertEq(dsce.getFeedDecimals(address(wbtc)), 8);
        assertEq(dsce.getTokenDecimals(address(link)), 18);
        assertEq(dsce.getFeedDecimals(address(link)), 18);
        assertEq(dsce.getTokenDecimals(address(usdt)), 6);
    }

    function testUsdValueWith8DecimalToken() public {
        // 1 WBTC (1e8 units) at $30,000
        assertEq(dsce.getUsdValue(address(wbtc), 1e8), 30_000e18);
    }

    function testTokenAmountFromUsdWith8DecimalToken() public {
        assertEq(dsce.getTokenAmountFromUsd(address(wbtc), 15_000e18), 0.5e8);
    }

    function testUsdValueWith18DecimalFeed() public {
        assertEq(dsce.getUsdValue(address(link), 3e18), 60e18);
    }

    function testTokenAmountFromUsdWith18DecimalFeed() public {
        assertEq(dsce.getTokenAmountFromUsd(address(link), 60e18), 3e18);
    }

    function testUsdValueWith6DecimalToken() public {
        assertEq(dsce.getUsdValue(address(usdt), 1000e6), 1000e18);
    }

    function testGetUsdValueRevertsOnZeroPrice() public {
        btcUsdFeed.updateAnswer(0);
        vm.expectRevert();
        dsce.getUsdValue(address(wbtc), 1e8);
    }

    ////////////////////////////
    // Non-standard ERC20s    //
    ////////////////////////////

    function testNoReturnTokenCanBeDepositedAndRedeemed() public {
        uint256 amount = 1000e6;
        usdt.mint(user, amount);

        vm.startPrank(user);
        usdt.approve(address(dsce), amount);
        dsce.depositCollateral(address(usdt), amount);
        assertEq(dsce.getCollateralBalanceOfUser(user, address(usdt)), amount);
        assertEq(dsce.getAccountCollateralValue(user), 1000e18);

        dsce.redeemCollateral(address(usdt), amount);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), amount);
        assertEq(usdt.balanceOf(address(dsce)), 0);
    }

    ////////////////////////////////////
    // End-to-end with 8-decimal WBTC //
    ////////////////////////////////////

    function testMintAndLiquidateWith8DecimalCollateral() public {
        // User: 1 WBTC ($30,000) backs 15,000 DSC -> health factor exactly 1
        uint256 userCollateral = 1e8;
        uint256 userDebt = 15_000e18;
        wbtc.mint(user, userCollateral);
        vm.startPrank(user);
        wbtc.approve(address(dsce), userCollateral);
        dsce.depositCollateralAndMintDsc(address(wbtc), userCollateral, userDebt);
        vm.stopPrank();
        assertEq(dsce.getHealthFactor(user), 1e18);

        // BTC drops to $20,000 -> health factor 0.666...
        btcUsdFeed.updateAnswer(20_000e8);
        assertLt(dsce.getHealthFactor(user), 1e18);

        // Liquidator: 20 WETH ($40,000) backs 15,000 DSC
        uint256 liquidatorCollateral = 20 ether;
        weth.mint(liquidator, liquidatorCollateral);
        vm.startPrank(liquidator);
        weth.approve(address(dsce), liquidatorCollateral);
        dsce.depositCollateralAndMintDsc(address(weth), liquidatorCollateral, userDebt);
        dsc.approve(address(dsce), userDebt);
        dsce.liquidate(address(wbtc), user, userDebt);
        vm.stopPrank();

        // $15,000 / $20,000 = 0.75 WBTC, plus 10% bonus = 0.825 WBTC
        assertEq(wbtc.balanceOf(liquidator), 82_500_000);
        assertEq(dsce.getCollateralBalanceOfUser(user, address(wbtc)), 17_500_000);
        assertEq(dsce.getDscMinted(user), 0);
        assertEq(dsce.getUsdValue(address(wbtc), 17_500_000), 3500e18);
    }

    ////////////////
    // Fuzz tests //
    ////////////////

    function testFuzz_UsdRoundTripLosesLessThanOneTokenUnit(uint256 usdAmount, uint256 tokenSeed) public {
        usdAmount = bound(usdAmount, 0, 1e36);
        address token = _tokenFromSeed(tokenSeed);

        uint256 tokenAmount = dsce.getTokenAmountFromUsd(token, usdAmount);
        uint256 roundTripUsd = dsce.getUsdValue(token, tokenAmount);

        // Conversion always rounds down, never in the user's favor, by at most one token unit
        assertLe(roundTripUsd, usdAmount);
        assertLe(usdAmount - roundTripUsd, dsce.getUsdValue(token, 1) + 1);
    }

    function testFuzz_CannotMintBelowMinHealthFactor(uint256 collateralAmount, uint256 mintAmount) public {
        collateralAmount = bound(collateralAmount, 1, 1e12); // up to 10,000 WBTC
        mintAmount = bound(mintAmount, 1, 1e30);

        wbtc.mint(user, collateralAmount);
        vm.startPrank(user);
        wbtc.approve(address(dsce), collateralAmount);
        dsce.depositCollateral(address(wbtc), collateralAmount);

        uint256 collateralUsd = dsce.getUsdValue(address(wbtc), collateralAmount);
        uint256 maxMintable = (collateralUsd * dsce.getLiquidationThreshold()) / dsce.getLiquidationPrecision();

        if (mintAmount > maxMintable) {
            uint256 expectedHealthFactor = dsce.calculateHealthFactor(mintAmount, collateralUsd);
            vm.expectRevert(
                abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor)
            );
            dsce.mintDsc(mintAmount);
        } else {
            dsce.mintDsc(mintAmount);
            assertGe(dsce.getHealthFactor(user), dsce.getMinHealthFactor());
            assertEq(dsc.balanceOf(user), mintAmount);
        }
        vm.stopPrank();
    }

    function _tokenFromSeed(uint256 seed) private view returns (address) {
        uint256 index = seed % 4;
        if (index == 0) return address(weth);
        if (index == 1) return address(wbtc);
        if (index == 2) return address(link);
        return address(usdt);
    }
}
