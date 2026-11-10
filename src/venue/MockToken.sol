// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockToken
/// @notice A pretend token for the testnet demo. It has no value and stands in for a real tokenized
///         stock (or a dollar stablecoin). Authorised minters create it freely, which is how the demo
///         hands players play money without asking them to hold or approve anything.
contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    mapping(address => bool) public minters;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterSet(address indexed minter, bool allowed);

    error NotOwner();
    error NotMinter();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
        owner = msg.sender;
        minters[msg.sender] = true;
    }

    function setMinter(address minter, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        minters[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    function transferOwnership(address to) external {
        if (msg.sender != owner) revert NotOwner();
        owner = to;
    }

    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] -= amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
