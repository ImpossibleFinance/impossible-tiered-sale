// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./IFFundable.sol";

// Contract to manage tiered sales with promotional codes and whitelisting.
contract IFTieredSale is ReentrancyGuard, AccessControl, IFFundable {
    using SafeERC20 for ERC20;

    ERC20 public paymentToken;

    ERC20 public saleToken;


    // Tier and promotion management
    string[] public tierIds;
    mapping(string => Tier) public tiers;
    mapping(string => mapping(address => uint256)) public purchasedAmountPerTier; // tierId => address => amount in ether
    mapping(string => uint256) public codePurchaseAmount; // promo code => total purchased amount in ether
    mapping(string => uint256) public saleTokenPurchasedByTier; // tierId => total purchased amount in ether
    mapping(string => PromoCode) public promoCodes;
    mapping(address => string[]) public ownerPromoCodes; // address => promo code
    string[] public allPromoCodes;

    // Configuration percentages
    // reward percentage
    uint8 public baseOwnerPercentage = 8;
    uint8 public masterOwnerPercentage = 2;
    uint8 public addressPromoCodePercentage = 8;
    uint8 public immutable MAX_BASE_OWNER_PERCENTAGE = 10;
    uint8 public immutable MAX_MASTER_OWNER_PERCENTAGE = 2;
    uint8 public immutable MAX_BONUS_PERCENTAGE = 5;
    // discount percentage
    uint8 public addressPromoCodeDiscountPercentage = 5;

    // Reward claiming management
    bool public claimRewardsEnabled = false;
    uint256 public totalRewardsUnclaimed; // Total unclaimed rewards, assuming all are valid

    // Role constants
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Structs for managing pricing tiers and promotional codes
    struct Tier {
        uint256 price;  // Price per tier in gwei.
        uint256 maxTotalPurchasable;  // Total limit per tier (0 means no limit), specified in ether.
        uint256 maxAllocationPerWallet;  // Limit per wallet (0 means no limit), specified in ether.
        uint8 bonusPercentage;  // Additional bonus percentage applicable for this tier.
        bytes32 whitelistRootHash;  // Merkle root hash for whitelisting.
        bool isHalt;  // Flag to halt transactions for this tier if set to true.
        bool allowPromoCode;  // Flag to allow promo codes for this tier.
        bool allowWalletPromoCode;  // Flag to allow promo codes specific to wallets.
        uint256 startTime;  // Start time for this tier.
        uint256 endTime;  // End time for this tier.
    }

    struct PromoCode {
        uint8 discountPercentage;  // Discount provided by the promo code, in percentage (1 - 100).
        address promoCodeOwnerAddress;  // Address of the promo code owner.
        address masterOwnerAddress;  // Address of the master owner who oversees this promo code.
        uint256 promoCodeOwnerEarnings;  // Earnings accrued to the promo code owner, in gwei.
        uint256 masterOwnerEarnings;  // Earnings accrued to the master owner, in gwei.
        uint256 totalPurchased;  // Total value purchased using this promo code, in ether.
        uint8 baseOwnerPercentageOverride; // Base owner percentage override for this promo code.
        uint8 masterOwnerPercentageOverride; // Master owner percentage override for this promo code.
    }


    // State variables

    // Events
    event TierUpdated(string tierId);
    event PurchasedInTier(address indexed buyer, string tierId, uint256 amount, string promoCode);
    event ReferralRewardWithdrawn(address referrer, uint256 amount);
    event PromoCodeAdded(string code, uint8 discountPercentage, address promoCodeOwnerAddress, address masterOwnerAddress);

    // Constructor
    constructor(
        ERC20 _paymentToken,
        ERC20 _saleToken,
        uint256 _startTime,
        uint256 _endTime
    )
        IFFundable(_paymentToken, _saleToken, _startTime, _endTime, msg.sender)
    {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
        paymentToken = _paymentToken;
        saleToken = _saleToken;
    }

    // Access management
    modifier onlyOperator() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(OPERATOR_ROLE, msg.sender),  "Not authorized");
        _;
    }

        // Override the transferOwnership function
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        _revokeRole(DEFAULT_ADMIN_ROLE, owner());
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        super.transferOwnership(newOwner);
    }

    // Operator management functions
    function addOperator(address operator) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(operator!= address(0), "Invalid address");
        grantRole(OPERATOR_ROLE, operator);
    }

    function removeOperator(address operator) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(OPERATOR_ROLE, operator);
    }

    // Tier management
    function setTier(
        string memory _tierId,
        uint256 _price,
        uint256 _maxTotalPurchasable,
        uint256 _maxAllocationPerWallet,
        bytes32 _whitelistRootHash,
        uint8 _bonusPercentage,
        bool _isHalt,
        bool _allowPromoCode,
        bool _allowWalletPromoCode,
        uint256 _startTime,
        uint256 _endTime
    ) public onlyOperator {
        // Validate input data
        require(_price > 0, "Invalid price");
        require(_bonusPercentage <= MAX_BONUS_PERCENTAGE, "Invalid bonus percentage");
        // check starttime is in the future and endtime is greater than start time
        require(_startTime > block.timestamp, "Invalid start time");
        require(_endTime > _startTime, "Invalid end time");


        tiers[_tierId] = Tier({
            price: _price,
            maxTotalPurchasable: _maxTotalPurchasable,
            maxAllocationPerWallet: _maxAllocationPerWallet,
            whitelistRootHash: _whitelistRootHash,
            bonusPercentage: _bonusPercentage,
            isHalt: _isHalt,
            allowPromoCode: _allowPromoCode,
            allowWalletPromoCode: _allowWalletPromoCode,
            startTime: _startTime,
            endTime: _endTime

        });
        emit TierUpdated(_tierId);

        // iterate through the tierIds array to check if the tierId already exists
        for (uint i = 0; i < tierIds.length; i++) {
            if (keccak256(abi.encodePacked(tierIds[i])) == keccak256(abi.encodePacked(_tierId))) {
                return; // Tier already exists
            }
        }
        tierIds.push(_tierId);
    }


    // Promotion code management
    function addPromoCode(
        string memory _code,
        uint8 _discountPercentage,
        address _promoCodeOwnerAddress,
        address _masterOwnerAddress,
        uint8 _baseOwnerPercentageOverride,
        uint8 _masterOwnerPercentageOverride
    ) public onlyOperator {
        if (promoCodes[_code].discountPercentage != 0 || promoCodes[_code].promoCodeOwnerAddress != address(0)){
            revert("Promo code already exists");
        }
        // Validate the discount percentage and owner addresses
        _validatePromoCodeSetting(_code, _discountPercentage, _promoCodeOwnerAddress, _masterOwnerAddress, _baseOwnerPercentageOverride, _masterOwnerPercentageOverride);
        require(!_isWalletPromoCode(_code), "Address promo codes are not allowed");

        // Add the promo code
        promoCodes[_code] = PromoCode({
            discountPercentage: _discountPercentage,
            promoCodeOwnerAddress: _promoCodeOwnerAddress,
            masterOwnerAddress: _masterOwnerAddress,
            promoCodeOwnerEarnings: 0,
            masterOwnerEarnings: 0,
            totalPurchased: 0,
            baseOwnerPercentageOverride: _baseOwnerPercentageOverride,
            masterOwnerPercentageOverride: _masterOwnerPercentageOverride
        });
        ownerPromoCodes[_promoCodeOwnerAddress].push(_code);
        ownerPromoCodes[_masterOwnerAddress].push(_code);
        allPromoCodes.push(_code);
        emit PromoCodeAdded(_code, _discountPercentage, _promoCodeOwnerAddress, _masterOwnerAddress);
    }

    function _validatePromoCodeSetting(
        string memory code,
        uint8 discountPercentage,
        address promoCodeOwnerAddress,
        address masterOwnerAddress,
        uint8 baseOwnerPercentageOverride,
        uint8 masterOwnerPercentageOverride
    ) internal pure {
        require(bytes(code).length > 0, "Invalid promo code");
        require(discountPercentage <= 100, "Invalid discount percentage");
        require(promoCodeOwnerAddress != masterOwnerAddress, "Promo code owner and master owner cannot be the same");
        require(baseOwnerPercentageOverride <= MAX_BASE_OWNER_PERCENTAGE, "Invalid base owner percentage");
        require(masterOwnerPercentageOverride <= MAX_MASTER_OWNER_PERCENTAGE, "Invalid master owner percentage");
    }

    // Whitelisted purchase functions
    function whitelistedPurchaseInTierWithCode(
        string memory _tierId,
        uint256 _amount,
        bytes32[] calldata _merkleProof,
        string memory _promoCode,
        uint256 _allocation
    ) public {
        // Ensure promo codes are allowed for the tier and the promo code is valid
        require(!_isWalletPromoCode(_promoCode), "Purchase with whitelistedPurchaseInTierWithWalletCode");
        require(tiers[_tierId].allowPromoCode, "Promo code is not allowed for this tier");
        _validatePromoCode(_promoCode);
        bytes32 tierWhitelistRootHash = tiers[_tierId].whitelistRootHash;
        if (tierWhitelistRootHash != bytes32(0)) {
            require(checkTierWhitelist(_tierId, msg.sender, _merkleProof, _allocation), "Invalid proof");
            require(purchasedAmountPerTier[_tierId][msg.sender] + _amount <= _allocation, "Purchase exceeds allocation");
        }

        uint8 discount = calculateDiscount(_promoCode);
        uint256 discountedPrice = tiers[_tierId].price * (100 - discount) / 100;  // in gwei
        executePurchase(_tierId, _amount, discountedPrice, _promoCode);

        codePurchaseAmount[_promoCode] += discountedPrice * _amount;
        _updatePromoCodeRewards(_promoCode, discountedPrice * _amount, _tierId);
    }

    function whitelistedPurchaseInTierWithWalletCode(
        string memory _tierId,
        uint256 _amount,
        bytes32[] calldata _merkleProof,
        address _walletPromoCode,
        uint256 _allocation
    ) public {
        // Ensure promo codes are allowed for the tier and the promo code is valid
        require(tiers[_tierId].allowWalletPromoCode, "Promo code is not allowed for this tier");
        require(msg.sender != _walletPromoCode, "Cannot purchase with own wallet address promo code");
        // the promo code wallet address has to purchase at least one node
        require(validateWalletPromoCode(_walletPromoCode), "Promo code address has not purchased a node");
        string memory promoCode = addressToString(_walletPromoCode);
        // no need to validate address promo code at purchase
        bytes32 tierWhitelistRootHash = tiers[_tierId].whitelistRootHash;
        if (tierWhitelistRootHash != bytes32(0)) {
            require(checkTierWhitelist(_tierId, msg.sender, _merkleProof, _allocation), "Invalid proof");
            require(purchasedAmountPerTier[_tierId][msg.sender] + _amount <= _allocation, "Purchase exceeds allocation");
        }

        uint8 discount = calculateDiscount(promoCode);
        uint256 discountedPrice = tiers[_tierId].price * (100 - discount) / 100;  // in gwei
        executePurchase(_tierId, _amount, discountedPrice, promoCode);

        codePurchaseAmount[promoCode] += discountedPrice * _amount;
        _updateWalletPromoCodeRewards(_walletPromoCode, discountedPrice * _amount);
    }

    function calculateDiscount(string memory _promoCode) internal view returns (uint8) {
        uint8 discount;
        if (_isWalletPromoCode(_promoCode)) {
            discount = addressPromoCodeDiscountPercentage; // Fixed discount for address-based promo codes
        } else {
            discount = promoCodes[_promoCode].discountPercentage; // Variable discount for other promo codes
        }
        return discount;
    }

    function whitelistedPurchaseInTier(
        string memory _tierId,
        uint256 _amount,
        bytes32[] calldata _merkleProof,
        uint256 _allocation
    ) public {
        bytes32 tierWhitelistRootHash = tiers[_tierId].whitelistRootHash;
        if (tierWhitelistRootHash != bytes32(0)) {
            require(checkTierWhitelist(_tierId, msg.sender, _merkleProof, _allocation), "Invalid proof");
            require(purchasedAmountPerTier[_tierId][msg.sender] + _amount <= _allocation, "Purchase exceeds allocation");
        }
        executePurchase(_tierId, _amount, tiers[_tierId].price, "");
    }

    function executePurchase (string memory _tierId, uint256 _amount, uint256 _price, string memory _promoCode) private nonReentrant  {
        Tier storage tier = tiers[_tierId];
        require(!tier.isHalt, "Purchases in this tier are currently halted");
        require(tier.startTime <= block.timestamp && block.timestamp <= tier.endTime, "Tier is not active");
        require(_amount > 0, "Can only purchase non-zero amounts");
        require(
            tier.maxAllocationPerWallet == 0 || purchasedAmountPerTier[_tierId][msg.sender] + _amount <= tier.maxAllocationPerWallet,
            "Amount exceeds wallet's maximum allocation for this tier"
        );
        require(
            tier.maxTotalPurchasable == 0 || saleTokenPurchasedByTier[_tierId] + _amount <= tier.maxTotalPurchasable,
            "Amount exceeds tier's maximum total purchasable"
        );

        totalPaymentReceived += _amount * _price;
        purchasedAmountPerTier[_tierId][msg.sender] += _amount;
        saleTokenPurchasedByTier[_tierId] += _amount;

        uint256 totalCost = _amount * _price;  // in gwei

        paymentToken.safeTransferFrom(msg.sender, address(this), totalCost);

        emit PurchasedInTier(msg.sender, _tierId, _amount, _promoCode);
    }

    function _updateWalletPromoCodeRewards(address _walletPromoCode, uint256 totalCost) internal {
        string memory promoCode = addressToString(_walletPromoCode);
        if (promoCodes[promoCode].promoCodeOwnerAddress == address(0)) {
            promoCodes[promoCode].promoCodeOwnerAddress = _walletPromoCode;
        }
        uint256 ownerRewards = totalCost * addressPromoCodePercentage / 100;
        totalRewardsUnclaimed += ownerRewards;
        promoCodes[promoCode].promoCodeOwnerEarnings += ownerRewards;
        promoCodes[promoCode].totalPurchased += totalCost;
    }

    function _updatePromoCodeRewards(string memory _promoCode, uint256 totalCost, string memory tierId) internal {
        uint8 rewardPercentage = promoCodes[_promoCode].baseOwnerPercentageOverride > 0 ? promoCodes[_promoCode].baseOwnerPercentageOverride : baseOwnerPercentage;
        uint256 baseOwnerRewards = totalCost * rewardPercentage / 100;

        uint8 masterRewardPercentage = promoCodes[_promoCode].masterOwnerPercentageOverride > 0 ? promoCodes[_promoCode].masterOwnerPercentageOverride : masterOwnerPercentage;
        uint256 masterOwnerRewards = totalCost * masterRewardPercentage / 100;
        uint256 bonus = totalCost * tiers[tierId].bonusPercentage / 100;

        baseOwnerRewards += bonus;
        totalRewardsUnclaimed += baseOwnerRewards + masterOwnerRewards;
        promoCodes[_promoCode].promoCodeOwnerEarnings += baseOwnerRewards;
        promoCodes[_promoCode].masterOwnerEarnings += masterOwnerRewards;
        promoCodes[_promoCode].totalPurchased += totalCost;
    }


    function getSaleTokensSold() override internal view returns (uint256 amount) {
        uint256 tokenSold = 0;
        for (uint i = 0; i < tierIds.length; i++) {
            if (tiers[tierIds[i]].price == 0) {
                continue;
            }
            tokenSold += saleTokenPurchasedByTier[tierIds[i]];
        }
        return tokenSold;
    }

    function withdrawAllPromoCodeRewards () public nonReentrant {
        address promoCodeOwner = msg.sender;
        require(claimRewardsEnabled, "Claim rewards is disabled");

        // for each promo code owned by the address, withdraw the rewards
        string[] memory promoCodesOwned = ownerPromoCodes[promoCodeOwner];
        uint256 rewards = 0;
        for (uint i = 0; i < promoCodesOwned.length; i++) {
            PromoCode storage promo = promoCodes[promoCodesOwned[i]];

            // it could be _masterOwnerAddress or _promoCodeOwnerAddress
            if (promo.promoCodeOwnerAddress == promoCodeOwner) {
                rewards += promo.promoCodeOwnerEarnings;
                promo.promoCodeOwnerEarnings = 0;
            }
            if (promo.masterOwnerAddress == promoCodeOwner) {
                rewards += promo.masterOwnerEarnings;
                promo.masterOwnerEarnings = 0;
            }
        }
        require(rewards > 0, "No rewards available");
        totalRewardsUnclaimed -= rewards;
        paymentToken.safeTransfer(msg.sender, rewards);

        emit ReferralRewardWithdrawn(msg.sender, rewards);
    }


    function withdrawPromoCodeRewards (string memory _promoCode) public nonReentrant {
        require(claimRewardsEnabled, "Claim rewards is disabled");
        string memory promoCode = _promoCode;
        if (_isWalletPromoCode(promoCode)) {
            // can only claim wallet promo code of their own address
            require(validateWalletPromoCode(msg.sender), "Promo code address has not purchased a node");
            promoCode = addressToString(msg.sender);
        }
        PromoCode storage promo = promoCodes[promoCode];
        require(msg.sender == promo.promoCodeOwnerAddress || msg.sender == promo.masterOwnerAddress, "Not promo code owner or master owner");

        uint256 reward = 0;
        if (msg.sender == promo.promoCodeOwnerAddress) {
            reward = promo.promoCodeOwnerEarnings;
            promo.promoCodeOwnerEarnings = 0;
        } else if (msg.sender == promo.masterOwnerAddress) {
            reward = promo.masterOwnerEarnings;
            promo.masterOwnerEarnings = 0;
        }

        require(reward > 0, "No rewards available");
        totalRewardsUnclaimed -= reward;
        paymentToken.safeTransfer(msg.sender, reward);

        emit ReferralRewardWithdrawn(msg.sender, reward);
    }

    function safeCashPaymentToken() public onlyCasherOrOwner {
        // leave the amount for withdrawalReferenceRewards
        // this function assumes that the rewards are valid
        // to make sure there are enough payment tokens to be withdrawn by the referrers
        uint256 paymentTokenBal = paymentToken.balanceOf(address(this));
        require(paymentTokenBal > 0, "No payment token to cash");
        require(paymentTokenBal > totalRewardsUnclaimed, "Not enough payment token to cash");
        uint256 withdrawAmount = paymentTokenBal - totalRewardsUnclaimed;
        paymentToken.safeTransfer(_msgSender(), withdrawAmount);
        emit Cash(_msgSender(), withdrawAmount, 0);
    }

    // Returns true if user's allocation matches the one in merkle root, otherwise false
    function checkTierWhitelist(string memory _tierId, address user, bytes32[] calldata merkleProof, uint256 allocation)
        public
        view
        returns (bool)
    {
        // compute merkle leaf from input
        bytes32 leaf = keccak256(abi.encodePacked(user, allocation));

        // verify merkle proof
        return MerkleProof.verify(merkleProof, tiers[_tierId].whitelistRootHash, leaf);
    }

    function _isWalletPromoCode(string memory _promoCode) internal pure returns (bool) {
        return bytes(_promoCode).length == 42;
    }

    function validateWalletPromoCode(address promoCodeAddress) public view returns (bool) {
        if (promoCodeAddress == address(0)) {
            return false;
        }

        uint256 sum = 0;
        for (uint i = 0; i < tierIds.length; i++) {
            if (tiers[tierIds[i]].price == 0) {
                continue;
            }
            if (purchasedAmountPerTier[tierIds[i]][promoCodeAddress] > 0) {
                // return true if the address has purchased at least one node
                sum += purchasedAmountPerTier[tierIds[i]][promoCodeAddress];
                return true;
            }
        }
        return false;
    }

    function _validatePromoCode(string memory _promoCode) internal view {
        require(bytes(_promoCode).length > 0, "Invalid promo code");
        require(promoCodes[_promoCode].discountPercentage > 0, "Invalid promo code");
    }

    // Override the renounceOwnership function to disable it
    function renounceOwnership() public pure override{
        revert("ownership renunciation is disabled");
    }

    // ops functions
    function haltAllTiers() public onlyOperator {
        for (uint i = 0; i < tierIds.length; i++) {
            tiers[tierIds[i]].isHalt = true;
        }
    }

    function unhaltAllTiers() public onlyOperator {
        for (uint i = 0; i < tierIds.length; i++) {
            tiers[tierIds[i]].isHalt = false;
        }
    }

    function updateMaxTotalPurchasable(string memory _tierId, uint256 _maxTotalPurchasable) public onlyOperator {
        tiers[_tierId].maxTotalPurchasable = _maxTotalPurchasable;
    }

    function updateWhitelist(string memory _tierId, bytes32 _whitelistRootHash) public onlyOperator {
        tiers[_tierId].whitelistRootHash = _whitelistRootHash;
    }

    function updateIsHalt(string memory _tierId, bool _isHalt) public onlyOperator {
        tiers[_tierId].isHalt = _isHalt;
    }

    function updatePromoCodeAllowance(string memory _tierId, bool _allowPromoCode) public onlyOperator {
        tiers[_tierId].allowPromoCode = _allowPromoCode;
    }

    function updateWalletPromoCodeAllowance(string memory _tierId, bool _allowWalletPromoCode) public onlyOperator {
        tiers[_tierId].allowWalletPromoCode = _allowWalletPromoCode;
    }

    function updateTierStartTime(string memory _tierId, uint256 _startTime) public onlyOperator {
        require(_startTime > block.timestamp && _startTime < tiers[_tierId].endTime, "Invalid start time");
        tiers[_tierId].startTime = _startTime;
    }

    function updateMaxAllocationPerWallet(string memory _tierId, uint256 _maxAllocationPerWallet) public onlyOperator {
        tiers[_tierId].maxAllocationPerWallet = _maxAllocationPerWallet;
    }

    function updateTierEndTime(string memory _tierId, uint256 _endTime) public onlyOperator {
        require(_endTime > block.timestamp && tiers[_tierId].startTime < _endTime, "Invalid end time");
        tiers[_tierId].endTime = _endTime;
    }

    function updateClaimRewardsEnabled(bool _claimRewardsEnabled) public onlyOperator {
        claimRewardsEnabled = _claimRewardsEnabled;
    }

    // owner only ops functions
    function updateRewards(uint8 _baseOwnerPercentage, uint8 _masterOwnerPercentage) public onlyOwner {
        require(_baseOwnerPercentage <= MAX_BASE_OWNER_PERCENTAGE, "Invalid base owner percentage");
        require(_masterOwnerPercentage <= MAX_MASTER_OWNER_PERCENTAGE, "Invalid master owner percentage");
        baseOwnerPercentage = _baseOwnerPercentage;
        masterOwnerPercentage = _masterOwnerPercentage;
    }

    function updateAddressRewards(uint8 _addressPromoCodePercentage) public onlyOwner {
        require(_addressPromoCodePercentage <= MAX_BASE_OWNER_PERCENTAGE, "Invalid address promo code percentage");
        addressPromoCodePercentage = _addressPromoCodePercentage;
    }

    function updateAddressDiscount(uint8 _addressPromoCodeDiscountPercentage) public onlyOwner {
        require(_addressPromoCodeDiscountPercentage <= 100, "Invalid address promo code discount percentage");
        addressPromoCodeDiscountPercentage = _addressPromoCodeDiscountPercentage;
    }

    function updatePromocode(
        string memory _code,
        uint8 _discountPercentage,
        address _promoCodeOwnerAddress,
        address _masterOwnerAddress,
        uint8 _baseOwnerPercentageOverride,
        uint8 _masterOwnerPercentageOverride
     ) public onlyOwner {
        // ok to update address promo code
        _validatePromoCodeSetting(_code, _discountPercentage, _promoCodeOwnerAddress, _masterOwnerAddress, _baseOwnerPercentageOverride, _masterOwnerPercentageOverride);
        promoCodes[_code].discountPercentage = _discountPercentage;
        promoCodes[_code].promoCodeOwnerAddress = _promoCodeOwnerAddress;
        promoCodes[_code].masterOwnerAddress = _masterOwnerAddress;
        promoCodes[_code].baseOwnerPercentageOverride = _baseOwnerPercentageOverride;
        promoCodes[_code].masterOwnerPercentageOverride = _masterOwnerPercentageOverride;
    }

    // view function for ops
    function getAllPromoCodeInfo(uint256 fromIdx, uint256 toIdx) public view returns (PromoCode[] memory) {
        require(fromIdx < toIdx, "Invalid range");
        if (toIdx > allPromoCodes.length) {
            toIdx = allPromoCodes.length;
        }
        PromoCode[] memory promoCodeInfos = new PromoCode[](toIdx - fromIdx);
        for (uint i = fromIdx; i < toIdx; i++) {
            promoCodeInfos[i - fromIdx] = promoCodes[allPromoCodes[i]];
        }
        return promoCodeInfos;
    }

    function getPromoCodeLength() public view returns (uint256) {
        return allPromoCodes.length;
    }

    function getAllPromoCodes(uint256 fromIdx, uint256 toIdx) public view returns (string[] memory) {
        require(fromIdx < toIdx, "Invalid range");
        if (toIdx > allPromoCodes.length) {
            toIdx = allPromoCodes.length;
        }
        string[] memory promoCodeList = new string[](toIdx - fromIdx);
        for (uint i = fromIdx; i < toIdx; i++) {
            promoCodeList[i] = allPromoCodes[i];
        }
        return promoCodeList;
    }

    function getOwnerPromoCodes(address owner) public view returns (string[] memory) {
        uint256 length = ownerPromoCodes[owner].length;
        string[] memory promoCodeList = new string[](length);
        for (uint i = 0; i < length; i++) {
            promoCodeList[i] = ownerPromoCodes[owner][i];
        }
        return promoCodeList;
    }


    function getAllTierIds() public view returns (string[] memory) {
        return tierIds;
    }


    // util function
    function addressToString(address _addr) public pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(_addr)), 20);
    }
}
