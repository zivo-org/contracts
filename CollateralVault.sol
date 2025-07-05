// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CollateralVault is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant CREDIT_MANAGER_ROLE =
        keccak256("CREDIT_MANAGER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    uint256 public constant BASIS_POINTS = 10000;

    enum CollateralStatus {
        Active,
        Locked,
        Liquidating
    }

    struct UserCollateral {
        uint256 amount;
        CollateralStatus status;
        uint256 lockedAmount;
        uint256 lastUpdateTimestamp;
    }

    mapping(address => UserCollateral) public userCollateral;
    address[] public usersList;
    mapping(address => bool) private userExists;

    uint256 public totalCollateral;
    address public usdcToken;
    address public creditManager;

    uint256 public collateralizationRatio = 15000;
    uint256 public liquidationThreshold = 12000;
    uint256 public maxCollateralAmount = 1000000 * 10 ** 6;

    event CollateralDeposited(
        address indexed user,
        uint256 amount,
        uint256 totalUserCollateral,
        uint256 timestamp
    );

    event CollateralWithdrawn(
        address indexed user,
        uint256 amount,
        uint256 remainingCollateral,
        uint256 timestamp
    );

    event CollateralLocked(
        address indexed user,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    event CollateralUnlocked(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event CollateralLiquidated(
        address indexed user,
        uint256 amount,
        address indexed liquidator,
        uint256 timestamp
    );

    event EmergencyWithdrawal(
        address indexed user,
        uint256 amount,
        address indexed admin,
        uint256 timestamp
    );

    modifier onlyCreditManager() {
        require(hasRole(CREDIT_MANAGER_ROLE, msg.sender), "Only CreditManager");
        _;
    }

    modifier onlyLiquidator() {
        require(
            hasRole(LIQUIDATOR_ROLE, msg.sender) ||
                hasRole(CREDIT_MANAGER_ROLE, msg.sender),
            "Only authorized liquidator"
        );
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than zero");
        _;
    }

    function initialize(
        address _owner,
        address _creditManager,
        address _usdcToken
    ) public initializer {
        require(_owner != address(0), "Invalid owner");
        require(_creditManager != address(0), "Invalid credit manager");
        require(_usdcToken != address(0), "Invalid USDC token");

        __Ownable_init(_owner);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CREDIT_MANAGER_ROLE, _creditManager);

        creditManager = _creditManager;
        usdcToken = _usdcToken;
    }

    function depositCollateral(
        address borrower,
        uint256 amount
    )
        external
        onlyCreditManager
        nonReentrant
        whenNotPaused
        validAmount(amount)
    {
        require(
            totalCollateral + amount <= maxCollateralAmount,
            "Exceeds max limit"
        );

        IERC20(usdcToken).safeTransferFrom(borrower, address(this), amount);

        UserCollateral storage collateral = userCollateral[borrower];
        collateral.amount += amount;
        collateral.lastUpdateTimestamp = block.timestamp;

        if (collateral.status == CollateralStatus.Liquidating) {
            collateral.status = CollateralStatus.Active;
        }

        totalCollateral += amount;

        if (!userExists[borrower]) {
            usersList.push(borrower);
            userExists[borrower] = true;
        }

        emit CollateralDeposited(
            borrower,
            amount,
            collateral.amount,
            block.timestamp
        );
    }

    function withdrawCollateral(
        address borrower,
        uint256 amount
    )
        external
        onlyCreditManager
        nonReentrant
        whenNotPaused
        validAmount(amount)
    {
        UserCollateral storage collateral = userCollateral[borrower];
        require(collateral.amount >= amount, "Insufficient collateral");

        collateral.amount -= amount;
        collateral.lastUpdateTimestamp = block.timestamp;
        totalCollateral -= amount;

        IERC20(usdcToken).safeTransfer(borrower, amount);

        if (collateral.amount == 0) {
            _removeUserFromList(borrower);
        }

        emit CollateralWithdrawn(
            borrower,
            amount,
            collateral.amount,
            block.timestamp
        );
    }

    function lockCollateral(
        address user,
        uint256 amount,
        string calldata reason
    ) external onlyCreditManager nonReentrant validAmount(amount) {
        UserCollateral storage collateral = userCollateral[user];
        require(collateral.amount >= amount, "Insufficient collateral to lock");
        require(
            collateral.amount - collateral.lockedAmount >= amount,
            "Not enough unlocked collateral"
        );

        collateral.lockedAmount += amount;
        collateral.status = CollateralStatus.Locked;
        collateral.lastUpdateTimestamp = block.timestamp;

        emit CollateralLocked(user, amount, reason, block.timestamp);
    }

    function unlockCollateral(
        address user,
        uint256 amount
    ) external onlyCreditManager nonReentrant validAmount(amount) {
        UserCollateral storage collateral = userCollateral[user];
        require(
            collateral.lockedAmount >= amount,
            "Not enough locked collateral"
        );

        collateral.lockedAmount -= amount;
        if (collateral.lockedAmount == 0) {
            collateral.status = CollateralStatus.Active;
        }
        collateral.lastUpdateTimestamp = block.timestamp;

        emit CollateralUnlocked(user, amount, block.timestamp);
    }

    function liquidateCollateral(
        address user,
        uint256 amount
    ) external onlyLiquidator nonReentrant validAmount(amount) {
        UserCollateral storage collateral = userCollateral[user];
        require(
            collateral.amount >= amount,
            "Insufficient collateral for liquidation"
        );

        collateral.amount -= amount;
        collateral.status = CollateralStatus.Liquidating;
        collateral.lastUpdateTimestamp = block.timestamp;
        totalCollateral -= amount;

        IERC20(usdcToken).safeTransfer(msg.sender, amount);

        if (collateral.amount == 0) {
            _removeUserFromList(user);
        }

        emit CollateralLiquidated(user, amount, msg.sender, block.timestamp);
    }

    function getCollateralBalance(
        address user
    ) external view returns (uint256) {
        return userCollateral[user].amount;
    }

    function getUserCollateral(
        address user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 lockedAmount,
            uint256 availableAmount,
            CollateralStatus status
        )
    {
        UserCollateral memory collateral = userCollateral[user];
        return (
            collateral.amount,
            collateral.lockedAmount,
            collateral.amount - collateral.lockedAmount,
            collateral.status
        );
    }

    function emergencyWithdraw(
        address user,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(paused(), "Contract must be paused");

        UserCollateral storage collateral = userCollateral[user];
        require(collateral.amount >= amount, "Insufficient collateral");

        collateral.amount -= amount;
        totalCollateral -= amount;

        IERC20(usdcToken).safeTransfer(user, amount);

        emit EmergencyWithdrawal(user, amount, msg.sender, block.timestamp);
    }

    function updateParameters(
        uint256 _collateralizationRatio,
        uint256 _liquidationThreshold,
        uint256 _maxCollateralAmount
    ) external onlyOwner {
        require(_collateralizationRatio <= BASIS_POINTS, "Invalid ratio");
        require(_liquidationThreshold <= BASIS_POINTS, "Invalid threshold");

        collateralizationRatio = _collateralizationRatio;
        liquidationThreshold = _liquidationThreshold;
        maxCollateralAmount = _maxCollateralAmount;
    }

    function getAllUsers() external view returns (address[] memory) {
        return usersList;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _removeUserFromList(address user) internal {
        if (!userExists[user]) return;

        for (uint256 i = 0; i < usersList.length; i++) {
            if (usersList[i] == user) {
                usersList[i] = usersList[usersList.length - 1];
                usersList.pop();
                userExists[user] = false;
                break;
            }
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
