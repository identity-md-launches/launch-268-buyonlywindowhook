// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

library HookMiner {
    uint160 internal constant FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
    }

    function mine(address deployer, bytes32 initCodeHash) internal pure returns (bytes32 salt, address at) {
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            at = predict(deployer, salt, initCodeHash);
            if (uint160(at) & Hooks.ALL_HOOK_MASK == FLAGS) return (salt, at);
        }
        revert("salt search exhausted");
    }
}
