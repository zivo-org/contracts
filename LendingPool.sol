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

contract LendingPool is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PROTOCOL_FEE_RATE = 1000; // 10%

    IERC20 public usdcToken;
    address public creditManager;

    uint256 public totalDeposited;
    uint256 public totalBorrowed;
    uint256 public totalRepaid;
    uint256 public protocolFeesCollected;

    struct LenderInfo {
        uint256 depositedAmount;
        uint256 earnedInterest;
        uint256 depositTimestamp;
    }

    mapping(address => LenderInfo) public lenders;
    address[] public lendersList;
    mapping(address => bool) private lenderExists;

    event Deposit(address indexed lender, uint256 amount, uint256 timestamp);
    event Withdraw(
        address indexed lender,
        uint256 amount,
        uint256 interest,
        uint256 timestamp
    );
    event Borrow(address indexed borrower, uint256 amount, uint256 timestamp);
    event Repay(
        address indexed borrower,
        uint256 principal,
        uint256 interest,
        uint256 timestamp
    );

    modifier onlyCreditManager() {
        require(msg.sender == creditManager, "Only CreditManager");
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
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        creditManager = _creditManager;
        usdcToken = IERC20(_usdcToken);
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        usdcToken.safeTransferFrom(msg.sender, address(this), amount);

        if (!lenderExists[msg.sender]) {
            lendersList.push(msg.sender);
            lenderExists[msg.sender] = true;
        }

        lenders[msg.sender].depositedAmount += amount;
        lenders[msg.sender].depositTimestamp = block.timestamp;
        totalDeposited += amount;

        emit Deposit(msg.sender, amount, block.timestamp);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        LenderInfo storage lender = lenders[msg.sender];
        require(lender.depositedAmount >= amount, "Insufficient balance");
        require(getAvailableLiquidity() >= amount, "Insufficient liquidity");

        lender.depositedAmount -= amount;
        totalDeposited -= amount;

        if (lender.depositedAmount == 0) {
            _removeLenderFromList(msg.sender);
        }

        usdcToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, 0, block.timestamp);
    }

    function borrow(
        address borrower,
        uint256 amount
    ) external onlyCreditManager nonReentrant {
        require(amount <= getAvailableLiquidity(), "Insufficient liquidity");

        totalBorrowed += amount;
        usdcToken.safeTransfer(borrower, amount);

        emit Borrow(borrower, amount, block.timestamp);
    }

    function repay(
        address borrower,
        uint256 principal,
        uint256 interest
    ) external onlyCreditManager nonReentrant {
        uint256 protocolFee = (interest * PROTOCOL_FEE_RATE) / BASIS_POINTS;
        uint256 lenderInterest = interest - protocolFee;

        totalRepaid += principal;
        protocolFeesCollected += protocolFee;

        if (lenderInterest > 0 && totalDeposited > 0) {
            _distributeInterest(lenderInterest);
        }

        usdcToken.safeTransferFrom(
            msg.sender,
            address(this),
            principal + interest
        );

        emit Repay(borrower, principal, interest, block.timestamp);
    }

    function getAvailableLiquidity() public view returns (uint256) {
        return usdcToken.balanceOf(address(this)) - protocolFeesCollected;
    }

    function getUtilizationRate() public view returns (uint256) {
        if (totalDeposited == 0) return 0;
        uint256 currentBorrowed = totalBorrowed > totalRepaid
            ? totalBorrowed - totalRepaid
            : 0;
        return (currentBorrowed * BASIS_POINTS) / totalDeposited;
    }

    function getLenderInfo(
        address lender
    )
        external
        view
        returns (
            uint256 depositedAmount,
            uint256 earnedInterest,
            uint256 depositTimestamp
        )
    {
        LenderInfo memory info = lenders[lender];
        return (
            info.depositedAmount,
            info.earnedInterest,
            info.depositTimestamp
        );
    }

    function updateCreditManager(address newCreditManager) external onlyOwner {
        require(newCreditManager != address(0), "Invalid address");
        creditManager = newCreditManager;
    }

    function withdrawProtocolFees(
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 withdrawAmount = amount == 0 ? protocolFeesCollected : amount;
        require(
            withdrawAmount <= protocolFeesCollected,
            "Exceeds available fees"
        );

        protocolFeesCollected -= withdrawAmount;
        usdcToken.safeTransfer(to, withdrawAmount);
    }

    function getAllLenders() external view returns (address[] memory) {
        return lendersList;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _distributeInterest(uint256 interestAmount) internal {
        for (uint256 i = 0; i < lendersList.length; i++) {
            address lenderAddr = lendersList[i];
            LenderInfo storage lender = lenders[lenderAddr];

            if (lender.depositedAmount > 0) {
                uint256 lenderShare = (lender.depositedAmount *
                    interestAmount) / totalDeposited;
                lender.earnedInterest += lenderShare;
            }
        }
    }

    function _removeLenderFromList(address lender) internal {
        if (!lenderExists[lender]) return;

        for (uint256 i = 0; i < lendersList.length; i++) {
            if (lendersList[i] == lender) {
                lendersList[i] = lendersList[lendersList.length - 1];
                lendersList.pop();
                lenderExists[lender] = false;
                break;
            }
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
