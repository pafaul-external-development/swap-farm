pragma ton-solidity >= 0.43.0;

import './interfaces/IUserAccount.sol';

import './libraries/UserAccountErrorCodes.sol';
import './libraries/UserAccountCostConstants.sol';

import '../FarmContract/interfaces/IFarmContract.sol';

import '../utils/TIP3/interfaces/ITokensReceivedCallback.sol';
import '../utils/TIP3/interfaces/ITONTokenWallet.sol';
import '../utils/TIP3/interfaces/IRootTokenContract.sol';

/**
 * Процесс деплоя:
 * Создание контракта (constructor)
 */

 /**
  * Процесс входа в фармилку:
  * Запрос информации о фармилке
  * Запись инофрмации о фармилке
  * Деплой пустого кошелька для приёма платежей пользователя
  * Настройка кошелька -> запрет на переводы без notify_receiver
  */

contract UserAccount is ITokensReceivedCallback, IUserAccount {

    address static owner;

    mapping (address => UserFarmInfo) farmInfo;
    mapping (address => address) knownTokenRoots;

    // Service value
    TvmCell empty;

    constructor() public {
        tvm.accept();
        address(owner).transfer({value: 0, flag: 64});
    }

    /**
     * @param farm Address of farm contract
     * @param stackingTIP3UserWallet User's wallet with stacking tokens
     * @param rewardTIP3Wallet User's wallet for reward payouts
     */
    function enterFarm(
        address farm, 
        address stackingTIP3UserWallet, 
        address rewardTIP3Wallet
    ) external override onlyOwner onlyUnknownFarm(farm) addressNotZero(farm) addressNotZero(stackingTIP3UserWallet) addressNotZero(rewardTIP3Wallet) {
        farmInfo[farm] = UserFarmInfo({
            stackedTokens: 0,
            pendingReward: 0,
            rewardPerTokenSum: 0,

            stackingTIP3Wallet: address.makeAddrStd(0, 0),
            stackingTIP3UserWallet: stackingTIP3UserWallet,
            stackingTIP3Root: address.makeAddrStd(0, 0),
            rewardTIP3Wallet: rewardTIP3Wallet,

            start: 0,
            finish: 0
        });

        IFarmContract(farm).fetchInfo{
            flag: 64,
            callback: this.receiveFarmInfo
        }();
    }

    /**
     * @param farmInfo_ Information about farm
     */
    function receiveFarmInfo(FarmInfo farmInfo_) external onlyKnownFarm(msg.sender) {
        address farm = msg.sender;
        farmInfo[farm].stackingTIP3Root = farmInfo_.stackingTIP3Root;
        farmInfo[farm].start = farmInfo_.startTime;
        farmInfo[farm].finish = farmInfo_.finishTime;
        knownTokenRoots[farmInfo_.stackingTIP3Root] = farm;

        IRootTokenContract(farmInfo_.stackingTIP3Root).getWalletAddress{
            value: UserAccountCostConstants.getWalletAddress,
            callback: this.receiveTIP3Address
        }({
            wallet_public_key: 0,
            owner_address: address(this)
        });

        IRootTokenContract(farmInfo_.stackingTIP3Root).deployEmptyWallet{
            flag: 64
        }({
            deploy_grams: UserAccountCostConstants.deployTIP3Wallet,
            wallet_public_key: 0,
            owner_address: address(this),
            gas_back_address: owner
        });
    }

    /**
     * @param stackingTIP3Wallet Wallet required for receiving user's stacking
     */
    function receiveTIP3Address(address stackingTIP3Wallet) external onlyKnownTokenRoot {
        tvm.accept();
        farmInfo[knownTokenRoots[msg.sender]].stackingTIP3Wallet = stackingTIP3Wallet;
        ITONTokenWallet(stackingTIP3Wallet).setReceiveCallback{
            value: UserAccountCostConstants.setReceiveCallback
        }({
            receive_callback: address(this),
            allow_non_notifiable: false
        });

        address(owner).transfer({flag: 64, value: 0});
    }

    function tokensReceivedCallback(
        address, // token_wallet,
        address token_root,
        uint128 amount,
        uint256, // sender_public_key,
        address, // sender_address,
        address sender_wallet,
        address original_gas_to,
        uint128, // updated_balance,
        TvmCell payload
    ) external override {
        TvmSlice s = payload.toSlice();
        address farm = s.decode(address);

        bool messageIsCorrect = 
            msg.sender == farmInfo[farm].stackingTIP3Wallet && 
            token_root == farmInfo[farm].stackingTIP3Root && 
            sender_wallet == farmInfo[farm].stackingTIP3UserWallet &&
            farmInfo.exists(farm) &&
            farmInfo[farm].start <= uint64(now);

        if (!messageIsCorrect) {
            ITONTokenWallet(msg.sender).transfer{
                flag: 64
            }({
                to: sender_wallet,
                tokens: amount,
                grams: 0,
                send_gas_to: original_gas_to,
                notify_receiver: true,
                payload: payload
            });
        } else {
            farmInfo[farm].stackedTokens = farmInfo[farm].stackedTokens + amount;

            IFarmContract(farm).tokensDepositedToFarm{
                flag: 64
            }({
                userAccountOwner: owner, 
                tokensDeposited: amount, 
                tokensAmount: farmInfo[farm].stackedTokens - amount, 
                pendingReward: farmInfo[farm].pendingReward, 
                rewardPerTokenSum: farmInfo[farm].rewardPerTokenSum
            });    
        }
    }

    /**
     * @param farm Address of farm contract
     */
    function withdrawPendingReward(
        address farm
    ) external override onlyOwner {
        IFarmContract(farm).withdrawPendingReward{
            flag: 64
        }({
            userAccountOwner: owner, 
            tokenAmount: farmInfo[farm].stackedTokens, 
            pendingReward: farmInfo[farm].pendingReward, 
            rewardPerTokenSum: farmInfo[farm].rewardPerTokenSum, 
            rewardWallet: farmInfo[farm].rewardTIP3Wallet
        });
    }

    /**
     * @param farm Address of farm contract
     * @param tokensToWithdraw How much tokens will be withdrawed from stack 
     */
    function withdrawPartWithPendingReward(
        address farm, 
        uint128 tokensToWithdraw
    ) external override onlyOwner onlyKnownFarm(farm) onlyActiveFarm(farm) {
        farmInfo[farm].stackedTokens = farmInfo[farm].stackedTokens - tokensToWithdraw;
        
        transferTokensBack(farm, tokensToWithdraw);

        IFarmContract(farm).withdrawWithPendingReward{
            flag: 64
        }({
            userAccountOwner: owner, 
            tokensToWithdraw: tokensToWithdraw, 
            originalTokensAmount: farmInfo[farm].stackedTokens + tokensToWithdraw, 
            pendingReward: farmInfo[farm].pendingReward, 
            rewardPerTokenSum: farmInfo[farm].rewardPerTokenSum, 
            rewardWallet: farmInfo[farm].rewardTIP3Wallet
        });
    }

    /**
     * @param farm Address of farm contract
     */
    function withdrawAllWithPendingReward(
        address farm
    ) external override onlyOwner onlyKnownFarm(farm) onlyActiveFarm(farm) {
        require(msg.sender == owner);
        uint128 tokensToWithdraw = farmInfo[farm].stackedTokens;
        farmInfo[farm].stackedTokens = 0;

        transferTokensBack(farm, tokensToWithdraw);

        IFarmContract(farm).withdrawWithPendingReward{
            flag: 64
        }({
            userAccountOwner: owner, 
            tokensToWithdraw: tokensToWithdraw, 
            originalTokensAmount: tokensToWithdraw,
            pendingReward: farmInfo[farm].pendingReward, 
            rewardPerTokenSum: farmInfo[farm].rewardPerTokenSum, 
            rewardWallet: farmInfo[farm].rewardTIP3Wallet
        });
    }

    /**
     * @param farm Address of farm contract
     * @param tokenAmount Amount of tokens to transfer back to user
     */
    function transferTokensBack(address farm, uint128 tokenAmount) internal view {
        ITONTokenWallet(farmInfo[farm].stackingTIP3UserWallet).transfer{
            value: UserAccountCostConstants.transferTokens
        }({
            to: farmInfo[farm].stackingTIP3UserWallet,
            tokens: tokenAmount,
            grams: 0,
            send_gas_to: owner,
            notify_receiver: true,
            payload: empty
        });
    }

    /**
     * @param farm Address of farm contract
     */
    function updateReward(
        address farm
    ) external override onlyOwner {
        IFarmContract(farm).updateUserReward{
            flag: 64
        }({
            userAccountOwner: owner, 
            tokenAmount: farmInfo[farm].stackedTokens, 
            pendingReward: farmInfo[farm].pendingReward, 
            rewardPerTokenSum: farmInfo[farm].rewardPerTokenSum
        });
    }

    /**
     * @param userReward User current reward after update
     * @param rewardPerTokenSum Last known value of reward per token summed
     */
    function udpateRewardInfo(
        uint128 userReward, 
        uint128 rewardPerTokenSum
    ) external override onlyKnownFarm(msg.sender) {
        farmInfo[msg.sender].pendingReward = userReward;
        farmInfo[msg.sender].rewardPerTokenSum = rewardPerTokenSum;

        address(owner).transfer({flag: 64, value: 0});
    }

    /**
     * @param farm Address of farm contract
     */
    function getUserFarmInfo(
        address farm
    ) external override responsible onlyKnownFarm(farm) returns (UserFarmInfo) {
        return {flag: 64} farmInfo[farm];
    }

    function getAllUserFarmInfo() external override responsible returns (mapping(address => UserFarmInfo)) {
        return {flag: 64} farmInfo;
    }

    /**
     * @param farm Address of farm contract
     */
    function createPayload(
        address farm
    ) external override responsible onlyKnownFarm(farm) returns(TvmCell) {
        TvmBuilder builder;
        builder.store(farm);
        return builder.toCell();
    }

    modifier onlyOwner() {
        require(msg.sender == owner, UserAccountErrorCodes.ERROR_ONLY_OWNER);
        _;
    } 

    /**
     * @param farm Address of farm contract
     */
    modifier onlyKnownFarm(address farm) {
        require(farmInfo.exists(farm), UserAccountErrorCodes.ERROR_ONLY_KNOWN_FARM);
        _;
    }

    /**
     * @param farm Address of farm contract
     */
    modifier onlyUnknownFarm(address farm) {
        require(!farmInfo.exists(farm), UserAccountErrorCodes.ERROR_ONLY_UNKNOWN_FARM);
        _;
    }

    modifier onlyKnownTokenRoot() {
        require(knownTokenRoots.exists(msg.sender), UserAccountErrorCodes.ERROR_ONLY_KNOWN_TOKEN_ROOT);
        _;
    }

    /**
     * @param farm Address of farm contract
     */
    modifier onlyActiveFarm(address farm) {
        require(farmInfo[farm].start <= uint64(now), UserAccountErrorCodes.ERROR_ONLY_ACTIVE_FARM);
        _;
    }

    /**
     * @param addr Address to check
     */
    modifier addressNotZero(address addr) {
        require(addr != address.makeAddrStd(0, 0), UserAccountErrorCodes.ERROR_ZERO_ADDRESS);
        _;
    }
}