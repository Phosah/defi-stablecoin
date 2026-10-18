// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";

/// @notice DSC whose `transferFrom` returns false, to exercise DSCEngine's burn failure path.
contract MockFailedTransferFromDSC is DecentralizedStableCoin {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}
