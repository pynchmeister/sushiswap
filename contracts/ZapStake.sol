// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// ZapStake is the coolest bar in town. You come in with some GZap, and leave with more! The longer you stay, the more GZap you get.
//
// This contract handles swapping to and from xZap, ZSwap's staking token.
contract ZapStake is ERC20("ZapStake", "xZap"){
    using SafeMath for uint256;
    IERC20 public gzap;

    // Define the GZap token contract
    constructor(IERC20 _gzap) public {
        gzap = _gzap;
    }

    // Enter the bar. Pay some GZAPs. Earn some shares.
    // Locks GZap and mints xGZap
    function enter(uint256 _amount) public {
        // Gets the amount of GZap locked in the contract
        uint256 totalGZap = gzap.balanceOf(address(this));
        // Gets the amount of xZap in existence
        uint256 totalShares = totalSupply();
        // If no xZap exists, mint it 1:1 to the amount put in
        if (totalShares == 0 || totalGZap == 0) {
            _mint(msg.sender, _amount);
        } 
        // Calculate and mint the amount of xZap the GZap is worth. The ratio will change overtime, as xZap is burned/minted and GZap deposited + gained from fees / withdrawn.
        else {
            uint256 what = _amount.mul(totalShares).div(totalGZap);
            _mint(msg.sender, what);
        }
        // Lock the GZap in the contract
        gzap.transferFrom(msg.sender, address(this), _amount);
    }

    // Leave the bar. Claim back your GZAPs.
    // Unlocks the staked + gained GZap and burns xZap
    function leave(uint256 _share) public {
        // Gets the amount of xGZap in existence
        uint256 totalShares = totalSupply();
        // Calculates the amount of GZap the xGZap is worth
        uint256 what = _share.mul(gzap.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);
        gzap.transfer(msg.sender, what);
    }
}
