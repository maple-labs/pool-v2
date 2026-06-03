// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { MapleProxyFactory }  from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { MaplePoolDeployer }        from "../contracts/MaplePoolDeployer.sol";
import { MaplePoolManagerFactory }  from "../contracts/proxy/MaplePoolManagerFactory.sol";

import { IMaplePool }         from "../contracts/interfaces/IMaplePool.sol";
import { IMaplePoolDeployer } from "../contracts/interfaces/IMaplePoolDeployer.sol";
import { IMaplePoolManager }  from "../contracts/interfaces/IMaplePoolManager.sol";

import {
    MockFactory,
    MockGlobals,
    MockMigrator,
    MockPoolPermissionManager,
    MockProxied,
    MockStrategy
} from "./mocks/Mocks.sol";

import { TestBase } from "./utils/TestBase.sol";

contract MaplePoolDeployerConstructorTests is TestBase {

    function test_constructor_revert_zeroGlobals() external {
        vm.expectRevert("PD:C:ZERO_ADDRESS");
        new MaplePoolDeployer(address(0));
    }

}

contract PoolDeployerTestBase is TestBase {

    bytes32 strategySalt = keccak256("strategy-1");

    uint256 delegateManagementFeeRate = 0.1e6;  // 10% delegate fee
    uint256 liquidityCap              = 1_000_000e18;

    string poolName   = "Pool";
    string poolSymbol = "POOL";

    address PD = makeAddr("PD");

    address poolPermissionManager;
    address strategyFactory;
    address strategyManager;
    address strategyManagerFactory;
    address withdrawalManagerFactory;

    MockERC20               asset;
    MaplePoolManagerFactory factory;
    MaplePoolDeployer       poolDeployer;

    IMaplePoolDeployer.PoolManagerInitParams poolManagerInitParams;
    IMaplePoolDeployer.PoolConfigParams      poolConfigParams;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AT", 18);

        _deployAndBootstrapGlobals(address(asset), PD);

        factory = new MaplePoolManagerFactory(address(globals));

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, deploy("MaplePoolManager"), deploy("MaplePoolManagerInitializer"));
        factory.setDefaultVersion(1);
        vm.stopPrank();

        withdrawalManagerFactory = address(new MapleProxyFactory(globals));
        strategyFactory          = address(new MapleProxyFactory(globals));
        strategyManagerFactory   = address(new MockFactory());

        vm.startPrank(GOVERNOR);
        MapleProxyFactory(withdrawalManagerFactory).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
        MapleProxyFactory(withdrawalManagerFactory).setDefaultVersion(1);
        MapleProxyFactory(strategyFactory).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
        MapleProxyFactory(strategyFactory).setDefaultVersion(1);
        vm.stopPrank();

        strategyManager = address(new MockStrategy(address(0), address(0), address(0)));
        MockStrategy(strategyManager).__setFactory(strategyManagerFactory);
        MockStrategy(strategyManager).__setIsAssetSupported(address(asset), true);
        MockFactory(strategyManagerFactory).__setIsInstance(strategyManager, true);

        poolPermissionManager = address(new MockPoolPermissionManager());

        poolDeployer = new MaplePoolDeployer(globals);
        MockGlobals(globals).setValidPoolDeployer(address(poolDeployer), true);

        MockGlobals(globals).setValidInstance("POOL_MANAGER_FACTORY",             address(factory),         true);
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", withdrawalManagerFactory, true);
        MockGlobals(globals).setValidInstance("POOL_PERMISSION_MANAGER",          poolPermissionManager,    true);
        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY",                 strategyFactory,          true);
        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY",         strategyManagerFactory,   true);

        poolManagerInitParams = IMaplePoolDeployer.PoolManagerInitParams({
            asset:         address(asset),
            name:          poolName,
            symbol:        poolSymbol,
            initialSupply: 0
        });

        poolConfigParams = IMaplePoolDeployer.PoolConfigParams({
            poolPermissionManager:     poolPermissionManager,
            liquidityCap:              liquidityCap,
            delegateManagementFeeRate: delegateManagementFeeRate
        });
    }

    function _getExpectedPoolManagerAddress(uint256 initialSupply) internal view returns (address poolManager_) {
        ( poolManager_, ) = poolDeployer.getPoolDeploymentAddresses(
            address(factory), PD, address(asset), initialSupply, poolName, poolSymbol
        );
    }

    function _getExpectedPoolAddress(uint256 initialSupply) internal view returns (address pool_) {
        ( , pool_ ) = poolDeployer.getPoolDeploymentAddresses(
            address(factory), PD, address(asset), initialSupply, poolName, poolSymbol
        );
    }

    function _getExpectedWMAddress(address pool, address poolManager) internal view returns (address withdrawalManager_) {
        withdrawalManager_ = poolDeployer.getQueueWithdrawalManagerAddress(withdrawalManagerFactory, pool, poolManager);
    }

    function _getExpectedStrategyAddress(address poolManager, bytes32 salt) internal view returns (address strategy_) {
        address[] memory factories      = new address[](1);
        bytes[]   memory deploymentData = new bytes[](1);
        bytes32[] memory salts          = new bytes32[](1);

        factories[0]      = strategyFactory;
        deploymentData[0] = new bytes(0);
        salts[0]          = salt;

        address[] memory strategies = poolDeployer.getStrategiesAddresses(poolManager, factories, deploymentData, salts);

        strategy_ = strategies[0];
    }

    function _strategyParams(uint256 cap) internal view returns (IMaplePoolDeployer.StrategyDeployParams[] memory strategies_) {
        strategies_ = new IMaplePoolDeployer.StrategyDeployParams[](1);

        strategies_[0] = IMaplePoolDeployer.StrategyDeployParams({
            factory:        strategyFactory,
            deploymentData: new bytes(0),
            salt:           strategySalt,
            cap:            cap
        });
    }

    function _strategyManagerParams(uint256 cap)
        internal view returns (IMaplePoolDeployer.StrategyManagerParams[] memory strategyManagers_)
    {
        strategyManagers_ = new IMaplePoolDeployer.StrategyManagerParams[](1);

        strategyManagers_[0] = IMaplePoolDeployer.StrategyManagerParams({
            instance: strategyManager,
            cap:      cap
        });
    }

    function array(address a) internal pure returns (address[] memory arr_) {
        arr_    = new address[](1);
        arr_[0] = a;
    }

    function array(address a, address b) internal pure returns (address[] memory arr_) {
        arr_    = new address[](2);
        arr_[0] = a;
        arr_[1] = b;
    }

}

