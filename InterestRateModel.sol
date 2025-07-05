// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract InterestRateModel is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;

    bytes32 public constant CREDIT_MANAGER_ROLE =
        keccak256("CREDIT_MANAGER_ROLE");
    bytes32 public constant LENDING_POOL_ROLE = keccak256("LENDING_POOL_ROLE");
    bytes32 public constant RATE_ADMIN_ROLE = keccak256("RATE_ADMIN_ROLE");

    uint256 public constant BASIS_POINTS = 10000; 
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant PRECISION = 1e18;

    enum RateModelType {
        Fixed,
        Dynamic
    }

    struct RateParameters {
        uint256 baseRate; 
        uint256 maxRate; 
        uint256 penaltyRate;
        uint256 optimalUtilization;
        uint256 penaltyUtilization;
        RateModelType modelType;
        bool isActive;
    }

    RateParameters public rateParams;
    uint256 public gracePeriod;

    address public lendingPool;

    uint256 public constant MAX_RATE_LIMIT = 10000; 
    uint256 public constant MIN_GRACE_PERIOD = 1 days;
    uint256 public constant MAX_GRACE_PERIOD = 90 days;

    event RateUpdated(
        uint256 oldRate,
        uint256 newRate,
        RateModelType modelType,
        uint256 timestamp
    );

    event GracePeriodChanged(
        uint256 oldPeriod,
        uint256 newPeriod,
        uint256 timestamp
    );

    event RateParametersUpdated(
        uint256 baseRate,
        uint256 maxRate,
        uint256 penaltyRate,
        uint256 optimalUtilization,
        uint256 penaltyUtilization,
        RateModelType modelType,
        uint256 timestamp
    );

    event LendingPoolUpdated(
        address indexed oldPool,
        address indexed newPool,
        uint256 timestamp
    );

    modifier onlyAuthorized() {
        require(
            hasRole(CREDIT_MANAGER_ROLE, msg.sender) ||
                hasRole(LENDING_POOL_ROLE, msg.sender) ||
                msg.sender == owner(),
            "InterestRateModel: Not authorized"
        );
        _;
    }

    modifier onlyRateAdmin() {
        require(
            hasRole(RATE_ADMIN_ROLE, msg.sender) || msg.sender == owner(),
            "InterestRateModel: Rate admin access required"
        );
        _;
    }

    modifier validRate(uint256 rate) {
        require(
            rate <= MAX_RATE_LIMIT,
            "InterestRateModel: Rate exceeds maximum"
        );
        _;
    }

    modifier validUtilization(uint256 utilization) {
        require(
            utilization <= BASIS_POINTS,
            "InterestRateModel: Invalid utilization"
        );
        _;
    }

    function initialize(
        address _owner,
        address _creditManager,
        address _lendingPool
    ) public initializer {
        require(_owner != address(0), "InterestRateModel: Invalid owner");
        require(
            _creditManager != address(0),
            "InterestRateModel: Invalid credit manager"
        );

        __Ownable_init(_owner);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CREDIT_MANAGER_ROLE, _creditManager);
        _grantRole(RATE_ADMIN_ROLE, _owner);

        if (_lendingPool != address(0)) {
            _grantRole(LENDING_POOL_ROLE, _lendingPool);
            lendingPool = _lendingPool;
        }

        rateParams = RateParameters({
            baseRate: 1500,
            maxRate: 2000,
            penaltyRate: 3000,
            optimalUtilization: 5000,
            penaltyUtilization: 9000,
            modelType: RateModelType.Fixed,
            isActive: true
        });

        gracePeriod = 30 days;
    }

    function getAnnualRate() external view returns (uint256 rate) {
        if (rateParams.modelType == RateModelType.Fixed) {
            return rateParams.baseRate;
        } else {
            return _calculateDynamicRate();
        }
    }

    function setAnnualRate(
        uint256 newRate
    ) external onlyRateAdmin validRate(newRate) whenNotPaused {
        uint256 oldRate = rateParams.baseRate;
        rateParams.baseRate = newRate;

        emit RateUpdated(
            oldRate,
            newRate,
            rateParams.modelType,
            block.timestamp
        );
    }

    function calculateAccruedInterest(
        uint256 principal,
        uint256 borrowTimestamp
    ) external view returns (uint256 accruedInterest) {
        if (
            principal == 0 ||
            borrowTimestamp == 0 ||
            borrowTimestamp >= block.timestamp
        ) {
            return 0;
        }

        if (block.timestamp <= borrowTimestamp + gracePeriod) {
            return 0;
        }

        uint256 interestStartTime = borrowTimestamp + gracePeriod;
        uint256 timeElapsed = block.timestamp - interestStartTime;

        if (timeElapsed == 0) {
            return 0;
        }

        uint256 currentRate = rateParams.modelType == RateModelType.Fixed
            ? rateParams.baseRate
            : _calculateDynamicRate();

        uint256 dailyRate = (currentRate * PRECISION) /
            (BASIS_POINTS * SECONDS_PER_YEAR);
        accruedInterest = (principal * dailyRate * timeElapsed) / PRECISION;

        return accruedInterest;
    }

    function calculateInterest(
        address borrower,
        uint256 principal,
        uint256 borrowTimestamp
    ) external view onlyAuthorized returns (uint256 accruedInterest) {
        return this.calculateAccruedInterest(principal, borrowTimestamp);
    }

    function setGracePeriod(
        uint256 duration
    ) external onlyRateAdmin whenNotPaused {
        require(
            duration >= MIN_GRACE_PERIOD && duration <= MAX_GRACE_PERIOD,
            "InterestRateModel: Invalid grace period"
        );

        uint256 oldPeriod = gracePeriod;
        gracePeriod = duration;

        emit GracePeriodChanged(oldPeriod, duration, block.timestamp);
    }

    function updateRateParameters(
        uint256 _baseRate,
        uint256 _maxRate,
        uint256 _penaltyRate,
        uint256 _optimalUtilization,
        uint256 _penaltyUtilization,
        RateModelType _modelType
    )
        external
        onlyRateAdmin
        validRate(_baseRate)
        validRate(_maxRate)
        validRate(_penaltyRate)
        validUtilization(_optimalUtilization)
        validUtilization(_penaltyUtilization)
        whenNotPaused
    {
        require(
            _baseRate <= _maxRate,
            "InterestRateModel: Base rate exceeds max rate"
        );
        require(
            _maxRate <= _penaltyRate,
            "InterestRateModel: Max rate exceeds penalty rate"
        );
        require(
            _optimalUtilization <= _penaltyUtilization,
            "InterestRateModel: Invalid utilization thresholds"
        );

        rateParams.baseRate = _baseRate;
        rateParams.maxRate = _maxRate;
        rateParams.penaltyRate = _penaltyRate;
        rateParams.optimalUtilization = _optimalUtilization;
        rateParams.penaltyUtilization = _penaltyUtilization;
        rateParams.modelType = _modelType;

        emit RateParametersUpdated(
            _baseRate,
            _maxRate,
            _penaltyRate,
            _optimalUtilization,
            _penaltyUtilization,
            _modelType,
            block.timestamp
        );
    }

    function updateLendingPool(address newLendingPool) external onlyOwner {
        address oldPool = lendingPool;

        if (oldPool != address(0)) {
            _revokeRole(LENDING_POOL_ROLE, oldPool);
        }

        if (newLendingPool != address(0)) {
            _grantRole(LENDING_POOL_ROLE, newLendingPool);
        }

        lendingPool = newLendingPool;

        emit LendingPoolUpdated(oldPool, newLendingPool, block.timestamp);
    }

    function getUtilizationRate() public view returns (uint256 utilization) {
        if (lendingPool == address(0)) {
            return 0;
        }

        try ILendingPool(lendingPool).getUtilizationRate() returns (
            uint256 rate
        ) {
            return rate;
        } catch {
            return 0;
        }
    }

    function getRateParameters()
        external
        view
        returns (RateParameters memory params)
    {
        return rateParams;
    }

    function calculateInterestForPeriod(
        uint256 principal,
        uint256 rate,
        uint256 timeElapsed
    ) external pure returns (uint256 interest) {
        if (principal == 0 || rate == 0 || timeElapsed == 0) {
            return 0;
        }

        uint256 dailyRate = (rate * PRECISION) /
            (BASIS_POINTS * SECONDS_PER_YEAR);
        return (principal * dailyRate * timeElapsed) / PRECISION;
    }

    function isGracePeriodEnded(
        uint256 borrowTimestamp
    ) external view returns (bool ended) {
        if (borrowTimestamp == 0) return false;
        return block.timestamp > borrowTimestamp + gracePeriod;
    }

    function getRemainingGracePeriod(
        uint256 borrowTimestamp
    ) external view returns (uint256 remaining) {
        if (borrowTimestamp == 0) return 0;

        uint256 graceEnd = borrowTimestamp + gracePeriod;
        if (block.timestamp >= graceEnd) {
            return 0;
        }

        return graceEnd - block.timestamp;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _calculateDynamicRate() internal view returns (uint256 rate) {
        uint256 utilization = getUtilizationRate();

        if (utilization <= rateParams.optimalUtilization) {
            uint256 rateIncrease = ((utilization *
                (rateParams.maxRate - rateParams.baseRate)) /
                rateParams.optimalUtilization);
            return rateParams.baseRate + rateIncrease;
        } else if (utilization <= rateParams.penaltyUtilization) {
            uint256 excessUtilization = utilization -
                rateParams.optimalUtilization;
            uint256 utilizationRange = rateParams.penaltyUtilization -
                rateParams.optimalUtilization;
            uint256 rateIncrease = ((excessUtilization *
                (rateParams.penaltyRate - rateParams.maxRate)) /
                utilizationRange);
            return rateParams.maxRate + rateIncrease;
        } else {
            return rateParams.penaltyRate;
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}

interface ILendingPool {
    function getUtilizationRate() external view returns (uint256);
}
