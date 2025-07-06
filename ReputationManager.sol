// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract ReputationManager is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;

    uint256 public constant MIN_SCORE = 0;
    uint256 public constant MAX_SCORE = 1000;
    uint256 public constant DEFAULT_SCORE = 500;
    uint256 public constant BRONZE_THRESHOLD = 300;
    uint256 public constant SILVER_THRESHOLD = 600;
    uint256 public constant GOLD_THRESHOLD = 850;

    bytes32 public constant CREDIT_MANAGER_ROLE =
        keccak256("CREDIT_MANAGER_ROLE");

    enum ReputationTier {
        Bronze,
        Silver,
        Gold,
        Platinum
    }

    struct ReputationData {
        uint256 score;
        uint256 lastUpdated;
        uint256 totalRepayments;
        uint256 onTimeRepayments;
        uint256 lateRepayments;
        uint256 defaults;
        ReputationTier tier;
        bool isInitialized;
    }

    mapping(address => ReputationData) public reputations;
    address[] public usersList;

    uint256 public onTimeBonus = 20;
    uint256 public latePaymentPenalty = 15;
    uint256 public defaultPenalty = 50;
    uint256 public maxScoreChange = 100;

    event ScoreUpdated(
        address indexed user,
        uint256 oldScore,
        uint256 newScore,
        bool isIncrease,
        string reason,
        uint256 timestamp
    );

    event TierChanged(
        address indexed user,
        ReputationTier oldTier,
        ReputationTier newTier,
        uint256 timestamp
    );

    event UserInitialized(
        address indexed user,
        uint256 initialScore,
        ReputationTier initialTier,
        uint256 timestamp
    );

    modifier onlyAuthorized() {
        require(
            hasRole(CREDIT_MANAGER_ROLE, msg.sender) || msg.sender == owner(),
            "Not authorized"
        );
        _;
    }

    modifier userExists(address user) {
        require(reputations[user].isInitialized, "User not initialized");
        _;
    }

    function initialize(
        address _owner,
        address _creditManager
    ) public initializer {
        require(_owner != address(0), "Invalid owner");
        require(_creditManager != address(0), "Invalid credit manager");

        __Ownable_init(_owner);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CREDIT_MANAGER_ROLE, _creditManager);
    }

    function initializeUser(
        address user
    ) external onlyAuthorized whenNotPaused {
        require(user != address(0), "Invalid user address");
        require(!reputations[user].isInitialized, "User already initialized");

        ReputationTier initialTier = _calculateTier(DEFAULT_SCORE);

        reputations[user] = ReputationData({
            score: DEFAULT_SCORE,
            lastUpdated: block.timestamp,
            totalRepayments: 0,
            onTimeRepayments: 0,
            lateRepayments: 0,
            defaults: 0,
            tier: initialTier,
            isInitialized: true
        });

        usersList.push(user);
        emit UserInitialized(user, DEFAULT_SCORE, initialTier, block.timestamp);
    }

    function updateReputation(
        address borrower,
        bool isPositive,
        uint256 amount
    ) external onlyAuthorized whenNotPaused {
        if (!reputations[borrower].isInitialized) {
            this.initializeUser(borrower);
        }

        ReputationData storage data = reputations[borrower];
        uint256 scoreChange;
        string memory reason;

        if (isPositive) {
            scoreChange = onTimeBonus;
            data.onTimeRepayments++;
            reason = "On-time repayment";
        } else {
            scoreChange = latePaymentPenalty;
            data.lateRepayments++;
            reason = "Late payment";
        }

        data.totalRepayments++;
        _updateReputation(borrower, isPositive, scoreChange, reason);
    }

    function recordDefault(
        address user,
        uint256 debtAmount
    ) external onlyAuthorized whenNotPaused userExists(user) {
        ReputationData storage data = reputations[user];
        data.defaults++;

        uint256 penalty = defaultPenalty;
        if (debtAmount > 10000 * 1e6) {
            penalty = penalty * 2;
        }

        _updateReputation(user, false, penalty, "Loan default/liquidation");
    }

    function getReputationScore(address user) external view returns (uint256) {
        if (!reputations[user].isInitialized) {
            return DEFAULT_SCORE;
        }
        return reputations[user].score;
    }

    function getTier(address user) external view returns (ReputationTier) {
        if (!reputations[user].isInitialized) {
            return _calculateTier(DEFAULT_SCORE);
        }
        return reputations[user].tier;
    }

    function getReputationData(
        address user
    ) external view returns (ReputationData memory) {
        return reputations[user];
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

    function _updateReputation(
        address user,
        bool isIncrease,
        uint256 amount,
        string memory reason
    ) internal {
        ReputationData storage data = reputations[user];
        uint256 oldScore = data.score;
        ReputationTier oldTier = data.tier;

        uint256 actualChange = Math.min(amount, maxScoreChange);

        if (isIncrease) {
            data.score = Math.min(data.score + actualChange, MAX_SCORE);
        } else {
            data.score = data.score > actualChange
                ? data.score - actualChange
                : MIN_SCORE;
        }

        data.lastUpdated = block.timestamp;
        data.tier = _calculateTier(data.score);

        emit ScoreUpdated(
            user,
            oldScore,
            data.score,
            isIncrease,
            reason,
            block.timestamp
        );

        if (oldTier != data.tier) {
            emit TierChanged(user, oldTier, data.tier, block.timestamp);
        }
    }

    function _calculateTier(
        uint256 score
    ) internal pure returns (ReputationTier) {
        if (score >= GOLD_THRESHOLD) {
            return ReputationTier.Platinum;
        } else if (score >= SILVER_THRESHOLD) {
            return ReputationTier.Gold;
        } else if (score >= BRONZE_THRESHOLD) {
            return ReputationTier.Silver;
        } else {
            return ReputationTier.Bronze;
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
