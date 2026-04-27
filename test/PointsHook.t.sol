// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PointsHook} from "../src/PointsHook.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract PointsHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PointsHook hook;
    PoolKey poolKey;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Деплоим PoolManager + все стандартные роутеры
        deployFreshManagerAndRouters();

        // 2. deployCodeTo: деплоим хук на валидный адрес без HookMiner
        //    Адрес определяется флагами — afterSwap = бит 7 (0x0080)
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);

        deployCodeTo(
            "PointsHook.sol",          // путь к контракту
            abi.encode(manager),       // аргументы конструктора
            hookAddress                // целевой адрес
        );
        hook = PointsHook(hookAddress);

        // 3. Деплоим ETH + ERC20, минтим токены себе
        //    ETH = currency0 (address(0)), token = currency1
        deployMintAndApprove2Currencies();

        // 4. Инициализируем ETH/Token пул с нашим хуком
        //    sqrtPriceX96 1:1
        (poolKey, poolId) = initPool(
            Currency.wrap(address(0)),  // ETH = currency0
            currency1,
            hook,
            3000,   // fee 0.3%
            SQRT_PRICE_1_1
        );

        // 5. Добавляем ликвидность
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper:  60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            abi.encode(address(this))
        );

        // 6. Фондируем тестовых юзеров
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Делаем своп ETH→Token через наш хук
    function _swapEthForToken(
        address user,
        uint256 ethAmount,
        bytes memory hookData
    ) internal returns (int256 delta0, int256 delta1) {
        vm.prank(user);
        swapRouter.swap{value: ethAmount}(
            poolKey,
            SwapParams({
                zeroForOne:        true,
                amountSpecified:   -int256(ethAmount), // exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Делаем своп Token→ETH (обратное направление)
    function _swapTokenForEth(
        address user,
        uint256 tokenAmount,
        bytes memory hookData
    ) internal {
        // Апрувим токен роутеру от имени user
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), tokenAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne:        false,
                amountSpecified:   -int256(tokenAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    // ─── Unit Tests ───────────────────────────────────────────────────────────

    /// @notice Хук должен вернуть только AFTER_SWAP_FLAG = true
    function test_getHookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertTrue(perms.afterSwap,           "afterSwap must be enabled");
        assertFalse(perms.beforeSwap,         "beforeSwap must be disabled");
        assertFalse(perms.beforeInitialize,   "beforeInitialize must be disabled");
        assertFalse(perms.afterInitialize,    "afterInitialize must be disabled");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity must be disabled");
    }

    // ─── Swap Success Tests ───────────────────────────────────────────────────

    /// @notice ETH→Token своп начисляет 20% points получателю
    function test_swapSuccess_receivesPoints() public {
        uint256 ethAmount = 0.001 ether;
        bytes memory hookData = abi.encode(alice);

        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(alice, tokenId);
        assertEq(balanceBefore, 0, "points balance should start at zero");

        _swapEthForToken(alice, ethAmount, hookData);

        uint256 balanceAfter = hook.balanceOf(alice, tokenId);
        uint256 expectedPoints = ethAmount / 5; // 20%

        // Используем approxEq: свап с fees может дать чуть меньше
        assertApproxEqRel(
            balanceAfter - balanceBefore,
            expectedPoints,
            0.01e18, // 1% допуск
            "points should equal 20% of ETH spent"
        );
    }

    /// @notice Token→ETH своп НЕ начисляет points (zeroForOne = false)
    function test_swapTokenForEth_noPoints() public {
        uint256 tokenAmount = 1e18;
        bytes memory hookData = abi.encode(alice);

        // Фондируем alice токеном
        deal(Currency.unwrap(currency1), alice, tokenAmount);

        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(alice, tokenId);

        _swapTokenForEth(alice, tokenAmount, hookData);

        uint256 balanceAfter = hook.balanceOf(alice, tokenId);
        assertEq(balanceAfter, balanceBefore, "reverse swap must not grant points");
    }

    /// @notice Если hookData пустые — points не начисляются
    function test_emptyHookData_noPoints() public {
        uint256 ethAmount = 0.001 ether;
        bytes memory hookData = ""; // пустые hookData

        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(alice, tokenId);

        _swapEthForToken(alice, ethAmount, hookData);

        uint256 balanceAfter = hook.balanceOf(alice, tokenId);
        assertEq(balanceAfter, balanceBefore, "empty hookData must not grant points");
    }

    /// @notice Если получатель address(0) — points не начисляются
    function test_zeroAddressRecipient_noPoints() public {
        uint256 ethAmount = 0.001 ether;
        bytes memory hookData = abi.encode(address(0));

        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(alice, tokenId);

        _swapEthForToken(alice, ethAmount, hookData);

        uint256 balanceAfter = hook.balanceOf(alice, tokenId);
        assertEq(balanceAfter, balanceBefore, "zero address must not receive points");
    }

    /// @notice Пылевой своп (< 5 wei) округляется до 0 points
    function test_dustSwap_zeroPoints() public {
        uint256 ethAmount = 4; // 4 wei → 20% = 0.8 → floor = 0
        bytes memory hookData = abi.encode(alice);
        vm.deal(alice, 1 ether);

        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(alice, tokenId);

        _swapEthForToken(alice, ethAmount, hookData);

        uint256 balanceAfter = hook.balanceOf(alice, tokenId);
        assertEq(balanceAfter, balanceBefore, "dust swap must yield zero points");
    }

    /// @notice Points начисляются третьей стороне, а не msg.sender
    function test_pointsGoToSpecifiedRecipient_notSender() public {
        uint256 ethAmount = 0.001 ether;
        // alice делает своп, но points идут bob
        bytes memory hookData = abi.encode(bob);

        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 aliceBefore = hook.balanceOf(alice, tokenId);
        uint256 bobBefore   = hook.balanceOf(bob,   tokenId);

        _swapEthForToken(alice, ethAmount, hookData);

        assertEq(hook.balanceOf(alice, tokenId), aliceBefore, "alice must not receive points");
        assertGt(hook.balanceOf(bob,   tokenId), bobBefore,   "bob must receive points");
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    /// @notice Fuzz: любой ETH amount генерирует корректное количество points
    function testFuzz_pointsProportionalToEth(
        address recipient,
        uint256 ethAmount
    ) public {
        // Ограничения:
        vm.assume(recipient != address(0));
        vm.assume(recipient.code.length == 0); // только EOA (нет ERC1155Receiver)
        vm.assume(uint160(recipient) > 256); // exclude precompiles
        ethAmount = bound(ethAmount, 5, 0.1 ether); // 5 wei..0.1 ETH

        vm.deal(recipient, ethAmount + 0.01 ether);

        bytes memory hookData = abi.encode(recipient);
        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(recipient, tokenId);

        _swapEthForToken(recipient, ethAmount, hookData);

        uint256 balanceAfter = hook.balanceOf(recipient, tokenId);
        uint256 pointsReceived = balanceAfter - balanceBefore;
        uint256 expectedPoints = ethAmount / 5;

        // Points никогда не должны превышать 20% + 1% погрешность
        assertLe(pointsReceived, expectedPoints * 101 / 100, "points must not exceed 20% of eth");
    }

    /// @notice Fuzz: направление свопа определяет начисление points
    function testFuzz_noPointsForReverseSwap(
        address recipient,
        uint256 tokenAmount
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient.code.length == 0);
        vm.assume(uint160(recipient) > 256); // exclude precompiles
        tokenAmount = bound(tokenAmount, 1e15, 0.01 ether);

        deal(Currency.unwrap(currency1), recipient, tokenAmount);

        bytes memory hookData = abi.encode(recipient);
        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        uint256 balanceBefore = hook.balanceOf(recipient, tokenId);

        _swapTokenForEth(recipient, tokenAmount, hookData);

        assertEq(
            hook.balanceOf(recipient, tokenId),
            balanceBefore,
            "token->eth swap must never grant points"
        );
    }

    // ─── Fork Test (демо) ─────────────────────────────────────────────────────

    /// @notice Fork test: подключаемся к Base mainnet и читаем состояние нашего LimitOrderHook
    /// @dev Запускать только локально: forge test --match-test test_fork_baseLimitOrderHook --fork-url $BASE_RPC_URL
    function test_fork_baseLimitOrderHook() public {
        // Этот тест пропускается в CI (нет RPC)
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // Наш LimitOrderHook на Base mainnet
        address hookAddr = 0x45d971BdE51dd5E109036aB70a4E0b0eD2Dc4040;

        // Проверяем что контракт существует
        assertGt(hookAddr.code.length, 0, "LimitOrderHook must be deployed");
        console2.log("LimitOrderHook code size:", hookAddr.code.length);
    }
}