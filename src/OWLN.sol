// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Oneway Launch: fixed supply, minted once to the deploying factory.
contract OWLN is ERC20 {
    constructor() ERC20("Oneway Launch", "OWLN") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
