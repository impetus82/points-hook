// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract DeployPointsHook is Script {
    // Unichain mainnet PoolManager
    address constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        // Mine valid hook address
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            type(PointsHook).creationCode,
            abi.encode(POOL_MANAGER)
        );

        console.log("Mined hook address:", hookAddress);

        vm.startBroadcast(privateKey);

        PointsHook hook = new PointsHook{salt: salt}(
            IPoolManager(POOL_MANAGER)
        );

        require(address(hook) == hookAddress, "Address mismatch");
        console.log("PointsHook deployed:", address(hook));

        vm.stopBroadcast();
    }
}
