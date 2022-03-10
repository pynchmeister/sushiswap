// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@boringcrypto/boring-solidity/contracts/BoringBatchable.sol";
import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarder.sol";
import "./interfaces/IZapDirector.sol";

interface IMigratorDirector {
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    function migrate(IERC20 token) external returns (IERC20);
}

/// @notice The (older) ZapDirector contract gives out a constant number of GZAP tokens per block.
/// It is the only address with minting rights for GZAP.
/// The idea for this ZapDirector V2 (ZDV2) contract is therefore to be the owner of a dummy token
/// that is deposited into the ZapDirector V1 (ZDV1) contract.
/// The allocation point for this pool on ZDV1 is the total allocation point for all pools that receive double incentives.
contract ZapDirectorV2 is BoringOwnable, BoringBatchable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each ZDV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of GZAP entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each ZDV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of GZAP to distribute per block.
    struct PoolInfo {
        uint128 accGZapPerShare;
        uint64 lastRewardBlock;
        uint64 allocPoint;
    }

    /// @notice Address of ZDV1 contract.
    IZapDirector public immutable ZAP_DIRECTOR;
    /// @notice Address of GZAP contract.
    IERC20 public immutable GZAP;
    /// @notice The index of ZDV2 master pool in MCV1.
    uint256 public immutable MASTER_PID;
    // @notice The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorDirector public migrator;

    /// @notice Info of each ZDV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each ZDV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 private constant ZAPDIRECTOR_GZAP_PER_BLOCK = 1e20;
    uint256 private constant ACC_GZAP_PRECISION = 1e12;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, IRewarder indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accGZapPerShare);
    event LogInit();

    /// @param _ZAP_DIRECTOR The ZSwap ZDV1 contract address.
    /// @param _gzap The GZAP token contract address.
    /// @param _MASTER_PID The pool ID of the dummy token on the base ZDV1 contract.
    constructor(IZapDirector _ZAP_DIRECTOR, IERC20 _gzap, uint256 _MASTER_PID) public {
        GZAP = _gzap;
        ZAP_DIRECTOR = _ZAP_DIRECTOR;
        MASTER_PID = _MASTER_PID;
    }

    /// @notice Deposits a dummy token to `Zap_Director` ZDV1. This is required because ZDV1 holds the minting rights for GZAP.
    /// Any balance of transaction sender in `dummyToken` is transferred.
    /// The allocation point for the pool on ZDV1 is the total allocation point for all pools that receive double incentives.
    /// @param dummyToken The address of the ERC-20 token to deposit into ZDV1.
    function init(IERC20 dummyToken) external {
        uint256 balance = dummyToken.balanceOf(msg.sender);
        require(balance != 0, "ZapDirectorV2: Balance must exceed 0");
        dummyToken.safeTransferFrom(msg.sender, address(this), balance);
        dummyToken.approve(address(ZAP_DIRECTOR), balance);
        ZAP_DIRECTOR.deposit(MASTER_PID, balance);
        emit LogInit();
    }

    /// @notice Returns the number of ZDV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 allocPoint, IERC20 _lpToken, IRewarder _rewarder) public onlyOwner {
        uint256 lastRewardBlock = block.number;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
            allocPoint: allocPoint.to64(),
            lastRewardBlock: lastRewardBlock.to64(),
            accGZapPerShare: 0
        }));
        emit LogPoolAddition(lpToken.length.sub(1), allocPoint, _lpToken, _rewarder);
    }

    /// @notice Update the given pool's GZAP allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool overwrite) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        if (overwrite) { rewarder[_pid] = _rewarder; }
        emit LogSetPool(_pid, _allocPoint, overwrite ? _rewarder : rewarder[_pid], overwrite);
    }

    /// @notice Set the `migrator` contract. Can only be called by the owner.
    /// @param _migrator The contract address to set.
    function setMigrator(IMigratorDirector _migrator) public onlyOwner {
        migrator = _migrator;
    }

    /// @notice Migrate LP token to another LP contract through the `migrator` contract.
    /// @param _pid The index of the pool. See `poolInfo`.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "ZapDirectorV2: no migrator set");
        IERC20 _lpToken = lpToken[_pid];
        uint256 bal = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(_lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "ZapDirectorV2: migrated balance must match");
        lpToken[_pid] = newLpToken;
    }

    /// @notice View function to see pending GZAP on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending GZAP reward for a given user.
    function pendingGZap(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGZapPerShare = pool.accGZapPerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 gzapReward = blocks.mul(gzapPerBlock()).mul(pool.allocPoint) / totalAllocPoint;
            accGZapPerShare = accGZapPerShare.add(gzapReward.mul(ACC_GZAP_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accGZapPerShare) / ACC_GZAP_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Calculates and returns the `amount` of GZAP per block.
    function gzapPerBlock() public view returns (uint256 amount) {
        amount = uint256(ZAPDIRECTOR_GZAP_PER_BLOCK)
            .mul(ZAP_DIRECTOR.poolInfo(MASTER_PID).allocPoint) / ZAP_DIRECTOR.totalAllocPoint();
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 gzapReward = blocks.mul(gzapPerBlock()).mul(pool.allocPoint) / totalAllocPoint;
                pool.accGZapPerShare = pool.accGZapPerShare.add((gzapReward.mul(ACC_GZAP_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardBlock = block.number.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardBlock, lpSupply, pool.accGZapPerShare);
        }
    }

    /// @notice Deposit LP tokens to ZDV2 for GZAP allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(int256(amount.mul(pool.accGZapPerShare) / ACC_GZAP_PRECISION));

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGZapReward(pid, to, to, 0, user.amount);
        }

        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from ZDV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accGZapPerShare) / ACC_GZAP_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGZapReward(pid, msg.sender, to, 0, user.amount);
        }
        
        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of GZAP rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedGZap = int256(user.amount.mul(pool.accGZapPerShare) / ACC_GZAP_PRECISION);
        uint256 _pendingGZap = accumulatedGZap.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedGZap;

        // Interactions
        if (_pendingGZap != 0) {
            GZAP.safeTransfer(to, _pendingGZap);
        }
        
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGZapReward( pid, msg.sender, to, _pendingGZap, user.amount);
        }

        emit Harvest(msg.sender, pid, _pendingGZap);
    }
    
    /// @notice Withdraw LP tokens from ZDV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and GZAP rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedGZap = int256(user.amount.mul(pool.accGZapPerShare) / ACC_GZAP_PRECISION);
        uint256 _pendingGZap = accumulatedGZap.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedGZap.sub(int256(amount.mul(pool.accGZapPerShare) / ACC_GZAP_PRECISION));
        user.amount = user.amount.sub(amount);
        
        // Interactions
        GZAP.safeTransfer(to, _pendingGZap);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGZapReward(pid, msg.sender, to, _pendingGZap, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingGZap);
    }

    /// @notice Harvests GZAP from `Zap_DIRECTOR` ZDV1 and pool `MASTER_PID` to this ZDV2 contract.
    function harvestFromZapDirector() public {
        ZAP_DIRECTOR.deposit(MASTER_PID, 0);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onGZapReward(pid, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }
}
