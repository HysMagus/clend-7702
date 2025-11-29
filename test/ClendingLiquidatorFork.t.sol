// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/ClendingLiquidatorWallet.sol";

/// @dev Kept local to avoid relying on internal interfaces.
interface IClendingView {
    function DAI() external view returns (IERC20);
    function CORE_TOKEN() external view returns (IERC20);
    function coreDAO() external view returns (IERC20);
    function userTotalDebt(address user) external view returns (uint256);
}

/// @dev You must run this test against an Ethereum mainnet fork.
address constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant CLENDING = 0x54B276C8a484eBF2a244D933AF5FFaf595ea58c5;
address constant CORE_TOKEN_ADDR = 0x62359Ed7505Efc61FF1D56fEF82158CcaffA23D7;
address constant CORE_WETH_PAIR = 0x32Ce7e48debdccbFE0CD037Cc89526E4382cb81b;
address constant DAI_WETH_PAIR = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;
// Replace this one with the actual borrower address
address constant BORROWER = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;

/// - Real Maker DAI flash mint module (IERC3156FlashLender) at env `MAKER_FLASH`.
/// - Real DAI, CORE token and CORE/DAI Uniswap V2 pair on mainnet.
/// - Real Clending contract at `CLENDING`.
///
/// This test:
/// 1. Creates a mainnet fork (env `MAINNET_RPC_URL`).
/// 2. Attaches the liquidator wallet code to an existing borrower address
///    that already has debt on Clending.
/// 3. Calls `flashRepayAndReclaim` from that borrower address to:
///    - Flash mint DAI from Maker.
///    - Repay the Clending loan.
///    - Reclaim COREDAO and CORE_TOKEN collateral.
///    - Sell CORE_TOKEN into the CORE/DAI Uniswap V2 pair.
///    - Repay the flash mint + fee and realize DAI profit.
contract ClendingLiquidatorForkTest is Test {
    IClendingView public clending = IClendingView(CLENDING);

    IERC20 public dai;
    IERC20 public coreToken;
    IERC20 public coreDao;
    IUniswapV2Pair public coreWethPair;
    IUniswapV2Pair public daiWethPair;
    IERC3156FlashLender public flashLender;

    ClendingLiquidatorWallet public wallet; // typed handle to code at BORROWER
    uint256 public minProfitDai = 0; // configurable in test

    function setUp() public {
        // 1. Select mainnet fork
        //    You must export MAINNET_RPC_URL in your environment, e.g.:
        //    export MAINNET_RPC_URL="https://mainnet.infura.io/v3/..."
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // 2. Bind on-chain contracts
        dai = clending.DAI();
        coreToken = clending.CORE_TOKEN();
        coreDao = clending.coreDAO();
        coreWethPair = IUniswapV2Pair(CORE_WETH_PAIR);
        daiWethPair = IUniswapV2Pair(DAI_WETH_PAIR);

        // Sanity checks to ensure the fork matches expectations.
        require(address(dai) == MAINNET_DAI, "Clending DAI != mainnet DAI");
        require(address(coreToken) == CORE_TOKEN_ADDR, "CORE_TOKEN mismatch");

        // CORE/WETH pair sanity
        address c0 = coreWethPair.token0();
        address c1 = coreWethPair.token1();
        require(
            (c0 == address(coreToken) && c1 == MAINNET_WETH) ||
                (c0 == MAINNET_WETH && c1 == address(coreToken)),
            "CORE/WETH pair tokens mismatch"
        );

        // DAI/WETH pair sanity
        address d0 = daiWethPair.token0();
        address d1 = daiWethPair.token1();
        require(
            (d0 == address(dai) && d1 == MAINNET_WETH) ||
                (d0 == MAINNET_WETH && d1 == address(dai)),
            "DAI/WETH pair tokens mismatch"
        );

        // 3. Configure Maker flash mint module as the IERC3156 lender.
        //    You must export the flash module address as:
        //    export MAKER_FLASH="0x...flash-module-address..."
        address makerFlash = vm.envAddress("MAKER_FLASH");
        flashLender = IERC3156FlashLender(makerFlash);

        // 4. Ensure the target borrower actually has debt on Clending.
        uint256 debt = clending.userTotalDebt(BORROWER);
        require(debt > 0, "BORROWER has no debt on Clending");

        // 5. Deploy an implementation with correct immutables, then
        //    attach its runtime code to the BORROWER address to simulate
        //    EIP-7702 (EOA -> smart wallet) for that account.
        ClendingLiquidatorWallet impl =
            new ClendingLiquidatorWallet(address(flashLender), CLENDING, CORE_WETH_PAIR, DAI_WETH_PAIR);

        // Copy the implementation's runtime code to the BORROWER account.
        bytes memory code = address(impl).code;
        vm.etch(BORROWER, code);

        // Treat BORROWER as a ClendingLiquidatorWallet instance.
        wallet = ClendingLiquidatorWallet(payable(BORROWER));

        // Initialize storage for the wallet at BORROWER (set owner = BORROWER).
        vm.prank(BORROWER);
        wallet.initialize(BORROWER);
    }

    function test_flashRepayAndReclaim_onFork() public {
        // Read current total debt for the borrower from Clending.
        uint256 debt = clending.userTotalDebt(BORROWER);
        assertGt(debt, 0, "no debt to repay");

        uint256 daiBefore = dai.balanceOf(BORROWER);

        // Simulate the borrower sending the 7702 transaction:
        // the borrower address (BORROWER) is now running the liquidator code.
        vm.prank(BORROWER);
        wallet.flashRepayAndReclaim(debt, minProfitDai);

        uint256 daiAfter = dai.balanceOf(BORROWER);

        // Borrower should not end up with less DAI than before (ideally more).
        assertGe(daiAfter, daiBefore, "borrower lost DAI");
    }
}