contract DeployPoolFailureTests is PoolDeployerTestBase {

    IMaplePoolDeployer.StrategyDeployParams[]  strategiesParams;
    IMaplePoolDeployer.StrategyManagerParams[] strategyManagersParams;

    function test_deployPool_revert_invalidPoolDelegate() external {
        MockGlobals(globals).setValidPoolDelegate(PD, false);

        vm.prank(PD);
        vm.expectRevert("PD:DP:INVALID_PD");
        poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            strategiesParams,
            strategyManagersParams
        );
    }

    function test_deployPool_revert_invalidPoolManagerFactory() external {
        MockGlobals(globals).setValidInstance("POOL_MANAGER_FACTORY", address(factory), false);

        vm.prank(PD);
        vm.expectRevert("PD:DP:INVALID_PM_FACTORY");
        poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            strategiesParams,
            strategyManagersParams
        );
    }

    function test_deployPool_revert_invalidWithdrawalManagerFactory() external {
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", withdrawalManagerFactory, false);

        vm.prank(PD);
        vm.expectRevert("PD:DP:INVALID_WM_FACTORY");
        poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            strategiesParams,
            strategyManagersParams
        );
    }

    function test_deployPool_revert_invalidPoolPermissionManager() external {
        MockGlobals(globals).setValidInstance("POOL_PERMISSION_MANAGER", poolPermissionManager, false);

        vm.prank(PD);
        vm.expectRevert("PD:DP:INVALID_PPM");
        poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            strategiesParams,
            strategyManagersParams
        );
    }

}

