/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity 0.7.3;
pragma experimental ABIEncoderV2;

import "./../../lib/dappsys/erc20.sol";
import "./../reputationMiningCycle/IReputationMiningCycle.sol";
import "./../colonyNetwork/IColonyNetwork.sol";
import "./ColonyExtensionMeta.sol";

// ignore-file-swc-108


contract ReputationBootstrapper is ColonyExtensionMeta {

  // Constants

  uint256 constant INT128_MAX = 2**127 - 1;
  uint256 constant SECURITY_DELAY = 1 hours;

  // Events

  event GrantSet(bytes32 hashedSecret, uint256 reputationAmount);
  event GrantClaimed(address recipient, uint256 reputationAmount, uint256 tokenAmount);

  // Data structures

  struct Grant {
    uint256 amount;
    uint256 timestamp;
  }

  // Storage

  address public token;
  bool public giveTokens;
  bool public isLocked;

  uint256 public decayPeriod;
  uint256 public decayNumerator;
  uint256 public decayDenominator;

  mapping (bytes32 => Grant) public grants;
  mapping (bytes32 => mapping (bytes32 => uint256)) public committedSecrets;

  // Modifiers

  modifier onlyRoot() {
    require(colony.hasUserRole(msgSender(), 1, ColonyDataTypes.ColonyRole.Root), "reputation-bootstrapper-caller-not-root");
    _;
  }

  modifier unlocked() {
    require(!isLocked, "reputation-bootstrapper-locked");
    _;
  }

  modifier locked() {
    require(isLocked, "reputation-bootstrapper-unlocked");
    _;
  }

  // Overrides

  /// @notice Returns the identifier of the extension
  function identifier() public override pure returns (bytes32) {
    return keccak256("ReputationBootstrapper");
  }

  /// @notice Returns the version of the extension
  function version() public override pure returns (uint256) {
    return 1;
  }

  /// @notice Configures the extension
  /// @param _colony The colony in which the extension holds permissions
  function install(address _colony) public override auth {
    require(address(colony) == address(0x0), "extension-already-installed");

    colony = IColony(_colony);
    token = colony.getToken();

    address colonyNetwork = colony.getColonyNetwork();
    address repCycle = IColonyNetwork(colonyNetwork).getReputationMiningCycle(false);
    decayPeriod = IReputationMiningCycle(repCycle).getMiningWindowDuration();
    (decayNumerator, decayDenominator) = IReputationMiningCycle(repCycle).getDecayConstant();
  }

  /// @notice Called when upgrading the extension
  function finishUpgrade() public override auth {}

  /// @notice Called when deprecating (or undeprecating) the extension
  function deprecate(bool _deprecated) public override auth {
    deprecated = _deprecated;
    isLocked = true;
  }

  /// @notice Called when uninstalling the extension
  function uninstall() public override auth {
    uint256 balance = ERC20(token).balanceOf(address(this));
    require(ERC20(token).transfer(address(colony), balance), "reputation-bootstrapper-transfer-failed");

    selfdestruct(address(uint160(address(colony))));
  }

  // Public

  /// @notice Lock the extension, allowing grants to the claimed and preventing new grants
  function lockExtension() public onlyRoot unlocked {
    isLocked = true;
  }

  /// @notice Configure whether or not reputation claims come with tokens
  /// @param _giveTokens A boolean setting the functionality to true or false
  function setGiveTokens(bool _giveTokens) public onlyRoot unlocked {
    giveTokens = _giveTokens;
  }

  /// @notice Set an arbitrary number of grants
  /// @param _hashedSecrets An array of (hashed) secrets
  /// @param _amounts An array of reputation amounts claimable by the secret
  function setGrants(bytes32[] memory _hashedSecrets, uint256[] memory _amounts) public onlyRoot unlocked {
    require(_hashedSecrets.length == _amounts.length, "reputation-bootstrapper-invalid-arguments");

    for (uint256 i; i < _hashedSecrets.length; i++) {
      require(_amounts[i] <= INT128_MAX, "reputation-bootstrapper-invalid-amount");
      grants[_hashedSecrets[i]] = Grant(_amounts[i], block.timestamp);

      emit GrantSet(_hashedSecrets[i], _amounts[i]);
    }
  }

  /// @notice Commit the secret, beginning the security delay window
  /// @param _committedSecret A sha256 hash of (userAddress, secret)
  function commitSecret(bytes32 _committedSecret) public locked {
    bytes32 addressHash = keccak256(abi.encodePacked(msgSender(), _committedSecret));
    committedSecrets[addressHash][_committedSecret] = block.timestamp;
  }

  /// @notice Claim the grant, after committing the secret and having the security delay elapse
  /// @param _secret The secret corresponding to a reputation grant
  function claimGrant(uint256 _secret) public locked {
    bytes32 committedSecret = keccak256(abi.encodePacked(msgSender(), _secret));
    bytes32 addressHash = keccak256(abi.encodePacked(msgSender(), committedSecret));
    uint256 commitTimestamp = committedSecrets[addressHash][committedSecret];

    require(
      commitTimestamp > 0 && commitTimestamp + SECURITY_DELAY <= block.timestamp,
      "reputation-bootstrapper-commit-window-unelapsed"
    );

    bytes32 hashedSecret = keccak256(abi.encodePacked(_secret));
    uint256 grantAmount = grants[hashedSecret].amount;
    uint256 tokenAmount = grants[hashedSecret].amount;
    uint256 grantTimestamp = grants[hashedSecret].timestamp + SECURITY_DELAY; // Don't decay during delay window

    require(grantAmount > 0, "reputation-bootstrapper-nothing-to-claim");

    delete grants[hashedSecret];

    uint256 decayEpochs = (block.timestamp - grantTimestamp) / decayPeriod;
    uint256 adjustedNumerator = decayNumerator;

    // This algorithm successively doubles the decay factor while halving the number of epochs
    // This allows us to perform the decay in O(log(n)) time
    // For example, a decay of 50 epochs would be applied as (k**2)(k**16)(k**32)
    while (decayEpochs > 0){
      // slither-disable-next-line weak-prng
      if (decayEpochs % 2 >= 1) {
        // slither-disable-next-line divide-before-multiply
        grantAmount = grantAmount * adjustedNumerator / decayDenominator;
      }
      // slither-disable-next-line divide-before-multiply
      adjustedNumerator = adjustedNumerator * adjustedNumerator / decayDenominator;
      decayEpochs >>= 1;
    }

    colony.emitDomainReputationReward(1, msgSender(), int256(grantAmount));

    if (giveTokens) {
      require(ERC20(token).transfer(msgSender(), tokenAmount), "reputation-bootstrapper-transfer-failed");
    }

    emit GrantClaimed(msgSender(), grantAmount, tokenAmount);
  }


}
