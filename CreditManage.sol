// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IInterestRateModel {
    function calculateAccruedInterest(
        uint256 principal,
        uint256 borrowTimestamp
    ) external view returns (uint256);
    function getAnnualRate() external view returns (uint256);
    function isGracePeriodEnded(
        uint256 borrowTimestamp
    ) external view returns (bool);
}

interface ILendingPool {
    function borrow(address borrower, uint256 amount) external;
    function repay(
        address borrower,
        uint256 principal,
        uint256 interest
    ) external;
    function getAvailableLiquidity() external view returns (uint256);
}

interface ICollateralVault {
    function depositCollateral(address borrower, uint256 amount) external;
    function withdrawCollateral(address borrower, uint256 amount) external;
    function getCollateralBalance(
        address borrower
    ) external view returns (uint256);
    function liquidateCollateral(address borrower, uint256 amount) external;
}

interface IReputationManager {
    function getReputationScore(
        address borrower
    ) external view returns (uint256);
    function updateReputation(
        address borrower,
        bool isPositive,
        uint256 amount
    ) external;
}

contract CreditManager is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant GRACE_PERIOD = 30 days;
    uint256 public constant MAX_LTV = 10000;
    uint256 public constant LIQUIDATION_THRESHOLD = 11000;

    uint256 public fixedInterestRate = 1500; 
    uint256 public reputationThreshold = 750; 
    uint256 public creditIncreaseMultiplier = 1200;

    ILendingPool public lendingPool;
    ICollateralVault public collateralVault;
    IReputationManager public reputationManager;
    IInterestRateModel public interestRateModel;
    IERC20 public collateralToken;

    struct CreditLine {
        uint256 collateralDeposited;
        uint256 creditLimit;
        uint256 borrowedAmount;
        uint256 lastBorrowedTimestamp;
        uint256 interestAccrued;
        uint256 lastInterestUpdate;
        uint256 repaymentDueDate;
        bool isActive;
        uint256 totalRepaid;
        uint256 onTimeRepayments;
        uint256 lateRepayments;
    }

    mapping(address => CreditLine) public creditLines;
    address[] public borrowersList;
    mapping(address => bool) private borrowerExists;

    event CreditOpened(
        address indexed borrower,
        uint256 collateralAmount,
        uint256 creditLimit,
        uint256 timestamp
    );

    event Borrowed(
        address indexed borrower,
        uint256 amount,
        uint256 totalBorrowed,
        uint256 dueDate,
        uint256 timestamp
    );

    event Repaid(
        address indexed borrower,
        uint256 principalAmount,
        uint256 interestAmount,
        uint256 remainingBalance,
        uint256 timestamp
    );

    event Liquidated(
        address indexed borrower,
        uint256 collateralLiquidated,
        uint256 debtCleared,
        string reason,
        uint256 timestamp
    );

    event CreditLimitIncreased(
        address indexed borrower,
        uint256 oldLimit,
        uint256 newLimit,
        uint256 reputationScore,
        uint256 timestamp
    );

    modifier creditExists(address borrower) {
        require(creditLines[borrower].isActive, "Credit line not active");
        _;
    }

    modifier updateInterest(address borrower) {
        _updateInterest(borrower);
        _;
    }

    function initialize(
        address _lendingPool,
        address _collateralVault,
        address _reputationManager,
        address _interestRateModel,
        address _collateralToken,
        address _owner
    ) public initializer {
        require(_lendingPool != address(0), "Invalid lending pool");
        require(_collateralVault != address(0), "Invalid collateral vault");
        require(_reputationManager != address(0), "Invalid reputation manager");
        require(
            _interestRateModel != address(0),
            "Invalid interest rate model"
        );
        require(_collateralToken != address(0), "Invalid collateral token");
        require(_owner != address(0), "Invalid owner");

        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        lendingPool = ILendingPool(_lendingPool);
        collateralVault = ICollateralVault(_collateralVault);
        reputationManager = IReputationManager(_reputationManager);
        interestRateModel = IInterestRateModel(_interestRateModel);
        collateralToken = IERC20(_collateralToken);
    }

    function openCreditLine(
        uint256 collateralAmount
    ) external nonReentrant whenNotPaused {
        require(collateralAmount > 0, "Invalid collateral amount");
        require(
            !creditLines[msg.sender].isActive,
            "Credit line already exists"
        );

        collateralToken.safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        collateralToken.safeIncreaseAllowance(
            address(collateralVault),
            collateralAmount
        );
        collateralVault.depositCollateral(msg.sender, collateralAmount);

        uint256 creditLimit = collateralAmount;

        creditLines[msg.sender] = CreditLine({
            collateralDeposited: collateralAmount,
            creditLimit: creditLimit,
            borrowedAmount: 0,
            lastBorrowedTimestamp: 0,
            interestAccrued: 0,
            lastInterestUpdate: block.timestamp,
            repaymentDueDate: 0,
            isActive: true,
            totalRepaid: 0,
            onTimeRepayments: 0,
            lateRepayments: 0
        });

        if (!borrowerExists[msg.sender]) {
            borrowersList.push(msg.sender);
            borrowerExists[msg.sender] = true;
        }

        emit CreditOpened(
            msg.sender,
            collateralAmount,
            creditLimit,
            block.timestamp
        );
    }

    function addCollateral(
        uint256 collateralAmount
    ) external nonReentrant whenNotPaused creditExists(msg.sender) {
        require(collateralAmount > 0, "Invalid amount");

        collateralToken.safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        collateralToken.safeIncreaseAllowance(
            address(collateralVault),
            collateralAmount
        );
        collateralVault.depositCollateral(msg.sender, collateralAmount);

        CreditLine storage credit = creditLines[msg.sender];
        credit.collateralDeposited += collateralAmount;
        credit.creditLimit += collateralAmount;
    }

    function borrow(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        creditExists(msg.sender)
        updateInterest(msg.sender)
    {
        require(amount > 0, "Invalid amount");

        CreditLine storage credit = creditLines[msg.sender];
        uint256 totalDebt = credit.borrowedAmount + credit.interestAccrued;

        require(
            totalDebt + amount <= credit.creditLimit,
            "Exceeds credit limit"
        );
        require(
            lendingPool.getAvailableLiquidity() >= amount,
            "Insufficient liquidity"
        );

        credit.borrowedAmount += amount;
        credit.lastBorrowedTimestamp = block.timestamp;
        credit.repaymentDueDate = block.timestamp + GRACE_PERIOD + 30 days;

        lendingPool.borrow(msg.sender, amount);

        emit Borrowed(
            msg.sender,
            amount,
            credit.borrowedAmount,
            credit.repaymentDueDate,
            block.timestamp
        );
    }

    function repay(
        uint256 principalAmount,
        uint256 interestAmount
    )
        external
        nonReentrant
        whenNotPaused
        creditExists(msg.sender)
        updateInterest(msg.sender)
    {
        require(principalAmount > 0 || interestAmount > 0, "Invalid amounts");

        CreditLine storage credit = creditLines[msg.sender];
        require(
            principalAmount <= credit.borrowedAmount,
            "Exceeds borrowed amount"
        );
        require(interestAmount <= credit.interestAccrued, "Exceeds interest");

        uint256 totalRepayment = principalAmount + interestAmount;
        collateralToken.safeTransferFrom(
            msg.sender,
            address(this),
            totalRepayment
        );
        collateralToken.safeIncreaseAllowance(
            address(lendingPool),
            totalRepayment
        );

        lendingPool.repay(msg.sender, principalAmount, interestAmount);

        credit.borrowedAmount -= principalAmount;
        credit.interestAccrued -= interestAmount;
        credit.totalRepaid += totalRepayment;

        bool isOnTime = block.timestamp <= credit.repaymentDueDate;
        if (isOnTime) {
            credit.onTimeRepayments++;
        } else {
            credit.lateRepayments++;
        }

        reputationManager.updateReputation(
            msg.sender,
            isOnTime,
            totalRepayment
        );
        _checkCreditLimitIncrease(msg.sender);

        emit Repaid(
            msg.sender,
            principalAmount,
            interestAmount,
            credit.borrowedAmount,
            block.timestamp
        );
    }

    function liquidate(
        address borrower
    )
        external
        onlyOwner
        nonReentrant
        creditExists(borrower)
        updateInterest(borrower)
    {
        CreditLine storage credit = creditLines[borrower];

        bool isOverLTV = _isOverLTV(borrower);
        bool isOverdue = _isOverdue(borrower);
        require(isOverLTV || isOverdue, "Liquidation not allowed");

        uint256 totalDebt = credit.borrowedAmount + credit.interestAccrued;
        uint256 collateralToLiquidate = Math.min(
            totalDebt,
            credit.collateralDeposited
        );

        collateralVault.liquidateCollateral(borrower, collateralToLiquidate);

        credit.borrowedAmount = 0;
        credit.interestAccrued = 0;
        credit.collateralDeposited -= collateralToLiquidate;

        reputationManager.updateReputation(borrower, false, totalDebt);

        if (credit.collateralDeposited == 0) {
            credit.isActive = false;
        }

        string memory reason = isOverLTV ? "Over LTV" : "Overdue";
        emit Liquidated(
            borrower,
            collateralToLiquidate,
            totalDebt,
            reason,
            block.timestamp
        );
    }

    function getCreditInfo(
        address borrower
    )
        external
        view
        returns (
            uint256 collateralDeposited,
            uint256 creditLimit,
            uint256 borrowedAmount,
            uint256 interestAccrued,
            uint256 totalDebt,
            uint256 repaymentDueDate,
            bool isActive
        )
    {
        CreditLine memory credit = creditLines[borrower];
        uint256 currentInterest = _calculateInterest(borrower);
        uint256 totalInterest = credit.interestAccrued + currentInterest;

        return (
            credit.collateralDeposited,
            credit.creditLimit,
            credit.borrowedAmount,
            totalInterest,
            credit.borrowedAmount + totalInterest,
            credit.repaymentDueDate,
            credit.isActive
        );
    }

    function getRepaymentHistory(
        address borrower
    )
        external
        view
        returns (
            uint256 onTimeRepayments,
            uint256 lateRepayments,
            uint256 totalRepaid
        )
    {
        CreditLine memory credit = creditLines[borrower];
        return (
            credit.onTimeRepayments,
            credit.lateRepayments,
            credit.totalRepaid
        );
    }

    function checkCreditIncreaseEligibility(
        address borrower
    ) external view returns (bool eligible, uint256 newLimit) {
        CreditLine memory credit = creditLines[borrower];
        if (!credit.isActive) return (false, 0);

        uint256 reputationScore = reputationManager.getReputationScore(
            borrower
        );
        bool hasGoodReputation = reputationScore >= reputationThreshold;
        bool hasRepaymentHistory = credit.onTimeRepayments > 0;
        bool noCurrentDebt = credit.borrowedAmount == 0;

        eligible = hasGoodReputation && hasRepaymentHistory && noCurrentDebt;
        newLimit = eligible
            ? (credit.creditLimit * creditIncreaseMultiplier) / BASIS_POINTS
            : 0;

        return (eligible, newLimit);
    }

    function getAllBorrowers() external view returns (address[] memory) {
        return borrowersList;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _updateInterest(address borrower) internal {
        CreditLine storage credit = creditLines[borrower];
        if (credit.borrowedAmount > 0 && credit.lastBorrowedTimestamp > 0) {
            uint256 newInterest = _calculateInterest(borrower);
            credit.interestAccrued += newInterest;
            credit.lastInterestUpdate = block.timestamp;
        }
    }

    function _calculateInterest(
        address borrower
    ) internal view returns (uint256) {
        CreditLine memory credit = creditLines[borrower];
        if (credit.borrowedAmount == 0 || credit.lastBorrowedTimestamp == 0) {
            return 0;
        }

        uint256 totalAccrued = interestRateModel.calculateAccruedInterest(
            credit.borrowedAmount,
            credit.lastBorrowedTimestamp
        );

        return
            totalAccrued > credit.interestAccrued
                ? totalAccrued - credit.interestAccrued
                : 0;
    }

    function _isOverLTV(address borrower) internal view returns (bool) {
        CreditLine memory credit = creditLines[borrower];
        if (credit.collateralDeposited == 0) return true;

        uint256 totalDebt = credit.borrowedAmount +
            _calculateInterest(borrower);
        uint256 currentLTV = (totalDebt * BASIS_POINTS) /
            credit.collateralDeposited;
        return currentLTV > LIQUIDATION_THRESHOLD;
    }

    function _isOverdue(address borrower) internal view returns (bool) {
        CreditLine memory credit = creditLines[borrower];
        return
            credit.borrowedAmount > 0 &&
            block.timestamp > credit.repaymentDueDate;
    }

    function _checkCreditLimitIncrease(address borrower) internal {
        (bool eligible, uint256 newLimit) = this.checkCreditIncreaseEligibility(
            borrower
        );
        if (eligible) {
            CreditLine storage credit = creditLines[borrower];
            uint256 oldLimit = credit.creditLimit;
            credit.creditLimit = newLimit;

            uint256 reputationScore = reputationManager.getReputationScore(
                borrower
            );
            emit CreditLimitIncreased(
                borrower,
                oldLimit,
                newLimit,
                reputationScore,
                block.timestamp
            );
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