contract DeployPoolSuccessTests is PoolDeployerTestBase {

    function test_deployPool_success_emptyStrategiesAndManagers() external {
        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: 0 });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: 0 });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            new address[](0),
            new address[](0)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            new IMaplePoolDeployer.StrategyDeployParams[](0),
            new IMaplePoolDeployer.StrategyManagerParams[](0)
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);
        IMaplePool        pool        = IMaplePool(poolManager.pool());

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.poolDelegate(),              PD);
        assertEq(poolManager.asset(),                     address(asset));
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), delegateManagementFeeRate);
        assertEq(poolManager.poolPermissionManager(),     poolPermissionManager);
        assertEq(poolManager.strategyListLength(),        0);
        assertEq(poolManager.configured(),                true);

        assertEq(poolManager.pool(),              expectedPool);
        assertEq(poolManager.withdrawalManager(), expectedWithdrawalManager);

        assertEq(pool.manager(),     poolManagerAddress);
        assertEq(pool.asset(),       address(asset));
        assertEq(pool.name(),        poolName);
        assertEq(pool.symbol(),      poolSymbol);
        assertEq(pool.totalSupply(), 0);
    }

    function test_deployPool_success_withStrategiesAndManagers_noCaps() external {
        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: 0 });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: 0 });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });
        address expectedStrategy          = _getExpectedStrategyAddress({ poolManager: expectedPoolManager, salt: strategySalt });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            array(expectedStrategy),
            array(strategyManager)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            _strategyParams({ cap: 0 }),
            _strategyManagerParams({ cap: 0 })
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);
        IMaplePool        pool        = IMaplePool(poolManager.pool());

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.strategyListLength(),                  2);
        assertEq(poolManager.strategyList(0),                       expectedStrategy);
        assertEq(poolManager.strategyList(1),                       strategyManager);
        assertEq(poolManager.strategyCapOf(expectedStrategy),       0);
        assertEq(poolManager.strategyCapOf(strategyManager),        0);

        assertEq(poolManager.isStrategy(expectedStrategy),       true);
        assertEq(poolManager.isStrategyManager(strategyManager), true);
        assertEq(poolManager.configured(),                       true);

        assertEq(pool.manager(),     poolManagerAddress);
        assertEq(pool.asset(),       address(asset));
        assertEq(pool.name(),        poolName);
        assertEq(pool.symbol(),      poolSymbol);
        assertEq(pool.totalSupply(), 0);
    }

    function test_deployPool_success_withCaps() external {
        uint256 strategyCap        = 500_000e18;
        uint256 strategyManagerCap = 250_000e18;

        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: 0 });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: 0 });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });
        address expectedStrategy          = _getExpectedStrategyAddress({ poolManager: expectedPoolManager, salt: strategySalt });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            array(expectedStrategy),
            array(strategyManager)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            _strategyParams({ cap: strategyCap }),
            _strategyManagerParams({ cap: strategyManagerCap })
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);
        IMaplePool        pool        = IMaplePool(poolManager.pool());

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.poolDelegate(),              PD);
        assertEq(poolManager.asset(),                     address(asset));
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), delegateManagementFeeRate);
        assertEq(poolManager.poolPermissionManager(),     poolPermissionManager);

        assertEq(poolManager.strategyListLength(),            2);
        assertEq(poolManager.strategyList(0),                 expectedStrategy);
        assertEq(poolManager.strategyList(1),                 strategyManager);
        assertEq(poolManager.strategyCapOf(expectedStrategy), strategyCap);
        assertEq(poolManager.strategyCapOf(strategyManager),  strategyManagerCap);

        assertEq(poolManager.isStrategy(expectedStrategy),       true);
        assertEq(poolManager.isStrategyManager(strategyManager), true);
        assertEq(poolManager.configured(),                       true);

        assertEq(poolManager.pool(),              expectedPool);
        assertEq(poolManager.withdrawalManager(), expectedWithdrawalManager);

        assertEq(pool.manager(),     poolManagerAddress);
        assertEq(pool.asset(),       address(asset));
        assertEq(pool.name(),        poolName);
        assertEq(pool.symbol(),      poolSymbol);
        assertEq(pool.totalSupply(), 0);
    }

    function test_deployPool_success_withInitialSupply() external {
        uint256 initialSupply  = 100e18;
        address migrationAdmin = makeAddr("migrationAdmin");

        MockGlobals(globals).setMigrationAdmin(migrationAdmin);

        poolManagerInitParams.initialSupply = initialSupply;

        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: initialSupply });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: initialSupply });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            new address[](0),
            new address[](0)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            new IMaplePoolDeployer.StrategyDeployParams[](0),
            new IMaplePoolDeployer.StrategyManagerParams[](0)
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);
        IMaplePool        pool        = IMaplePool(poolManager.pool());

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.poolDelegate(),              PD);
        assertEq(poolManager.asset(),                     address(asset));
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), delegateManagementFeeRate);
        assertEq(poolManager.poolPermissionManager(),     poolPermissionManager);
        assertEq(poolManager.strategyListLength(),        0);
        assertEq(poolManager.configured(),                true);

        assertEq(poolManager.pool(),              expectedPool);
        assertEq(poolManager.withdrawalManager(), expectedWithdrawalManager);

        assertEq(pool.manager(),                 poolManagerAddress);
        assertEq(pool.asset(),                   address(asset));
        assertEq(pool.name(),                    poolName);
        assertEq(pool.symbol(),                  poolSymbol);
        assertEq(pool.totalSupply(),             initialSupply);
        assertEq(pool.balanceOf(migrationAdmin), initialSupply);
        assertEq(pool.balanceOf(PD),             0);
        assertEq(pool.balanceOf(address(0)),     0);
    }

    function test_deployPool_success_multipleStrategiesAndStrategyManagers() external {
        bytes32 strategySalt1 = keccak256("strategy-1");
        bytes32 strategySalt2 = keccak256("strategy-2");

        uint256 strategyCap1        = 0;
        uint256 strategyCap2        = 200e18;
        uint256 strategyManagerCap1 = 300e18;
        uint256 strategyManagerCap2 = 400e18;

        address strategyManager1 = address(new MockStrategy(address(0), address(0), address(0)));
        address strategyManager2 = address(new MockStrategy(address(0), address(0), address(0)));

        MockStrategy(strategyManager1).__setFactory(strategyManagerFactory);
        MockStrategy(strategyManager2).__setFactory(strategyManagerFactory);
        MockStrategy(strategyManager1).__setIsAssetSupported(address(asset), true);
        MockStrategy(strategyManager2).__setIsAssetSupported(address(asset), true);
        MockFactory(strategyManagerFactory).__setIsInstance(strategyManager1, true);
        MockFactory(strategyManagerFactory).__setIsInstance(strategyManager2, true);

        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: 0 });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: 0 });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });
        address expectedStrategy1         = _getExpectedStrategyAddress({ poolManager: expectedPoolManager, salt: strategySalt1 });
        address expectedStrategy2         = _getExpectedStrategyAddress({ poolManager: expectedPoolManager, salt: strategySalt2 });

        IMaplePoolDeployer.StrategyDeployParams[] memory strategies = new IMaplePoolDeployer.StrategyDeployParams[](2);

        strategies[0] = IMaplePoolDeployer.StrategyDeployParams({
            factory:        strategyFactory,
            deploymentData: new bytes(0),
            salt:           strategySalt1,
            cap:            strategyCap1
        });

        strategies[1] = IMaplePoolDeployer.StrategyDeployParams({
            factory:        strategyFactory,
            deploymentData: new bytes(0),
            salt:           strategySalt2,
            cap:            strategyCap2
        });

        IMaplePoolDeployer.StrategyManagerParams[] memory strategyManagers = new IMaplePoolDeployer.StrategyManagerParams[](2);

        strategyManagers[0] = IMaplePoolDeployer.StrategyManagerParams({ instance: strategyManager1, cap: strategyManagerCap1 });
        strategyManagers[1] = IMaplePoolDeployer.StrategyManagerParams({ instance: strategyManager2, cap: strategyManagerCap2 });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            array(expectedStrategy1, expectedStrategy2),
            array(strategyManager1,  strategyManager2)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            strategies,
            strategyManagers
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.poolDelegate(),              PD);
        assertEq(poolManager.asset(),                     address(asset));
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), delegateManagementFeeRate);
        assertEq(poolManager.poolPermissionManager(),     poolPermissionManager);
        assertEq(poolManager.configured(),                true);

        assertEq(poolManager.pool(),              expectedPool);
        assertEq(poolManager.withdrawalManager(), expectedWithdrawalManager);

        assertEq(poolManager.strategyListLength(), 4);
        assertEq(poolManager.strategyList(0),      expectedStrategy1);
        assertEq(poolManager.strategyList(1),      expectedStrategy2);
        assertEq(poolManager.strategyList(2),      strategyManager1);
        assertEq(poolManager.strategyList(3),      strategyManager2);

        assertEq(poolManager.strategyCapOf(expectedStrategy1), 0);
        assertEq(poolManager.strategyCapOf(expectedStrategy2), strategyCap2);
        assertEq(poolManager.strategyCapOf(strategyManager1),  strategyManagerCap1);
        assertEq(poolManager.strategyCapOf(strategyManager2),  strategyManagerCap2);

        assertEq(poolManager.isStrategy(expectedStrategy1),       true);
        assertEq(poolManager.isStrategy(expectedStrategy2),       true);
        assertEq(poolManager.isStrategyManager(strategyManager1), true);
        assertEq(poolManager.isStrategyManager(strategyManager2), true);

        IMaplePool pool = IMaplePool(poolManager.pool());

        assertEq(pool.manager(),     poolManagerAddress);
        assertEq(pool.asset(),       address(asset));
        assertEq(pool.name(),        poolName);
        assertEq(pool.symbol(),      poolSymbol);
        assertEq(pool.totalSupply(), 0);
    }

    function test_deployPool_success_onlyStrategy() external {
        uint256 strategyCap = 500_000e18;

        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: 0 });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: 0 });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });
        address expectedStrategy          = _getExpectedStrategyAddress({ poolManager: expectedPoolManager, salt: strategySalt });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            array(expectedStrategy),
            new address[](0)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            _strategyParams({ cap: strategyCap }),
            new IMaplePoolDeployer.StrategyManagerParams[](0)
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);
        IMaplePool        pool        = IMaplePool(poolManager.pool());

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.poolDelegate(),              PD);
        assertEq(poolManager.asset(),                     address(asset));
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), delegateManagementFeeRate);
        assertEq(poolManager.poolPermissionManager(),     poolPermissionManager);
        assertEq(poolManager.configured(),                true);

        assertEq(poolManager.pool(),              expectedPool);
        assertEq(poolManager.withdrawalManager(), expectedWithdrawalManager);

        assertEq(poolManager.strategyListLength(),            1);
        assertEq(poolManager.strategyList(0),                 expectedStrategy);
        assertEq(poolManager.strategyCapOf(expectedStrategy), strategyCap);
        assertEq(poolManager.isStrategy(expectedStrategy),    true);

        assertEq(pool.manager(),     poolManagerAddress);
        assertEq(pool.asset(),       address(asset));
        assertEq(pool.name(),        poolName);
        assertEq(pool.symbol(),      poolSymbol);
        assertEq(pool.totalSupply(), 0);
    }

    function test_deployPool_success_onlyStrategyManager() external {
        uint256 strategyManagerCap = 250_000e18;

        address expectedPoolManager       = _getExpectedPoolManagerAddress({ initialSupply: 0 });
        address expectedPool              = _getExpectedPoolAddress({ initialSupply: 0 });
        address expectedWithdrawalManager = _getExpectedWMAddress({ pool: expectedPool, poolManager: expectedPoolManager });

        vm.expectEmit();
        emit IMaplePoolDeployer.PoolDeployed(
            expectedPool,
            expectedPoolManager,
            expectedWithdrawalManager,
            new address[](0),
            array(strategyManager)
        );

        vm.prank(PD);
        address poolManagerAddress = poolDeployer.deployPool(
            address(factory),
            withdrawalManagerFactory,
            poolManagerInitParams,
            poolConfigParams,
            new IMaplePoolDeployer.StrategyDeployParams[](0),
            _strategyManagerParams({ cap: strategyManagerCap })
        );

        IMaplePoolManager poolManager = IMaplePoolManager(poolManagerAddress);
        IMaplePool        pool        = IMaplePool(poolManager.pool());

        assertEq(poolManagerAddress, expectedPoolManager);

        assertEq(poolManager.poolDelegate(),              PD);
        assertEq(poolManager.asset(),                     address(asset));
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), delegateManagementFeeRate);
        assertEq(poolManager.poolPermissionManager(),     poolPermissionManager);
        assertEq(poolManager.configured(),                true);

        assertEq(poolManager.pool(),              expectedPool);
        assertEq(poolManager.withdrawalManager(), expectedWithdrawalManager);

        assertEq(poolManager.strategyListLength(),               1);
        assertEq(poolManager.strategyList(0),                    strategyManager);
        assertEq(poolManager.strategyCapOf(strategyManager),     strategyManagerCap);
        assertEq(poolManager.isStrategyManager(strategyManager), true);

        assertEq(pool.manager(),     poolManagerAddress);
        assertEq(pool.asset(),       address(asset));
        assertEq(pool.name(),        poolName);
        assertEq(pool.symbol(),      poolSymbol);
        assertEq(pool.totalSupply(), 0);
    }

}
