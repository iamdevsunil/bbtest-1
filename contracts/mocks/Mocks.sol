// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// ─── Mock ERC20 (USDT) ───────────────────────────────────────────────────────
contract MockERC20 {
    string public name; string public symbol; uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s){ name=n; symbol=s; }
    function mint(address to, uint256 a) external { balanceOf[to]+=a; totalSupply+=a; }
    function approve(address sp, uint256 a) external returns (bool){ allowance[msg.sender][sp]=a; return true; }
    function transfer(address to, uint256 a) external returns (bool){ _t(msg.sender,to,a); return true; }
    function transferFrom(address f,address to,uint256 a) external returns (bool){
        uint256 al=allowance[f][msg.sender]; require(al>=a,"allow"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a;
        _t(f,to,a); return true;
    }
    function _t(address f,address to,uint256 a) internal { require(balanceOf[f]>=a,"bal"); balanceOf[f]-=a; balanceOf[to]+=a; }
}

// ─── Mock Pair (BB/USDT) with settable reserves ──────────────────────────────
contract MockPair {
    address public token0; address public token1;
    uint112 r0; uint112 r1;
    uint256 public price0CumulativeLast; uint256 public price1CumulativeLast;
    constructor(address _t0, address _t1){ token0=_t0; token1=_t1; }
    function setReserves(uint112 _r0, uint112 _r1) external { r0=_r0; r1=_r1; }
    function getReserves() external view returns (uint112,uint112,uint32){ return (r0,r1,uint32(block.timestamp)); }
    // simulate TWAP accumulation
    function bumpCumulative(uint256 a, uint256 b) external { price0CumulativeLast+=a; price1CumulativeLast+=b; }
}

// ─── Mock Router (PancakeSwap V2) ────────────────────────────────────────────
interface IBB { function transfer(address,uint256) external returns (bool); }
contract MockRouter {
    address public bb; address public usdt; MockPair public pair;
    constructor(address _bb, address _usdt, address _pair){ bb=_bb; usdt=_usdt; pair=MockPair(_pair); }
    // 1 USDT -> 1 BB; pulls USDT in, sends BB out from router's pre-funded reserve
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external {
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IBB(path[1]).transfer(to, amountIn); // BB from reserve (fixed supply)
    }
    function addLiquidity(
        address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired,
        uint256, uint256, address, uint256
    ) external returns (uint256,uint256,uint256){
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        return (amountADesired, amountBDesired, 1e18);
    }
}

// ─── Attacker: tries reentrancy + contract-caller bypass ─────────────────────
interface IVaultAttack {
    function enroll(address) external;
    function stake(uint128) external;
    function claim() external;
}
contract Attacker {
    IVaultAttack public vault;
    constructor(address v){ vault=IVaultAttack(v); }
    function tryEnroll(address ref) external { vault.enroll(ref); }      // should revert (EOA check)
    function tryStake(uint128 a) external { vault.stake(a); }            // should revert
    // reentrancy hook
    fallback() external { try vault.claim() {} catch {} }
}

// ─── Advanced attacker: reentrancy via malicious USDT callback attempt ────────
interface IVaultFull {
    function enroll(address) external;
    function stake(uint128) external;
    function claim() external;
    function claimReward() external;
}
contract ReentrantAttacker {
    IVaultFull public v; uint256 public depth;
    constructor(address _v){ v=IVaultFull(_v); }
    function attackClaim() external { v.claim(); }
    function attackStake(uint128 a) external { v.stake(a); }
    // re-enter on any ETH/callback
    receive() external payable { if(depth<2){depth++; try v.claim(){}catch{}} }
    fallback() external { if(depth<2){depth++; try v.claim(){}catch{}} }
}
