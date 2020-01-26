/**
 * @title: Compound wrapper
 * @summary: Used for interacting with Compound. Has
 *           a common interface with all other protocol wrappers.
 *           This contract holds assets only during a tx, after tx it should be empty
 * @author: William Bergamo, idle.finance
 */
pragma solidity 0.5.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../interfaces/CERC20Eth.sol";
import "../interfaces/ILendingProtocol.sol";
import "../interfaces/WhitePaperInterestRateModel.sol";

contract IdleETHCompound is ILendingProtocol, Ownable {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;
  using Address for address payable;

  // protocol token (cToken) address
  address public token;
  address public idleToken;

  /**
   * @param _token : cToken address
   */
  constructor(address _token) public {
    require(_token != address(0), 'COMP: _token addr is 0');

    token = _token;
  }

  /**
   * Throws if called by any account other than IdleToken contract.
   */
  modifier onlyIdle() {
    require(msg.sender == idleToken, "Ownable: caller is not IdleToken contract");
    _;
  }

  // onlyOwner
  /**
   * sets idleToken address
   * NOTE: can be called only once. It's not on the constructor because we are deploying this contract
   *       after the IdleToken contract
   * @param _idleToken : idleToken address
   */
  function setIdleToken(address _idleToken)
    external onlyOwner {
      require(idleToken == address(0), "idleToken addr already set");
      require(_idleToken != address(0), "_idleToken addr is 0");
      idleToken = _idleToken;
  }
  // end onlyOwner

  /**
   * Calculate next supply rate for Compound, given an `_amount` supplied (last array param)
   * and all other params supplied. See `info_compound.md` for more info
   * on calculations.
   *
   * @param params : array with all params needed for calculation (see below)
   * @return : yearly net rate
   */
  function nextSupplyRateWithParams(uint256[] memory params)
    public view
    returns (uint256) {
      /*
        This comment is a reference for params name
        This gives stack too deep so check implementation below

        uint256 j = params[0]; // 10 ** 18;
        uint256 a = params[1]; // white.baseRate(); // from WhitePaper
        uint256 b = params[2]; // cToken.totalBorrows();
        uint256 c = params[3]; // white.multiplier(); // from WhitePaper
        uint256 d = params[4]; // cToken.totalReserves();
        uint256 e = params[5]; // j.sub(cToken.reserveFactorMantissa());
        uint256 s = params[6]; // cToken.getCash();
        uint256 k = params[7]; // white.blocksPerYear();
        uint256 f = params[8]; // 100;
        uint256 x = params[9]; // newAmountSupplied;

        // q = ((((a + (b*c)/(b + s + x)) / k) * e * b / (s + x + b - d)) / j) * k * f -> to get yearly rate
        nextRate = a.add(b.mul(c).div(b.add(s).add(x))).div(k).mul(e).mul(b).div(
          s.add(x).add(b).sub(d)
        ).div(j).mul(k).mul(f); // to get the yearly rate
      */

      // (b*c)/(b + s + x)
      uint256 inter1 = params[2].mul(params[3]).div(params[2].add(params[6]).add(params[9]));
      // (s + x + b - d)
      uint256 inter2 = params[6].add(params[9]).add(params[2]).sub(params[4]);
      // ((a + (b*c)/(b + s + x)) / k) * e
      uint256 inter3 = params[1].add(inter1).div(params[7]).mul(params[5]);
      // ((((a + (b*c)/(b + s + x)) / k) * e * b / (s + x + b - d)) / j) * k * f
      return inter3.mul(params[2]).div(inter2).div(params[0]).mul(params[7]).mul(params[8]);
  }

  /**
   * Calculate next supply rate for Compound, given an `_amount` supplied
   *
   * @param _amount : new underlying amount supplied (eg DAI)
   * @return : yearly net rate
   */
  function nextSupplyRate(uint256 _amount)
    external view
    returns (uint256) {
      CERC20Eth cToken = CERC20Eth(token);
      WhitePaperInterestRateModel white = WhitePaperInterestRateModel(cToken.interestRateModel());
      uint256[] memory params = new uint256[](10);

      params[0] = 10**18; // j
      params[1] = white.baseRate(); // a
      params[2] = cToken.totalBorrows(); // b
      params[3] = white.multiplier(); // c
      params[4] = cToken.totalReserves(); // d
      params[5] = params[0].sub(cToken.reserveFactorMantissa()); // e
      params[6] = cToken.getCash(); // s
      params[7] = white.blocksPerYear(); // k
      params[8] = 100; // f
      params[9] = _amount; // x

      // q = ((((a + (b*c)/(b + s + x)) / k) * e * b / (s + x + b - d)) / j) * k * f -> to get yearly rate
      return nextSupplyRateWithParams(params);
  }

  /**
   * @return current price of cToken in underlying
   */
  function getPriceInToken()
    external view
    returns (uint256) {
      return CERC20Eth(token).exchangeRateStored();
  }

  /**
   * @return apr : current yearly net rate
   */
  function getAPR()
    external view
    returns (uint256 apr) {
      CERC20Eth cToken = CERC20Eth(token);
      WhitePaperInterestRateModel white = WhitePaperInterestRateModel(cToken.interestRateModel());
      uint256 cRate = cToken.supplyRatePerBlock(); // interest % per block
      apr = cRate.mul(white.blocksPerYear()).mul(100);
  }

  /**
   * Gets all underlying tokens in this contract and mints cTokens
   * tokens are then transferred to msg.sender
   * NOTE: underlying tokens needs to be sended here before calling this
   *
   * @return cTokens minted
   */
  function mint()
    external onlyIdle
    returns (uint256 cTokens) {
      uint256 balance = address(this).balance;
      if (balance == 0) {
        return cTokens;
      }
      // get a handle for the corresponding cToken contract
      CERC20Eth _cToken = CERC20Eth(token);
      // mint the cTokens and assert there is no error
      require(_cToken.mint.value(balance)() == 0, "Error minting");
      // cTokens are now in this contract
      cTokens = IERC20(token).balanceOf(address(this));
      // transfer them to the caller
      IERC20(token).safeTransfer(msg.sender, cTokens);
  }

  /**
   * Gets all cTokens in this contract and redeems underlying tokens.
   * underlying tokens are then transferred to `_account`
   * NOTE: cTokens needs to be sended here before calling this
   *
   * @param _account : account that will receive redeemed amount
   * @return underlying tokens redeemd
   */
  function redeem(address _account)
    external onlyIdle
    returns (uint256 tokens) {
      // Funds needs to be sended here before calling this
      CERC20Eth _cToken = CERC20Eth(token);
      // redeem all underlying sent in this contract
      require(_cToken.redeem(IERC20(token).balanceOf(address(this))) == 0, "Something went wrong when redeeming in cTokens");

      tokens = address(this).balance;
      // cast to address payable
      address(uint160(_account)).sendValue(tokens);
  }

  function() external payable {}
}