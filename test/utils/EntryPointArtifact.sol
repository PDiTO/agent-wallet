// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

// Pulls the EntryPoint v0.7.0 sources into the build so tests and scripts can deploy it with
// `vm.deployCode`. This file is GPL-3.0 because it imports GPL-3.0 code. Nothing else in the repository
// imports it; everything else talks to the EntryPoint through the MIT interface in src/interfaces.
// forge-lint: disable-next-line(unused-import)
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
