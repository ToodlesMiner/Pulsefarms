pragma solidity ^0.8.2;

contract HeadFarm is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SEC
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSecPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSecPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SEC to distribute per second.
        uint256 lastRewardTime; // Last time that SEC distribution occurs.
        uint256 accRewardPerShare; // Accumulated SEC per share, times 1e12. See below.
    }

    Squirtle public Token_B;

    // Reward tokens created per second.
    uint256 public RewardPerSecond;

    // set a max reward per second, which can never be higher than 1 per second
    uint256 public constant maxRewardPerSecond = 1e18; //@dev use with 18 decimals

    uint256 public constant MaxAllocPoint = 4000;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block time when INC mining starts.
    uint256 public immutable startTime;
    address public Token_A;
    address private MakerAddress;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        Squirtle _Token_B,
        address _Token_A,
        uint256 _RewardPerSecond,
        uint256 _startTime
    ) {
        Token_B = _Token_B;
        RewardPerSecond = _RewardPerSecond;
        startTime = _startTime;
        Token_A = _Token_A;
        MakerAddress = msg.sender;
    }

    function mint(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than zero");

        IERC20(Token_A).approve(address(Token_B), _amount);

        address caller = msg.sender;
        Token_B.Mint(caller, _amount);
    }

    function calculateRatio() public view returns (uint256) {
        uint256 _InflationCount = Token_B.InflationCount();
        uint256 _InflationPercent = Token_B.InflationPercent(); // This should be 700 for 7%
        uint256 Ratio = Token_B.initialRatio() * 1e2; // Multiply by 100 to scale 5000 to 500000, representing 50.00

        // Use a separate variable for the computation
        uint256 computedRatio = Ratio;

        // Apply the inflation for each count with compounding
        for (uint256 i = 0; i < _InflationCount; i++) {
            computedRatio =
                computedRatio +
                (computedRatio * _InflationPercent) /
                1e4; // 1e4 for 1000 (percent scaling) * 10 (extra decimal scaling)
        }

        return computedRatio;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Changes INC token reward per second, with a cap of maxINC per second
    // Good practice to update pools without messing up the contract
    function setRewardPerSecond(uint256 _RewardPerSecond) external onlyOwner {
        require(
            _RewardPerSecond <= maxRewardPerSecond,
            "setSecPerSecond: too many SEC!"
        );

        // This MUST be done or pool rewards will be calculated with new INC per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools();

        RewardPerSecond = _RewardPerSecond;
    }

    function changerMaker(address newMaker) external onlyOwner {
        Token_B.changerMaker(newMaker);
        //emit MakerAddressChanged (newMaker);
    }

    function checkForDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(
                poolInfo[_pid].lpToken != _lpToken,
                "add: pool already exists!!!!"
            );
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools

        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime
            ? block.timestamp
            : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accRewardPerShare: 0
            })
        );
    }

    // Update the given pool's INC allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        if (poolInfo[_pid].allocPoint > _allocPoint) {
            require(
                totalAllocPoint - (poolInfo[_pid].allocPoint - _allocPoint) > 0,
                "add: can't set totalAllocPoint to 0!!"
            );
        }
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to time.
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending INC on frontend.
    function pendingReward(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.LP1.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 Reward = multiplier
                .mul(RewardPerSecond)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accRewardPerShare = accRewardPerShare.add(
                Reward.mul(1e12).div(lpSupply)
            );
        }
        return
            user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.LP1.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(
            pool.lastRewardTime,
            block.timestamp
        );
        uint256 Reward = multiplier
            .mul(RewardPerSecond)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        Token_B.update(address(this), Reward);

        pool.accRewardPerShare = pool.accRewardPerShare.add(
            Reward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for INC allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(
            user.rewardDebt
        );

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);

        if (pending > 0) {
            safeSecTransfer(msg.sender, pending);
        }
        pool.LP1.safeTransferFrom(address(msg.sender), address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    //Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(
            user.rewardDebt
        );

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);

        if (pending > 0) {
            safeSecTransfer(msg.sender, pending);
        }
        pool.LP1.safeTransfer(address(msg.sender), _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    //Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.LP1.safeTransfer(address(msg.sender), oldUserAmount);
        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);
    }

    // Safe INC transfer function, just in case if rounding error causes pool to not have enough SEC.
    function safeSecTransfer(address _to, uint256 _amount) internal {
        uint256 SecBal = ERC20(Token_A).balanceOf(address(this));
        if (_amount > SecBal) {
            ERC20(Token_A).transfer(_to, SecBal);
        } else {
            ERC20(Token_A).transfer(_to, _amount);
        }
    }

    //****@dev for testing ONLY remove for mainet***
    // function Inflate () public  {
    //     Token_B.Inflate();
    // }
}
