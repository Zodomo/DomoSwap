// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Author: Zodomo.eth
// Started from function and return name template from BuidlGuidl but overwhelming majority of code is self-written
contract DEX {
    using SafeMath for uint256; // Uses SafeMath for uint256 variables
    IERC20 token; // Instantiates the imported contract

    uint256 public totalLiquidity;
    mapping (address => uint256) public liquidity;

    // Emitted when ethToToken() swap transacted
    event EthToTokenSwap(address indexed swapper, string tradeDetails, uint256 ethIn, uint256 tokenOut);
    // Emitted when tokenToEth() swap transacted
    event TokenToEthSwap(address indexed swapper, string tradeDetails, uint256 ethOut, uint256 tokenIn);
    // Emitted when liquidity provided to DEX and mints LPTs.
    event LiquidityProvided(address indexed provider, uint256 lptMinted, uint256 ethIn, uint256 tokenIn);
    // Emitted when liquidity removed from DEX and decreases LPT count within DEX.
    event LiquidityRemoved(address indexed provider, uint256 lptBurned, uint256 ethOut, uint256 tokenOut);

    constructor(address token_addr) public {
        token = IERC20(token_addr); // hooks into the ERC20 token we want to interact with, Balloons in this case
    }

    /* Initializes amount of tokens that will be transferred to the DEX itself from the ERC20 contract mintee
       ERC20 contract mintee is the only one who gets Balloons because Balloons.sol doesn't have a mint function outside of constructor
       Establishes ETH:Balloons ratio as 1:1 so "LP Tokens" (which aren't actually minted yet) are quantified by amount of ETH used
       init() caller must have called approve() on token contract for the init value at the minimum first */
    function init(uint256 tokens) public payable returns (uint256) {
        require(totalLiquidity == 0, "DEX already has liquidity!");  
        // require(address(this).balance == 0, "Contract has ETH, please withdraw!"); // Require zero balance if msg.value:tokens ratio must be enforced
        require(msg.value > 0, "No ETH sent!");
        // bool tokenTransfer = token.transferFrom(msg.sender, address(this), tokens);
        // require(tokenTransfer, "Failed to transfer tokens!");
        // The above can be simplified to one line:
        require(token.transferFrom(msg.sender, address(this), tokens), "Failed to transfer tokens!");
        totalLiquidity = address(this).balance; // Unless second line of init() is uncommented, includes pre-init ETH balance in liquidity
        liquidity[msg.sender] = totalLiquidity;
        emit LiquidityProvided(msg.sender, totalLiquidity, address(this).balance, tokens);
        return totalLiquidity;
    }

    // https://www.youtube.com/watch?v=IL7cRj5vzEU This function determines price with slippage
    // (xInput adjusted for fee * yLiquidity) / (xLiquidity + xInput adjusted for fee)
    // .mul(997) [numerator] and .mul(1000) [denominator] used because Solidity doesn't like decimals
    function price(
        uint256 xInput,
        uint256 xLiquidity,
        uint256 yLiquidity
    ) public pure returns (uint256 yOutput) {
        uint256 xInputWithFee = xInput.mul(997);
        uint256 numerator = xInputWithFee.mul(yLiquidity);
        uint256 denominator = (xLiquidity.mul(1000)).add(xInputWithFee);
        return (numerator.div(denominator));
    }

    // Use `return liquidity[provider]` to get the liquidity for a user.
    function getLiquidity(address provider) public view returns (uint256) { return liquidity[provider]; }

    // Sends Ether to DEX in exchange for $BAL
    function ethToToken() public payable returns (uint256 tokenOutput) {
        require(msg.value > 0, "No ETH sent!");
        // uint256 val = price(msg.value, (address(this).balance).sub(msg.value), token.balanceOf(address(this)));
        // require(token.transfer(msg.sender, val), "Token failed to send!");
        // I wrote the above two lines and they work, but they're easier to read below:
        uint256 ethReserve = (address(this).balance).sub(msg.value);
        uint256 tokenReserve = token.balanceOf(address(this));
        uint256 tokensOut = price(msg.value, ethReserve, tokenReserve);
        require(token.transfer(msg.sender, tokensOut), "Token failed to send!");
        emit EthToTokenSwap(msg.sender, "ETH to Balloons", msg.value, tokensOut);
        return tokensOut;
    }

    // Sends $BAL tokens to DEX in exchange for Ether
    function tokenToEth(uint256 tokenInput) public returns (uint256 ethOutput) {
        require(tokenInput > 0, "Cannot swap 0 tokens!");
        uint256 tokenReserve = token.balanceOf(address(this));
        uint256 etherOut = price(tokenInput, tokenReserve, address(this).balance);
        require(token.transferFrom(msg.sender, address(this), tokenInput), "Failed to transfer tokens!");
        (bool success, ) = msg.sender.call{value: etherOut}("");
        require(success, "Failed to send Ether!");
        emit TokenToEthSwap(msg.sender, "Balloons to ETH", etherOut, tokenInput);
        return etherOut;
    }

    // Depositor must call approve() on token contract for deposit value at a minimum first
    // deposit() calculates how many LP tokens to issue regardless of how much ETH has been added or removed since init
    // This is important because LP "tokens" were issued 1:1 for ETH deposited at init()
    function deposit() public payable returns (uint256 tokensDeposited) {
        /* First implementation, flawed due to decimal handling in Solidity amongst other reasons
        require(totalLiquidity > 0, "Not initialized!");
        require(msg.value > 0, "No ETH sent!");
        uint256 ratio = token.balanceOf(address(this)).div((address(this).balance).sub(msg.value));
        uint256 tokenDeposit = msg.value.mul(ratio);
        require(token.transferFrom(msg.sender, address(this), tokenDeposit), "Failed to transfer tokens!");
        totalLiquidity += msg.value;
        liquidity[msg.sender] += msg.value;
        emit LiquidityProvided(msg.sender, msg.value, msg.value, tokenDeposit);
        return tokenDeposit; */

        /* Token to ETH ratio calculated by the following:
           ((ETH sent * tokenReserve) / ethReserve) + 1
           LP "token" distribution regardless of price difference since init() calculated with:
           (ETH sent * totalLiquidity) / ethReserve
           Essentially, multiply ETH sent by total amount of LP tokens divided by how much ETH contract currently holds */
        uint256 ethReserve = address(this).balance.sub(msg.value);
        uint256 tokenReserve = token.balanceOf(address(this));
        uint256 tokenDeposit = ((msg.value.mul(tokenReserve)).div(ethReserve)).add(1);
        uint256 liquidityMinted = (msg.value.mul(totalLiquidity)).div(ethReserve);
        liquidity[msg.sender] = totalLiquidity.add(liquidityMinted);
        totalLiquidity = totalLiquidity.add(liquidityMinted);
        require(token.transferFrom(msg.sender, address(this), tokenDeposit));
        emit LiquidityProvided(msg.sender, liquidityMinted, msg.value, tokenDeposit);
        return tokenDeposit;
    }

    // Allows withdrawal of token and ETH from liquidity pool
    // Calculates token withdrawal ratio after any impermanence loss due to token distribution changes
    // Also coded to allow withdrawal of any amount of LP "tokens" held by liquidity provider. Doesn't need to be 100% withdrawal
    function withdraw(uint256 amount) public returns (uint256 eth_amount, uint256 token_amount) {
        /* First implementation, flawed due to decimal handling in Solidity amongst other reasons
        require(liquidity[msg.sender] > 0, "No liquidity provided!");
        require(liquidity[msg.sender] >= amount, "Withdrawal exceeds liquidity provided!");
        uint256 ratio = token.balanceOf(address(this)).div(address(this).balance);
        uint256 tokensOwed = amount.mul(ratio);
        require(token.transfer(msg.sender, tokensOwed), "Failed to transfer tokens!");
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Failed to send Ether!");
        return (amount, tokensOwed); */
        
        /* ETH quantity calculated with:
           (LP tokens "burned" * ethReserve) / totalLiquidity
           Token quantity calculated with:
           (LP tokens "burned" * tokenReserve) / totalLiquidity
           totalLiquidity references total LP token balance */
        require(liquidity[msg.sender] >= amount, "Withdrawal exceeds liquidity provided!");
        uint256 ethReserve = address(this).balance;
        uint256 tokenReserve = token.balanceOf(address(this));
        uint256 ethWithdrawn = (amount.mul(ethReserve)).div(totalLiquidity);
        uint256 tokenAmount = (amount.mul(tokenReserve)).div(totalLiquidity);
        liquidity[msg.sender] = liquidity[msg.sender].sub(amount);
        totalLiquidity = totalLiquidity.sub(amount);
        (bool success, ) = msg.sender.call{value: ethWithdrawn}("");
        require(success, "Failed to send Ether!");
        require(token.transfer(msg.sender, tokenAmount));
        emit LiquidityRemoved(msg.sender, amount, ethWithdrawn, tokenAmount);
        return (ethWithdrawn, tokenAmount);
    }
}