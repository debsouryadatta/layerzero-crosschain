// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OAppOptionsType3 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

contract SimpleTokenCrossChainMint is ERC20, Ownable, ReentrancyGuard, OApp, OAppOptionsType3 {
    using Strings for uint256;
    using OptionsBuilder for bytes;

    // ========== STRUCTS ==========
    struct PoolInfo {
        uint256 maxSupply;
        uint256 mintPrice;
        uint256 totalMinted;
        uint256 maxMintsPerWallet;
        bool enabled;
    }

    enum ActionType {
        MintTokensForBurn,
        BurnTokensForMint,
        SyncMintStatus // NEW: Sync mint status across chains
    }

    struct ActionData {
        ActionType actionType;
        address account;
        uint256 amount;
        uint8 poolId;
    }

    // ========== EVENTS ==========
    event PoolMinted(address indexed user, uint8 indexed poolId, uint256 amount, uint256 timestamp);
    event PoolStatusChanged(uint8 indexed poolId, bool enabled);
    // Debug events
    event Debug(string action, address user, uint256 value1, uint256 value2);
    event DebugString(string action, string message);
    event AllPoolsStatusChanged(bool enabled);
    event CrossChainTransfer(address indexed from, address indexed to, uint256 amount, uint32 dstEid);
    event WhitelistUpdated(uint8 indexed poolId, address indexed account, bool status);
    event CrossChainMintSynced(address indexed user, uint8 indexed poolId, uint32 indexed srcEid); // UPDATED EVENT
    event STokenPayment(address indexed user, uint256 amount, string operation); // NEW: S token payment tracking
    event STokenAddressUpdated(address indexed oldAddress, address indexed newAddress); // NEW: S token address update tracking

    // ========== ERRORS ==========
    error InvalidPoolId();
    error PoolDisabled();
    error PoolFull();
    error InsufficientPayment();
    error AlreadyMinted();
    error MintLimitExceeded();
    error NotWhitelisted();
    error InvalidAmount();
    error InvalidAddress();
    error TransferFailed();
    error STokenTransferFailed(); // NEW: S token specific error

    // Detailed diagnostic errors
    error MintingDisabled(bool globalMintingEnabled, bool poolEnabled);
    error WhitelistCheckFailed(uint8 poolId, address user, bool isWhitelisted);
    error PoolSupplyCheckFailed(uint256 totalMinted, uint256 maxSupply);
    error PaymentCheckFailed(uint256 provided, uint256 required);
    error CrossChainMessageFailed(uint32 dstEid, string reason);
    error RefundFailed(address recipient, uint256 amount);

    // ========== STATE ==========
    uint256 public constant MAX_POOLS = 4;

    // Chain constants
    uint256 public constant SONIC_CHAIN_ID = 146;
    uint32 public constant SONIC_EID = 30332;
    uint256 public constant ETH_CHAIN_ID = 1;
    uint32 public constant ETH_EID = 30101;

    // Additional chain constants
    uint256 public constant LINEA_CHAIN_ID = 59144;
    uint32 public constant LINEA_EID = 30183;
    uint256 public constant OPTIMISM_CHAIN_ID = 10;
    uint32 public constant OPTIMISM_EID = 30111;
    uint256 public constant BASE_CHAIN_ID = 8453;
    uint32 public constant BASE_EID = 30184;
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;
    uint32 public constant ARBITRUM_EID = 30110;

    // S Token contract on Sonic (native S is not ERC20, so we use wrapped S)
    address public WRAPPED_S_TOKEN = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38; // From Sonic docs

    mapping(uint8 => PoolInfo) public pools;
    mapping(uint8 => mapping(address => bool)) public whitelist;
    mapping(uint8 => mapping(address => uint256)) public mintCountPerPool; // UPDATED: Track mint count per pool per user
    mapping(address => bool) public hasMintedGlobal;
    mapping(address => uint32) public mintedOnChain; // Track which chain user first minted on

    bool public mintingEnabled = true;
    bool public crossChainEnabled = true;
    uint256 public totalMaxSupply;
    uint128 public defaultGasLimit = 200000;
    mapping(uint32 => uint128) public crossChainGasLimits;

    // ========== CONSTRUCTOR ==========
    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        address _endpoint,
        uint256[] memory _mintPrices,
        uint256[] memory _maxSupplies
    ) ERC20(_name, _symbol) Ownable(_owner) OApp(_endpoint, _owner) {
        require(_mintPrices.length == MAX_POOLS && _maxSupplies.length == MAX_POOLS, "Invalid pool config");

        for (uint8 i = 0; i < MAX_POOLS; i++) {
            uint8 poolId = i + 1;
            uint256 maxMints = (poolId <= 2) ? 1 : 2;

            pools[poolId] = PoolInfo({
                maxSupply: _maxSupplies[i] * (10 ** decimals()),
                mintPrice: _mintPrices[i],
                totalMinted: 0,
                maxMintsPerWallet: maxMints,
                enabled: false
            });
            totalMaxSupply += pools[poolId].maxSupply;
        }
    }

    // ========== CHAIN DETECTION ==========
    function _isSonicChain() internal view returns (bool) {
        return block.chainid == SONIC_CHAIN_ID;
    }

    function _isEthereumChain() internal view returns (bool) {
        return block.chainid == ETH_CHAIN_ID;
    }

    function _isLineaChain() internal view returns (bool) {
        return block.chainid == LINEA_CHAIN_ID;
    }

    function _isOptimismChain() internal view returns (bool) {
        return block.chainid == OPTIMISM_CHAIN_ID;
    }

    function _isBaseChain() internal view returns (bool) {
        return block.chainid == BASE_CHAIN_ID;
    }

    function _isArbitrumChain() internal view returns (bool) {
        return block.chainid == ARBITRUM_CHAIN_ID;
    }

    function _isEthTokenChain() internal view returns (bool) {
        // All chains except Sonic use ETH token
        return !_isSonicChain();
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal override {
        // Validate that the message comes from a trusted source
        bytes32 expectedPeer = peers[_origin.srcEid];
        bytes32 actualPeer = keccak256(abi.encodePacked(_origin.sender, address(this)));
        if (expectedPeer != bytes32(0) && expectedPeer != actualPeer) {
            revert InvalidAddress();
        }

        ActionData memory action = abi.decode(_message, (ActionData));

        if (action.actionType == ActionType.MintTokensForBurn) {
            _mint(action.account, action.amount);
        } else if (action.actionType == ActionType.BurnTokensForMint) {
            _burn(action.account, action.amount);
        } else if (action.actionType == ActionType.SyncMintStatus) {
            // Handle cross-chain mint status synchronization
            _syncMintStatus(action.account, action.poolId, _origin.srcEid);
        }
    }

    // ========== CROSS-CHAIN MINT SYNC ==========
    function _syncMintStatus(address _user, uint8 _poolId, uint32 _srcEid) internal {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        if (_user == address(0)) revert InvalidAddress();

        // Increment the user's mint count for this pool
        mintCountPerPool[_poolId][_user] += 1;

        // Update global tracking
        if (!hasMintedGlobal[_user]) {
            hasMintedGlobal[_user] = true;
            mintedOnChain[_user] = _srcEid;
        }

        emit CrossChainMintSynced(_user, _poolId, _srcEid);
    }

    // External function to allow try/catch
    function notifyOtherChainsExternal(address _user, uint8 _poolId) external {
        // Only allow calls from this contract
        require(msg.sender == address(this), "Unauthorized");
        _notifyOtherChains(_user, _poolId);
    }

    function _notifyOtherChains(address _user, uint8 _poolId) internal {
        if (_user == address(0)) {
            emit DebugString("_notifyOtherChains", "Invalid user address");
            return;
        }
        if (_poolId < 1 || _poolId > MAX_POOLS) {
            emit DebugString("_notifyOtherChains", "Invalid pool ID");
            return;
        }

        // Send message to all other chains to sync mint status
        // Get current chain EID
        uint32 currentEid = _getCurrentChainEid();
        emit Debug("Current chain EID", _user, currentEid, _poolId);

        // We'll send to all chains except the current one
        uint32[] memory destinationEids = _getOtherChainEids(currentEid);
        emit Debug("Destination chains count", _user, destinationEids.length, _poolId);

        // Send message to each destination chain
        for (uint256 i = 0; i < destinationEids.length; i++) {
            uint32 dstEid = destinationEids[i];
            emit Debug("Sending to chain", _user, dstEid, _poolId);

            ActionData memory action = ActionData({
                actionType: ActionType.SyncMintStatus,
                account: _user,
                amount: 0,
                poolId: _poolId
            });

            bytes memory message = abi.encode(action);
            uint128 gasLimit = crossChainGasLimits[dstEid] > 0 ? crossChainGasLimits[dstEid] : defaultGasLimit;
            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);

            MessagingFee memory fee = _quote(dstEid, message, options, false);

            // Handle payment based on current chain
            if (_isSonicChain()) {
                // On Sonic, use S token for gas fees
                bool gasPaymentSuccess = _handleSonicGasPayment(fee.nativeFee);
                if (!gasPaymentSuccess) {
                    emit DebugString("Sonic gas payment failed", fee.nativeFee.toString());
                    continue; // Skip this chain if payment fails
                }

                _lzSend(dstEid, message, options, MessagingFee(fee.nativeFee, 0), payable(address(this)));
                emit Debug("LZ send successful", _user, dstEid, _poolId);
            } else {
                // On other chains, use native token (ETH)
                if (address(this).balance >= fee.nativeFee) {
                    emit Debug("Native balance check", _user, address(this).balance, fee.nativeFee);
                    _lzSend(dstEid, message, options, MessagingFee(fee.nativeFee, 0), payable(address(this)));
                    emit Debug("LZ send successful", _user, dstEid, _poolId);
                } else {
                    emit Debug("Insufficient native balance", _user, address(this).balance, fee.nativeFee);
                }
            }
        }
    }

    // ========== S TOKEN HANDLING ==========
    function _handleSonicGasPayment(uint256 gasAmount) internal returns (bool) {
        if (!_isSonicChain()) return true; // Not on Sonic chain, no S token needed

        // Check if contract has enough wrapped S tokens
        IERC20 sToken = IERC20(WRAPPED_S_TOKEN);
        uint256 balance = sToken.balanceOf(address(this));

        emit Debug("S token balance check", address(this), balance, gasAmount);

        if (balance >= gasAmount) {
            // Note: In practice, you'd need to unwrap S tokens to pay for gas
            // This is a simplified implementation
            emit STokenPayment(address(this), gasAmount, "gas_payment");
            return true;
        }

        return false; // Insufficient S token balance
    }

    function _handleSTokenPayment(address user, uint256 amount) internal returns (bool) {
        if (!_isSonicChain()) return false;

        IERC20 sToken = IERC20(WRAPPED_S_TOKEN);

        // Check user's S token balance
        if (sToken.balanceOf(user) < amount) {
            return false;
        }

        // Transfer S tokens from user to contract
        bool success = sToken.transferFrom(user, address(this), amount);
        if (!success) {
            revert STokenTransferFailed();
        }

        emit STokenPayment(user, amount, "mint_payment");
        return true;
    }

    // ========== WHITELIST MGMT ==========
    function setWhitelist(uint8 _poolId, address[] calldata _accounts, bool _status) external onlyOwner {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        for (uint256 i; i < _accounts.length; i++) {
            address acc = _accounts[i];
            if (acc == address(0)) revert InvalidAddress();
            whitelist[_poolId][acc] = _status;
            emit WhitelistUpdated(_poolId, acc, _status);
        }
    }

    // ========== MINT WITH PER-POOL LIMITS ==========
    function mintFromPool(uint8 _poolId) external payable nonReentrant {
        // Check pool ID validity with detailed error
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();

        // Check if minting is enabled with detailed error
        if (!mintingEnabled || !pools[_poolId].enabled) {
            revert MintingDisabled(mintingEnabled, pools[_poolId].enabled);
        }

        // Check mint limit with detailed error
        if (mintCountPerPool[_poolId][msg.sender] >= pools[_poolId].maxMintsPerWallet) {
            revert MintLimitExceeded();
        }

        // Check whitelist with detailed error
        if (_poolId <= 3) {
            bool isWhitelisted = whitelist[_poolId][msg.sender];
            if (!isWhitelisted) {
                revert WhitelistCheckFailed(_poolId, msg.sender, isWhitelisted);
            }
        }

        PoolInfo storage pool = pools[_poolId];

        // Check pool supply with detailed error
        if (pool.totalMinted >= pool.maxSupply) {
            revert PoolSupplyCheckFailed(pool.totalMinted, pool.maxSupply);
        }

        uint256 mintAmount = 1 * (10 ** decimals());

        // Double-check pool supply with detailed error
        if (pool.maxSupply - pool.totalMinted < mintAmount) {
            revert PoolSupplyCheckFailed(pool.totalMinted, pool.maxSupply);
        }

        // Log important values for debugging
        emit Debug("Pre-mint check", msg.sender, _poolId, msg.value);

        // Handle payment based on chain
        if (_isSonicChain()) {
            // On Sonic, accept S token payment
            bool sTokenPayment = _handleSTokenPayment(msg.sender, pool.mintPrice);
            if (!sTokenPayment) {
                revert PaymentCheckFailed(0, pool.mintPrice); // We don't know exact S token balance
            }
        } else {
            // On other chains, use ETH/native token
            if (msg.value < pool.mintPrice) {
                revert PaymentCheckFailed(msg.value, pool.mintPrice);
            }
        }

        // Log payment success
        emit Debug("Payment successful", msg.sender, _poolId, msg.value);

        // Update state
        pool.totalMinted += mintAmount;
        mintCountPerPool[_poolId][msg.sender] += 1;

        // Update global tracking for first mint
        if (!hasMintedGlobal[msg.sender]) {
            hasMintedGlobal[msg.sender] = true;
            mintedOnChain[msg.sender] = _getCurrentChainEid();
        }

        // Handle refunds for non-Sonic chains
        if (!_isSonicChain()) {
            uint256 refundAmount = 0;
            if (msg.value > pool.mintPrice) {
                refundAmount = msg.value - pool.mintPrice;
            }

            if (refundAmount > 0) {
                emit Debug("Refunding excess payment", msg.sender, refundAmount, 0);
                (bool success, ) = msg.sender.call{ value: refundAmount }("");
                if (!success) {
                    revert RefundFailed(msg.sender, refundAmount);
                }
            }
        }

        // Log pre-mint state
        emit Debug("Pre-mint state", msg.sender, mintAmount, pool.totalMinted);

        _mint(msg.sender, mintAmount);

        emit PoolMinted(msg.sender, _poolId, mintAmount, block.timestamp);

        // Log post-mint state before cross-chain notification
        emit Debug("Post-mint state", msg.sender, _poolId, block.timestamp);

        // Notify other chains about this mint - wrap in try/catch to isolate cross-chain issues
        try this.notifyOtherChainsExternal(msg.sender, _poolId) {
            emit Debug("Cross-chain notification successful", msg.sender, _poolId, 1);
        } catch Error(string memory reason) {
            emit DebugString("Cross-chain notification failed", reason);
            // Don't revert the whole transaction if cross-chain notification fails
        } catch (bytes memory) {
            emit DebugString("Cross-chain notification failed", "Unknown error");
            // Don't revert the whole transaction if cross-chain notification fails
        }
    }

    // ========== HELPER FUNCTIONS ==========
    function _getCurrentChainEid() internal view returns (uint32) {
        if (_isSonicChain()) {
            return SONIC_EID;
        } else if (_isLineaChain()) {
            return LINEA_EID;
        } else if (_isOptimismChain()) {
            return OPTIMISM_EID;
        } else if (_isBaseChain()) {
            return BASE_EID;
        } else if (_isArbitrumChain()) {
            return ARBITRUM_EID;
        } else {
            return ETH_EID; // Default to Ethereum
        }
    }

    function _getOtherChainEids(uint32 currentEid) internal pure returns (uint32[] memory) {
        // Create an array with all possible chain EIDs
        uint32[] memory allEids = new uint32[](6);
        allEids[0] = ETH_EID;
        allEids[1] = SONIC_EID;
        allEids[2] = LINEA_EID;
        allEids[3] = OPTIMISM_EID;
        allEids[4] = BASE_EID;
        allEids[5] = ARBITRUM_EID;

        // Count how many chains we need to include (all except current)
        uint256 count = 0;
        for (uint256 i = 0; i < allEids.length; i++) {
            if (allEids[i] != currentEid) {
                count++;
            }
        }

        // Create result array with the right size
        uint32[] memory result = new uint32[](count);
        uint256 resultIndex = 0;

        // Fill result array with all EIDs except current
        for (uint256 i = 0; i < allEids.length; i++) {
            if (allEids[i] != currentEid) {
                result[resultIndex] = allEids[i];
                resultIndex++;
            }
        }

        return result;
    }

    // ========== CROSS-CHAIN TRANSFER (SOULBOUND) ==========
    function transferToChain(uint32 _dstEid, uint256 _amount) external payable {
        if (!crossChainEnabled) revert PoolDisabled();
        if (_amount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < _amount) revert InsufficientPayment();

        _burn(msg.sender, _amount);

        ActionData memory action = ActionData({
            actionType: ActionType.MintTokensForBurn,
            account: msg.sender, // Always transfer to the same wallet
            amount: _amount,
            poolId: 0 // Not used for transfers
        });

        bytes memory message = abi.encode(action);
        uint128 gasLimit = crossChainGasLimits[_dstEid] > 0 ? crossChainGasLimits[_dstEid] : defaultGasLimit;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);

        MessagingFee memory fee = _quote(_dstEid, message, options, false);

        if (_isSonicChain()) {
            // On Sonic, use S token for gas fees
            bool sTokenPayment = _handleSTokenPayment(msg.sender, fee.nativeFee);
            if (!sTokenPayment) {
                revert InsufficientPayment();
            }
            // Use S token payment for LayerZero (simplified - in practice needs more complex handling)
            _lzSend(_dstEid, message, options, MessagingFee(0, 0), payable(address(this)));
        } else {
            // On other chains, use ETH/native token
            if (msg.value < fee.nativeFee) revert InsufficientPayment();
            _lzSend(_dstEid, message, options, MessagingFee(fee.nativeFee, 0), payable(msg.sender));
        }

        emit CrossChainTransfer(msg.sender, msg.sender, _amount, _dstEid);
    }

    // ========== ADMIN FUNCTIONS ==========
    function enablePool(uint8 _poolId) external onlyOwner {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        pools[_poolId].enabled = true;
        emit PoolStatusChanged(_poolId, true);
    }

    function disablePool(uint8 _poolId) external onlyOwner {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        pools[_poolId].enabled = false;
        emit PoolStatusChanged(_poolId, false);
    }

    function enableAllPools() external onlyOwner {
        for (uint8 i = 1; i <= MAX_POOLS; i++) {
            pools[i].enabled = true;
        }
        emit AllPoolsStatusChanged(true);
    }

    function disableAllPools() external onlyOwner {
        for (uint8 i = 1; i <= MAX_POOLS; i++) {
            pools[i].enabled = false;
        }
        emit AllPoolsStatusChanged(false);
    }

    function setPoolPrice(uint8 _poolId, uint256 _newPrice) external onlyOwner {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        pools[_poolId].mintPrice = _newPrice;
    }

    function setPoolMintLimit(uint8 _poolId, uint256 _maxMints) external onlyOwner {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        pools[_poolId].maxMintsPerWallet = _maxMints;
    }

    function setMintingEnabled(bool _enabled) external onlyOwner {
        mintingEnabled = _enabled;
    }

    function setCrossChainEnabled(bool _enabled) external onlyOwner {
        crossChainEnabled = _enabled;
    }

    function setGasLimit(uint32 _dstEid, uint128 _gasLimit) external onlyOwner {
        crossChainGasLimits[_dstEid] = _gasLimit;
    }

    // setPeer function is inherited from OAppCore

    function resetUserMint(address _user) external onlyOwner {
        if (_user == address(0)) revert InvalidAddress();
        hasMintedGlobal[_user] = false;
        mintedOnChain[_user] = 0;
        for (uint8 i = 1; i <= MAX_POOLS; i++) {
            mintCountPerPool[i][_user] = 0;
        }
    }

    // NEW: Reset user mint for specific pool
    function resetUserMintForPool(address _user, uint8 _poolId) external onlyOwner {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        if (_user == address(0)) revert InvalidAddress();
        mintCountPerPool[_poolId][_user] = 0;
    }

    function withdraw() external onlyOwner {
        // Withdraw native tokens (ETH on most chains, S on Sonic)
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = owner().call{ value: balance }("");
            if (!success) revert TransferFailed();
        }

        // Also withdraw S tokens if on Sonic chain
        if (_isSonicChain()) {
            IERC20 sToken = IERC20(WRAPPED_S_TOKEN);
            uint256 sBalance = sToken.balanceOf(address(this));
            if (sBalance > 0) {
                bool success = sToken.transfer(owner(), sBalance);
                if (!success) revert TransferFailed();
            }
        }
    }

    // NEW: Admin function to set S token contract address (if needed)
    function setSTokenAddress(address _sTokenAddress) external onlyOwner {
        if (_sTokenAddress == address(0)) revert InvalidAddress();

        address oldAddress = WRAPPED_S_TOKEN;
        WRAPPED_S_TOKEN = _sTokenAddress;

        emit STokenAddressUpdated(oldAddress, _sTokenAddress);
    }

    // ========== VIEW FUNCTIONS ==========
    function getPoolInfo(uint8 _poolId) external view returns (PoolInfo memory) {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        return pools[_poolId];
    }

    function getAvailablePools() external view returns (uint8[] memory) {
        uint8[] memory availablePools = new uint8[](MAX_POOLS);
        uint8 count = 0;
        for (uint8 i = 1; i <= MAX_POOLS; i++) {
            if (pools[i].enabled) {
                availablePools[count] = i;
                count++;
            }
        }
        // Resize array
        uint8[] memory result = new uint8[](count);
        for (uint8 i = 0; i < count; i++) {
            result[i] = availablePools[i];
        }
        return result;
    }

    function getUserMintInfo(address _user) external view returns (bool hasGlobalMint, uint32 chainMintedOn) {
        return (hasMintedGlobal[_user], mintedOnChain[_user]);
    }

    // NEW: Get user's mint count for a specific pool
    function getUserMintCount(address _user, uint8 _poolId) external view returns (uint256) {
        if (_poolId < 1 || _poolId > MAX_POOLS) revert InvalidPoolId();
        return mintCountPerPool[_poolId][_user];
    }

    // ========== RECEIVE FUNCTION ==========
    // This function only receives funds without minting any tokens
    receive() external payable nonReentrant {
        // Simply accept the payment without minting
        // Funds can be withdrawn later by the contract owner using the withdraw() function
        emit Debug("Funds received", msg.sender, msg.value, block.timestamp);
    }
}
