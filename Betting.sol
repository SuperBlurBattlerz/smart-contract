// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.x;

interface IBlast {
  function configureClaimableGas() external;
  function configureAutomaticYield() external;
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
}

interface IBlastPoints {
    function configurePointsOperator(address operator) external;
}

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

/**
 * - There can be only one active race.
 * - If nobody has bet on the winner, we share the pool with the race winner.
 *   - If the winner has ever bet on the platform, we split 50/50 the betting pool with them. Otherwise they get a FEE_WINNER percentage of the pool
 * - To avoid gas problems with too many winners during rewards distribution, the process is split into three:
 *   - calculateWinnings - Can iterate in batches to calc the winning pool
 *   - _distributeRewards - Can iterate in batches to distribute rewards
 *   - distributeFees - Sends us rewards and gas is not dependent on the number of winners
 *   - For up to ~400 winners distributeRewards() can be used without the need for iterations.
 * - We ignore results of sending eth to winner and bettors, to avoid blocking of awards distributions.
*/
contract Betting is ReentrancyGuard {
    uint public constant MIN_BET = 0.0005 ether;
    uint public constant FEE_PLATFORM = 1;
    uint public constant FEE_WINNER = 2;

    struct Race {
        address[] racers;
        uint256 bettingStartBlock;
        uint256 bettingEndBlock;
        uint256 raceStartTimestamp;
        uint256 raceEndTimestamp;

        // winner => degens
        mapping(address => address[]) degens;
        // winner => degen => amount
        mapping(address => mapping(address => uint)) bets;
        uint totalBets;

        address winner;

        uint winnerReward;
        uint winnersBetsAmount;
        uint processedWinnersAmountsCount;
        // degen => flag
        mapping(address => bool) winnersAmountsSummed;

        uint rewardsDistributedCount;
        // degen => flag
        mapping(address => bool) rewardsDistributed;

        bool feesDistributed;
    }

    event NewRace(uint256 raceId);
    event NewBet(uint256 indexed raceId, address indexed degen, address indexed racer, uint256 amount);
    event RaceEnd(uint256 indexed raceId, address indexed winner);
    event RewardDistributed(address indexed to, uint amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BeneficiaryTransferred(address indexed previousBeneficiary, address indexed newBeneficiary);
    event RaceAdminUpdated(address indexed raceAdmin, bool flag);
    event PointsOperatorTransferred(address indexed newOperator);

    uint256 public currentRaceIndex = 0;
    // race id => race
    mapping(uint256 => Race) public races;
    mapping(address => bool) public allTimeDegens;

    address owner;
    address beneficiary1;
    address beneficiary2;
    mapping(address => bool) public raceAdmins;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner.");
        _;
    }

    modifier onlyRaceAdmin() {
        require(raceAdmins[msg.sender], "Not race admin.");
        _;
    }

    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);
    IBlastPoints public constant BLAST_POINTS = IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800);

    constructor(address _owner, address _pointsOperator) {
        owner = _owner;

        BLAST.configureAutomaticYield(); 
        BLAST.configureClaimableGas();

        setPointsOperator(_pointsOperator);
    }

    function getRacers(uint raceId) public view returns (address[] memory) {
        return races[raceId].racers;
    }

    function getRaceDegensCount(uint raceId, address racer) public view returns (uint) {
        return races[raceId].degens[racer].length;
    }

    function getRaceDegens(uint raceId, address racer) public view returns (address[] memory) {
        return races[raceId].degens[racer];
    }

    function getRaceDegens(uint raceId, address racer, uint start, uint end) public view returns (address[] memory degens) {
        uint i;
        degens = new address[](end - start);

        for (; start < end;) {
            degens[i] = races[raceId].degens[racer][start];
            unchecked { ++start; ++i; }
        }
    }

    function getRaceBets(uint raceId, address racer, address degen) public view returns (uint256) {
        return races[raceId].bets[racer][degen];
    }

    function getWinnersAmountsSummed(uint raceId, address degen) public view returns (bool) {
        return races[raceId].winnersAmountsSummed[degen];
    }

    function getRewardsDistributed(uint raceId, address degen) public view returns (bool) {
        return races[raceId].rewardsDistributed[degen];
    }

    function setPointsOperator(address _pointsOperator) public onlyOwner {
        emit PointsOperatorTransferred(_pointsOperator);

        BLAST_POINTS.configurePointsOperator(_pointsOperator);
    }

    function setOwner(address _owner) external onlyOwner {
        emit OwnershipTransferred(owner, _owner);

        owner = _owner;
    }

    function updateB1(address _b1) external onlyOwner {
        emit BeneficiaryTransferred(beneficiary1, _b1);

        beneficiary1 = _b1;
    }

    function updateB2(address _b2) external onlyOwner {
        emit BeneficiaryTransferred(beneficiary2, _b2);

        beneficiary2 = _b2;
    }

    function setRaceAdmin(address admin, bool flag) external onlyOwner {
        emit RaceAdminUpdated(admin, flag);

        raceAdmins[admin] = flag;
    }

    function createRace(
        address[] memory racers,
        uint256 bettingStartBlock,
        uint256 bettingEndBlock,
        uint256 raceStartTimestamp,
        uint256 raceEndTimestamp
    ) external onlyRaceAdmin {
        Race storage race = races[currentRaceIndex];

        require(race.racers.length == 0, "Race has already been setup.");
        require(racers.length >= 2 && racers.length <= 8, "Racers need to be between 2 and 8.");
        require(bettingEndBlock > bettingStartBlock && bettingStartBlock > block.number, "Bet interval must be in the future.");
        require(raceEndTimestamp > raceStartTimestamp, "Invalid race window.");

        uint i;
        uint len = racers.length;
        for (; i < len;) {
            race.racers.push(racers[i]);

            unchecked { ++i; }
        }

        race.bettingStartBlock = bettingStartBlock;
        race.bettingEndBlock = bettingEndBlock;
        race.raceStartTimestamp = raceStartTimestamp;
        race.raceEndTimestamp = raceEndTimestamp;

        emit NewRace(currentRaceIndex);
    }

    function betMore(address winner) external payable {
        Race storage race = races[currentRaceIndex];

        require(msg.value >= MIN_BET, "Bet too low.");
        require(
            block.number >= race.bettingStartBlock &&
                block.number < race.bettingEndBlock,
                "Outside of betting window."
        );
        require(block.timestamp < race.raceStartTimestamp, "Race has already started.");
        require(_isRacerInTheRace(race, winner), "This address isn't in the race.");

        if (race.bets[winner][msg.sender] == 0) {
            race.degens[winner].push(msg.sender);
        }

        race.bets[winner][msg.sender] += msg.value;
        race.totalBets += msg.value;

        allTimeDegens[msg.sender] = true;

        emit NewBet(currentRaceIndex, msg.sender, winner, msg.value);
    }

    function endRace(address winner) external onlyRaceAdmin {
        Race storage race = races[currentRaceIndex];

        require(race.racers.length != 0, "Race has not been setup.");
        require(block.timestamp > race.raceEndTimestamp, "Race end time hasn't been reached yet.");
        require(race.winner == address(0), "Winner has already been set.");
        require(_isRacerInTheRace(race, winner), "This address isn't in the race.");

        race.winner = winner;

        emit RaceEnd(currentRaceIndex, winner);
    }

    function calculateWinnings(uint start, uint end) public onlyRaceAdmin {
        Race storage race = races[currentRaceIndex];

        require(race.winner != address(0), "Winner hasn't been set yet.");
        require(end <= race.degens[race.winner].length, "Outside of bettors range in calc.");

        for (; start < end;) {
            address degen = race.degens[race.winner][start];

            if (race.winnersAmountsSummed[degen] == false) {
                race.winnersAmountsSummed[degen] = true;

                race.winnersBetsAmount += race.bets[race.winner][degen];

                ++race.processedWinnersAmountsCount;
            }

            unchecked { ++start; }
        }
    }

    function distributeRewards() external nonReentrant onlyRaceAdmin {
        Race storage race = races[currentRaceIndex];

        require(race.winner != address(0), "Winner hasn't been set yet.");

        uint winnersCount = race.degens[race.winner].length;

        if (winnersCount == 0) {
            _splitPoolWithWinner(race);
            return;
        }

        calculateWinnings(0, winnersCount);
        _distributeRewards(race, 0, winnersCount);
        distributeFees();
    }

    function distributeRewards(uint start, uint end) external nonReentrant onlyRaceAdmin {
        Race storage race = races[currentRaceIndex];

        require(race.winner != address(0), "Winner hasn't been set yet.");
        require(race.degens[race.winner].length != 0, "No bettors have won, use distributeRewards() or distributeFees().");
        require(race.processedWinnersAmountsCount == race.degens[race.winner].length, "Bets haven't been processed yet.");

        _distributeRewards(race, start, end);
    }

    function distributeFees() public onlyRaceAdmin {
        Race storage race = races[currentRaceIndex];

        uint winnersCount = race.degens[race.winner].length;

        require(race.winner != address(0), "Winner hasn't been set yet");
        require(race.rewardsDistributedCount == winnersCount, "Rewards haven't been distributed yet.");
        require(race.feesDistributed == false, "Fees have already been distributed.");

        if (winnersCount == 0) {
            _splitPoolWithWinner(race);
            return;
        }

        race.feesDistributed = true;

        if (race.winnerReward != 0) {
            _sendEth(race.winner, race.winnerReward);

            emit RewardDistributed(race.winner, race.winnerReward);
        }

        _closeRace();
    }

    function _sendEth(address to, uint amount) private {
        to.call{value: amount}("");
    }

    function _isRacerInTheRace(Race storage race, address racer) private view returns (bool) {
        uint i;
        uint len = race.racers.length;

        for (; i < len;) {
            if (racer == race.racers[i]) {
                return true;
            }

            unchecked { ++i; }
        }

        return false;
    }

    function _splitPoolWithWinner(Race storage race) private {
        require(race.feesDistributed == false, "Fees have already been distributed.");

        race.feesDistributed = true;

        if (address(this).balance != 0) {
            uint amount = allTimeDegens[race.winner] ? address(this).balance / 2 : address(this).balance * FEE_WINNER / 100;

            _sendEth(race.winner, amount);

            emit RewardDistributed(race.winner, amount);
        }

        _closeRace();
    }

    function _distributeRewards(Race storage race, uint start, uint end) private {
        require(end <= race.degens[race.winner].length, "Outside of bettors range in distribution.");

        bool onlyWinners = race.totalBets == race.winnersBetsAmount;
        uint fee = onlyWinners ? 0 : race.totalBets * FEE_PLATFORM / 100;
        race.winnerReward = onlyWinners ? 0 : race.totalBets * FEE_WINNER / 100;
        uint totalWinningsPool = race.totalBets - race.winnerReward - fee;

        // If the losers' bets are not enough to cover the fees,
        // just give the whole pool to the winning degens.
        if (totalWinningsPool < race.winnersBetsAmount) {
            totalWinningsPool = race.totalBets;
            race.winnerReward = 0;
        }

        for (; start < end;) {
            address degen = race.degens[race.winner][start];

            if (race.rewardsDistributed[degen] == false) {
                race.rewardsDistributed[degen] = true;
                ++race.rewardsDistributedCount;

                uint amount = (race.bets[race.winner][degen] * totalWinningsPool) / race.winnersBetsAmount;
                _sendEth(degen, amount);

                emit RewardDistributed(degen, amount);
            }

            unchecked { ++start; }
        }
    }

    function _closeRace() private {
        address me = address(this);

        BLAST.claimAllGas(me, me);

        if (me.balance != 0) {
            _sendEth(beneficiary1, me.balance / 2);
            _sendEth(beneficiary2, me.balance);
        }

        ++currentRaceIndex;
    }

    receive() external payable {}
}
