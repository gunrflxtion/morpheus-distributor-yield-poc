// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/// @notice Minimal price-feed interface (Chainlink AggregatorV3).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Price-feed stand-in used only in this local fork verification.
/// It always reports the price captured at the pinned fork block and a
/// current timestamp, so time warps in the fork do not make the feed stale.
contract MockPriceFeed {
    int256 private immutable _answer;
    uint8 private immutable _decimals;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, _answer, 0, block.timestamp, 0);
    }
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (uint256);
    function depositPoolAddresses(uint256 rewardPoolIndex_, uint256 index_) external view returns (address);
    function depositPools(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex_) external view returns (uint128);
    function minRewardsDistributePeriod() external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function rewardPool() external view returns (address);
    function l1Sender() external view returns (address);
    function aavePoolAddressesProvider() external view returns (address);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getCurrentUserMultiplier(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function rewardPoolsData(uint256 rewardPoolIndex_)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IRewardPool {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_)
        external
        view
        returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveAddressesProvider {
    function getPool() external view returns (address);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC20MetadataMini {
    function decimals() external view returns (uint8);
}

/// @title Yield share verification (Morpheus Distributor, local mainnet fork)
/// @notice Security review: checks whether a direct transfer of aTokens to
/// the Distributor is counted as pool yield when rewards are distributed,
/// and measures the resulting MOR entitlement of the tester.
/// Two scenarios: (A) baseline without any direct transfer, (B) with a
/// direct transfer of aWBTC to the Distributor before distribution.
/// Everything runs on a pinned local fork; no live transaction is sent.
contract YieldShareVerification is Test {
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address internal constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address internal constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address internal constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address internal constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;

    // Live Chainlink feeds used by the five index-0 pools (pinned block).
    address internal constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address internal constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address internal constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 internal constant REWARD_POOL_INDEX = 0;
    uint256 internal constant STAKE_WBTC = 1e8; // 1 wBTC (8 decimals)
    uint256 internal constant SUPPLY_WBTC_SATS = 648_000; // ~0.00648 wBTC for the direct transfer
    uint256 internal constant MOR_PRICE_USD_18 = 70e16; // $0.70 per MOR (17 Nov 2026 reference)

    address internal tester;
    address internal aavePool;
    address internal l1Sender;
    uint256 internal forkTimestamp;
    uint256 internal wbtcPrice18;

    function setUp() public {
        tester = makeAddr("tester");
        vm.deal(tester, 20 ether);
        vm.deal(address(this), 5 ether);
        deal(WBTC, tester, 2 * STAKE_WBTC);

        IDistributor distributor = IDistributor(DISTRIBUTOR);
        aavePool = IAaveAddressesProvider(distributor.aavePoolAddressesProvider()).getPool();
        l1Sender = distributor.l1Sender();
        forkTimestamp = block.timestamp;

        // Pin every live feed to its fork-block answer with a fresh timestamp.
        address[6] memory feeds = [
            FEED_STETH_USD,
            FEED_WBTC_BTC,
            FEED_BTC_USD,
            FEED_WETH_USD,
            FEED_USDC_USD,
            FEED_USDT_USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            (, int256 answer, , , ) = IPriceFeed(feeds[i]).latestRoundData();
            uint8 dec = IPriceFeed(feeds[i]).decimals();
            MockPriceFeed mock = new MockPriceFeed(answer, dec);
            vm.etch(feeds[i], address(mock).code);
            console.log("feed pinned", feeds[i], uint256(answer));
        }

        (, , wbtcPrice18, , , , , ) = distributor.depositPools(REWARD_POOL_INDEX, WBTC_POOL);
        console.log("fork block timestamp", forkTimestamp);
        console.log("last distribution timestamp", distributor.rewardPoolLastCalculatedTimestamp(REWARD_POOL_INDEX));
        console.log("wbtc stored price (18 dec)", wbtcPrice18);
        uint256 tranche1d = IRewardPool(distributor.rewardPool()).getPeriodRewards(
            REWARD_POOL_INDEX,
            distributor.rewardPoolLastCalculatedTimestamp(REWARD_POOL_INDEX),
            distributor.rewardPoolLastCalculatedTimestamp(REWARD_POOL_INDEX) + 86400
        );
        console.log("one-day tranche MOR (18 dec)", tranche1d);
    }

    function _poolList() internal pure returns (address[5] memory pools) {
        pools = [STETH_POOL, WBTC_POOL, WETH_POOL, USDC_POOL, USDT_POOL];
    }

    function _distributed(address[5] memory pools) internal view returns (uint256[5] memory out) {
        for (uint256 i = 0; i < pools.length; i++) {
            out[i] = IDistributor(DISTRIBUTOR).getDistributedRewards(REWARD_POOL_INDEX, pools[i]);
        }
    }

    function _sum(uint256[5] memory xs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < xs.length; i++) total += xs[i];
    }

    struct ScenarioResult {
        uint256 claimableMor; // MOR the tester can claim (18 dec)
        uint256 firstShareBps; // wBTC pool share of first distribution, basis points
        uint256 firstTrancheMor; // MOR distributed in the first distribution (18 dec)
        uint256 donationUsd18; // USD value of the direct transfer (18 dec)
        uint256 donationAwbtc; // aWBTC units transferred (8 dec)
        uint256 testerPoolShareBps; // tester virtual share of the wBTC pool, basis points
        bool claimSucceeded;
        uint256 sweptWbtc; // wBTC swept to L1Sender on tester withdraw (8 dec)
    }

    function _runScenario(bool withDirectTransfer) internal returns (ScenarioResult memory r) {
        address[5] memory pools = _poolList();
        uint256 t0 = block.timestamp;

        // 1. Stake 1 wBTC (no lock, no referrer -> 1x multiplier).
        vm.startPrank(tester);
        IERC20(WBTC).approve(DISTRIBUTOR, type(uint256).max);
        IDepositPool(WBTC_POOL).stake(REWARD_POOL_INDEX, STAKE_WBTC, 0, address(0));
        vm.stopPrank();

        (, , uint256 totalVirtual) = IDepositPool(WBTC_POOL).rewardPoolsData(REWARD_POOL_INDEX);
        uint256 testerMultiplier = IDepositPool(WBTC_POOL).getCurrentUserMultiplier(REWARD_POOL_INDEX, tester);
        r.testerPoolShareBps = (STAKE_WBTC * 10_000) / totalVirtual;
        console.log("tester multiplier (18 dec)", testerMultiplier);
        console.log("tester share of wBTC pool (bps)", r.testerPoolShareBps);

        // 2. Optional direct transfer of aWBTC to the Distributor.
        if (withDirectTransfer) {
            vm.startPrank(tester);
            IERC20(WBTC).approve(aavePool, type(uint256).max);
            IAavePool(aavePool).supply(WBTC, SUPPLY_WBTC_SATS, tester, 0);
            uint256 aBalance = IERC20(AWBTC).balanceOf(tester);
            IERC20(AWBTC).transfer(DISTRIBUTOR, aBalance);
            vm.stopPrank();
            r.donationAwbtc = aBalance;
            // USD value at the stored wBTC price: sats (8 dec) * price (18 dec) / 1e8.
            r.donationUsd18 = (aBalance * wbtcPrice18) / 1e8;
            console.log("direct transfer aWBTC (8 dec)", aBalance);
            console.log("direct transfer USD value (18 dec)", r.donationUsd18);
        }

        // 3. Move past the 1-day distribution gate and distribute.
        vm.warp(t0 + 86401);
        uint256[5] memory beforeFirst = _distributed(pools);
        IDistributor(DISTRIBUTOR).distributeRewards(REWARD_POOL_INDEX);
        uint256[5] memory afterFirst = _distributed(pools);
        uint256[5] memory deltaFirst;
        for (uint256 i = 0; i < pools.length; i++) deltaFirst[i] = afterFirst[i] - beforeFirst[i];
        r.firstTrancheMor = _sum(deltaFirst);
        r.firstShareBps = r.firstTrancheMor == 0 ? 0 : (deltaFirst[1] * 10_000) / r.firstTrancheMor;
        console.log("first distribution tranche MOR (18 dec)", r.firstTrancheMor);
        console.log("first distribution wBTC pool MOR (18 dec)", deltaFirst[1]);
        console.log("first distribution wBTC pool share (bps)", r.firstShareBps);

        // 4. Move past the 14-day claim lock and distribute again.
        vm.warp(t0 + 86401 + 1209600 + 1);
        IDistributor(DISTRIBUTOR).distributeRewards(REWARD_POOL_INDEX);

        // 5. Measure what the tester can claim, then try to claim it.
        r.claimableMor = IDepositPool(WBTC_POOL).getLatestUserReward(REWARD_POOL_INDEX, tester);
        console.log("claimable MOR before claim (18 dec)", r.claimableMor);

        vm.startPrank(tester);
        try IDepositPool(WBTC_POOL).claim{value: 0.05 ether}(REWARD_POOL_INDEX, tester) {
            r.claimSucceeded = true;
        } catch Error(string memory reason) {
            console.log("claim reverted with reason", reason);
        } catch (bytes memory) {
            console.log("claim reverted without a reason string");
        }
        vm.stopPrank();
        console.log("claim call succeeded", r.claimSucceeded);
        console.log(
            "claimable MOR after claim (18 dec)",
            IDepositPool(WBTC_POOL).getLatestUserReward(REWARD_POOL_INDEX, tester)
        );

        // 6. Withdraw the stake; this sweeps any surplus to the L1Sender.
        uint256 l1Before = IERC20(WBTC).balanceOf(l1Sender);
        vm.prank(tester);
        IDepositPool(WBTC_POOL).withdraw(REWARD_POOL_INDEX, STAKE_WBTC);
        r.sweptWbtc = IERC20(WBTC).balanceOf(l1Sender) - l1Before;
        console.log("wBTC swept to L1Sender on withdraw (8 dec)", r.sweptWbtc);
    }

    function _poolYieldUsd(address pool) internal view returns (uint256 yieldUsd18) {
        (address token, , uint256 tokenPrice, , uint256 lastUnderlyingBalance, uint8 strategy, address aToken, ) =
            IDistributor(DISTRIBUTOR).depositPools(REWARD_POOL_INDEX, pool);
        address yieldToken = strategy == 2 ? aToken : token;
        uint256 balance = IERC20(yieldToken).balanceOf(DISTRIBUTOR);
        uint256 growth = balance > lastUnderlyingBalance ? balance - lastUnderlyingBalance : 0;
        uint8 dec = IERC20MetadataMini(yieldToken).decimals();
        uint256 growth18 = dec == 18 ? growth : growth * (10 ** (18 - dec));
        yieldUsd18 = (growth18 * tokenPrice) / 1e18;
    }

    function testYieldBreakdown() public {
        // Measure the USD yield of every index-0 pool over the first
        // distribution window, before any tester stake or direct transfer.
        address[5] memory pools = _poolList();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 86401);

        uint256 totalYieldUsd18 = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            uint256 y = _poolYieldUsd(pools[i]);
            totalYieldUsd18 += y;
            console.log("pool yield USD (18 dec)", pools[i]);
            console.log(y);
        }
        console.log("total yield USD over window (18 dec)", totalYieldUsd18);

        uint256[5] memory beforeFirst = _distributed(pools);
        IDistributor(DISTRIBUTOR).distributeRewards(REWARD_POOL_INDEX);
        uint256[5] memory afterFirst = _distributed(pools);
        for (uint256 i = 0; i < pools.length; i++) {
            console.log("pool MOR delta (18 dec)", pools[i]);
            console.log(afterFirst[i] - beforeFirst[i]);
        }
    }

    function testBaselineNoDirectTransfer() public {
        ScenarioResult memory r = _runScenario(false);
        console.log("=== BASELINE (no direct transfer) ===");
        console.log("claimable MOR (18 dec)", r.claimableMor);
        // The wBTC pool earns only its tiny real yield, so its share stays small.
        assertLt(r.firstShareBps, 500, "baseline wBTC pool share unexpectedly large");
        assertGt(r.claimableMor, 0, "baseline claimable should be positive but small");
    }

    function testWithDirectTransfer() public {
        ScenarioResult memory r = _runScenario(true);
        console.log("=== WITH DIRECT TRANSFER ===");
        console.log("claimable MOR (18 dec)", r.claimableMor);
        console.log("direct transfer USD (18 dec)", r.donationUsd18);
        // The direct transfer must dominate the wBTC pool yield for this cycle.
        assertGt(r.firstShareBps, 2000, "direct transfer did not move the wBTC pool share");
        assertGt(r.claimableMor, 100 ether, "claimable MOR unexpectedly low");
        // The transferred amount must leave the Distributor as protocol yield
        // on the next withdraw (it is not recoverable by the tester).
        assertGe(r.sweptWbtc, r.donationAwbtc * 99 / 100, "direct transfer was not swept out");
    }
}
