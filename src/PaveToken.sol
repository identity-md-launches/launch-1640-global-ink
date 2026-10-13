// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title GLOBAL INK (PAVE)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`, which at launch is the IMD ProjectFactory). There is no owner, no
/// minter, no pause, no blacklist and no transfer fee: every transfer moves exactly what it says.
/// Holders may burn their own tokens, so the supply can only shrink after deployment.
/// @dev Self-contained implementation (no external library) so the deployed bytecode carries no
/// link placeholders. Follows the ERC-20 standard and emits the standard events. `approve` sets
/// an absolute allowance; use `increaseAllowance` / `decreaseAllowance` to adjust safely.
contract PaveToken {
    // ----------------------------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------------------------

    /// @notice The zero address was used where a real account is required.
    error ZeroAddress();
    /// @notice `account` holds `balance` but `needed` was required.
    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    /// @notice `spender` may spend `allowance` of `owner`'s tokens but `needed` was required.
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 needed);
    /// @notice `decreaseAllowance` would take the allowance below zero.
    error AllowanceBelowZero(address owner, address spender, uint256 allowance, uint256 requested);

    // ----------------------------------------------------------------------------------------
    // Events (ERC-20)
    // ----------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ----------------------------------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------------------------------

    /// @notice Token name, as requested.
    string public constant name = "GLOBAL INK";
    /// @notice Token symbol, as requested.
    string public constant symbol = "PAVE";
    /// @notice Token decimals, as requested.
    uint8 public constant decimals = 18;
    /// @notice The whole supply: 1,000,000,000 PAVE in minor units (18 decimals). Minted exactly
    /// once in the constructor; nothing can mint afterwards.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ----------------------------------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------------------------------

    /// @notice Current supply: `INITIAL_SUPPLY` minus everything burned.
    uint256 public totalSupply;
    /// @notice Balance of each account.
    mapping(address account => uint256) public balanceOf;
    /// @notice Remaining amount `spender` may transfer on behalf of `owner`.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ----------------------------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------------------------

    /// @notice Mints `INITIAL_SUPPLY` to the deployer. Takes no arguments and calls no contract.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ----------------------------------------------------------------------------------------
    // ERC-20
    // ----------------------------------------------------------------------------------------

    /// @notice Moves `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance. An allowance of
    /// `type(uint256).max` is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Raises the caller's allowance for `spender` by `addedValue`.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Lowers the caller's allowance for `spender` by `subtractedValue`.
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        if (current < subtractedValue) revert AllowanceBelowZero(msg.sender, spender, current, subtractedValue);
        unchecked {
            _approve(msg.sender, spender, current - subtractedValue);
        }
        return true;
    }

    // ----------------------------------------------------------------------------------------
    // Burn
    // ----------------------------------------------------------------------------------------

    /// @notice Destroys `amount` of the caller's own tokens, reducing `totalSupply`. Only the
    /// holder can burn its balance: there is no `burnFrom` and no privileged burn.
    function burn(uint256 amount) external {
        uint256 held = balanceOf[msg.sender];
        if (held < amount) revert InsufficientBalance(msg.sender, held, amount);
        unchecked {
            balanceOf[msg.sender] = held - amount;
            // held <= totalSupply always, so this cannot underflow.
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    // ----------------------------------------------------------------------------------------
    // Internals
    // ----------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 held = balanceOf[from];
        if (held < amount) revert InsufficientBalance(from, held, amount);
        unchecked {
            balanceOf[from] = held - amount;
            // The sum of all balances equals totalSupply <= INITIAL_SUPPLY, so no overflow.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(owner, spender, current, amount);
        unchecked {
            _approve(owner, spender, current - amount);
        }
    }
}
