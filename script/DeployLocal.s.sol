// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AgentWallet} from "../src/AgentWallet.sol";
import {AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {IAgentWallet} from "../src/interfaces/IAgentWallet.sol";
import {IEntryPoint} from "../src/interfaces/IEntryPoint.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Local demo setup on anvil: deploys an EntryPoint v0.7.0, the factory and a test token, then has
/// the owner create an account, fund it and grant the agent a session key. Writes the addresses to
/// deployments/local.json for agent/demo.ts.
/// @dev Uses anvil's well-known dev keys. Never point this at a real network.
contract DeployLocal is Script {
    // anvil accounts 0-2 and 5.
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant OWNER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant GUARDIAN_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant AGENT_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    bytes4 internal constant TRANSFER = 0xa9059cbb;
    bytes4 internal constant APPROVE = 0x095ea7b3;

    function run() external {
        require(block.chainid == 31_337, "local anvil only");

        address owner = vm.addr(OWNER_PK);
        address guardian = vm.addr(GUARDIAN_PK);
        address agent = vm.addr(AGENT_PK);
        address vendor = makeAddr("vendor");

        vm.startBroadcast(DEPLOYER_PK);
        // Read from the artifact on disk: `forge script` only compiles the script's own imports, and the
        // EntryPoint is compiled by the full `forge build` via test/utils/EntryPointArtifact.sol.
        IEntryPoint entryPoint = IEntryPoint(vm.deployCode("out/EntryPoint.sol/EntryPoint.json"));
        AgentWalletFactory factory = new AgentWalletFactory(entryPoint);
        MockERC20 token = new MockERC20("Test USD", "TUSD");
        vm.stopBroadcast();

        vm.startBroadcast(OWNER_PK);
        AgentWallet account = factory.createAccount(owner, guardian, bytes32(0));
        (bool ok,) = address(account).call{value: 1 ether}("");
        require(ok, "fund failed");
        token.mint(address(account), 1000e18);
        account.addSession(_policy(agent, address(token), vendor));
        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeAddress(json, "entryPoint", address(entryPoint));
        vm.serializeAddress(json, "factory", address(factory));
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "account", address(account));
        vm.serializeAddress(json, "owner", owner);
        vm.serializeAddress(json, "guardian", guardian);
        vm.serializeAddress(json, "agent", agent);
        string memory out = vm.serializeAddress(json, "vendor", vendor);
        vm.createDir("deployments", true);
        vm.writeJson(out, "deployments/local.json");

        console.log("EntryPoint  ", address(entryPoint));
        console.log("Factory     ", address(factory));
        console.log("Token       ", address(token));
        console.log("AgentWallet ", address(account));
        console.log("Session key ", agent);
    }

    /// @dev 100 TUSD per day via transfer/approve, 0.1 ETH per day to the vendor, 20 calls, 0.05 ETH of gas,
    /// valid for a week.
    function _policy(address agent, address token, address vendor)
        internal
        view
        returns (IAgentWallet.SessionParams memory p)
    {
        p.key = agent;
        p.validAfter = uint48(block.timestamp);
        p.validUntil = uint48(block.timestamp + 7 days);
        p.maxCalls = 20;
        p.maxValuePerCall = 0.1 ether;
        p.gasBudget = 0.05 ether;

        p.permissions = new IAgentWallet.Permission[](2);
        p.permissions[0].target = token;
        p.permissions[0].selectors = new bytes4[](2);
        p.permissions[0].selectors[0] = TRANSFER;
        p.permissions[0].selectors[1] = APPROVE;
        p.permissions[1].target = vendor;
        p.permissions[1].selectors = new bytes4[](1);

        p.spendLimits = new IAgentWallet.SpendLimit[](2);
        p.spendLimits[0] = IAgentWallet.SpendLimit({token: token, limit: 100e18, period: 1 days});
        p.spendLimits[1] = IAgentWallet.SpendLimit({token: address(0), limit: 0.1 ether, period: 1 days});
    }
}
