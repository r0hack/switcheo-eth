pragma solidity 0.5.10;

import "./lib/math/SafeMath.sol";
import "./lib/ownership/Ownable.sol";
import "./lib/introspection/IERC1820Registry.sol";

contract ERC20Token {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract BrokerV2 is Ownable {
    using SafeMath for uint256;

    struct WithdrawalAnnouncement {
        uint256 amount;
        uint256 withdrawableAt;
    }

    enum State { Active, Inactive }
    enum AdminState { Normal, Escalated }

    bytes32 public constant CONTRACT_NAME = keccak256("Switcheo Exchange");
    bytes32 public constant CONTRACT_VERSION = keccak256("2");
    // TODO: update this before deployment
    uint256 public constant CHAIN_ID = 3;
    // TODO: pre-calculate and update this before deployment
    address public constant VERIFYING_CONTRACT = address(1);
    bytes32 public constant SALT = keccak256("switcheo-eth-eip712-salt");

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(abi.encodePacked(
        "EIP712Domain(",
            "string name,",
            "string version,",
            "uint256 chainId,",
            "address verifyingContract,",
            "bytes32 salt",
        ")"
    ));

    // DOMAIN_SEPARATOR: 0x14f697e312cdba1c10a1eb5c87d96fa22b63aef9dc39592568387471319ea630
    bytes32 public constant DOMAIN_SEPARATOR = keccak256(abi.encode(
        EIP712_DOMAIN_TYPEHASH,
        CONTRACT_NAME,
        CONTRACT_VERSION,
        CHAIN_ID,
        VERIFYING_CONTRACT,
        SALT
    ));

    bytes32 public constant AUTHORIZE_SPENDER_TYPEHASH = keccak256(abi.encodePacked(
        "AuthorizeSpender(",
            "address user,",
            "address spender,",
            "uint256 nonce",
        ")"
    ));

    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(abi.encodePacked(
        "Withdraw(",
            "address withdrawer,",
            "address assetId,",
            "uint256 amount,",
            "address feeAssetId,",
            "uint256 feeAmount,",
            "uint256 nonce",
        ")"
    ));

    // OFFER_TYPEHASH: 0xf845c83a8f7964bc8dd1a092d28b83573b35be97630a5b8a3b8ae2ae79cd9260
    bytes32 public constant OFFER_TYPEHASH = keccak256(abi.encodePacked(
        "Offer(",
            "address maker,",
            "address offerAssetId,",
            "uint256 offerAmount,",
            "address wantAssetId,",
            "uint256 wantAmount,",
            "address feeAssetId,",
            "uint256 feeAmount,",
            "uint256 nonce",
        ")"
    ));

    // FILL_TYPEHASH: 0x5f59dbc3412a4575afed909d028055a91a4250ce92235f6790c155a4b2669e99
    bytes32 public constant FILL_TYPEHASH = keccak256(abi.encodePacked(
        "Fill(",
            "address filler,",
            "address offerAssetId,",
            "uint256 offerAmount,",
            "address wantAssetId,",
            "uint256 wantAmount,",
            "address feeAssetId,",
            "uint256 feeAmount,",
            "uint256 nonce",
        ")"
    ));

    bytes32 public constant SWAP_TYPEHASH = keccak256(abi.encodePacked(
        "Swap(",
            "address maker,",
            "address taker,",
            "address assetId,",
            "uint256 amount,",
            "bytes32 hashedSecret,",
            "uint256 expiryTime,",
            "address feeAssetId,",
            "uint256 feeAmount,",
            "uint256 nonce",
        ")"
    ));

    // Ether token "address" is set as the constant 0x00
    address private constant ETHER_ADDR = address(0);

    // deposits
    uint256 private constant REASON_DEPOSIT = 0x01;
    uint256 private constant REASON_MAKER_GIVE = 0x02;
    uint256 private constant REASON_FILLER_GIVE = 0x03;
    uint256 private constant REASON_FILLER_FEE_GIVE = 0x04;
    uint256 private constant REASON_FILLER_RECEIVE = 0x05;
    uint256 private constant REASON_MAKER_RECEIVE = 0x06;
    uint256 private constant REASON_FILLER_FEE_RECEIVE = 0x07;
    uint256 private constant REASON_MAKER_FEE_GIVE = 0x10;
    uint256 private constant REASON_MAKER_FEE_RECEIVE = 0x11;
    uint256 private constant REASON_WITHDRAW = 0x09;
    uint256 private constant REASON_WITHDRAW_FEE_GIVE = 0x14;
    uint256 private constant REASON_WITHDRAW_FEE_RECEIVE = 0x15;
    uint256 private constant REASON_SWAP_GIVE = 0x30;
    uint256 private constant REASON_SWAP_RECEIVE = 0x35;
    uint256 private constant REASON_SWAP_FEE_GIVE = 0x36;
    uint256 private constant REASON_SWAP_FEE_RECEIVE = 0x37;
    uint256 private constant REASON_SWAP_CANCEL_RECEIVE = 0x38;
    uint256 private constant REASON_SWAP_CANCEL_FEE_RECEIVE = 0x3B;
    uint256 private constant REASON_SWAP_CANCEL_FEE_REFUND = 0x3D;

    uint256 private constant MAX_SLOW_WITHDRAW_DELAY = 604800;


    State public state; // position 0
    AdminState public adminState; // position 1
    // The operator receives fees
    address public operator; // position 2

    uint256 public slowWithdrawDelay; // position 3
    uint256 public slowCancelDelay; // position 4

    mapping(bytes32 => uint256) public offers; // position 5
    mapping(uint256 => uint256) public usedNonces; // position 6
    mapping(address => mapping(address => uint256)) public balances; // position 7

    mapping(address => bool) adminAddresses;
    mapping(bytes32 => bool) public atomicSwaps;
    mapping(address => bool) public tokenWhitelist;
    mapping(address => bool) public spenderWhitelist;
    mapping(address => mapping(address => bool)) public spenderAuthorizations;
    mapping(address => mapping(address => WithdrawalAnnouncement)) public withdrawlAnnouncements;

    // Emitted on any balance state transition (+ve)
    event BalanceIncrease(
        address indexed user,
        address indexed assetId,
        uint256 amount,
        uint256 indexed reason,
        uint256 nonceA,
        uint256 nonceB
    );

    // Emitted on any balance state transition (-ve)
    event BalanceDecrease(
        address indexed user,
        address indexed assetId,
        uint256 amount,
        uint256 indexed reason,
        uint256 nonceA,
        uint256 nonceB
    );

    event AddAdmin(address indexed admin);
    event RemoveAdmin(address indexed admin);
    event WhitelistToken(address indexed assetId);
    event UnwhitelistToken(address indexed assetId);
    event AddSpender(address indexed spender);
    event RemoveSpender(address indexed spender);

    event AuthorizeSpender(
        address indexed user,
        address indexed spender,
        uint256 nonce
    );

    event UnauthorizeSpender(address indexed user, address indexed spender);

    event SpendFrom(
        address indexed from,
        address indexed to,
        address indexed assetId,
        uint256 amount
    );

    event Deposit(address indexed user, uint256 amount);

    event DepositToken(
        address indexed user,
        address indexed assetId,
        uint256 amount,
        uint256 nonce
    );

    event TokenFallback(
        address indexed user,
        address indexed assetId,
        uint256 amount
    );

    event TokensReceived(
        address indexed user,
        address indexed assetId,
        uint256 amount
    );

    event Withdraw(
        address withdrawer,
        address assetId,
        uint256 amount,
        address feeAssetId,
        uint256 feeAmount,
        uint256 nonce
    );

    event AdminWithdraw(
        address indexed withdrawer,
        address indexed assetId,
        uint256 amount
    );

    event AnnounceWithdraw(
        address indexed withdrawer,
        address indexed assetId,
        uint256 amount,
        uint256 withdrawableAt
    );

    event SlowWithdraw(
        address indexed withdrawer,
        address indexed assetId,
        uint256 amount
    );

    event CreateSwap(
        address indexed maker,
        address indexed taker,
        address assetId,
        uint256 amount,
        bytes32 indexed hashedSecret,
        uint256 expiryTime,
        address feeAssetId,
        uint256 feeAmount,
        uint256 nonce
    );

    event ExecuteSwap(
        address indexed maker,
        address indexed taker,
        address assetId,
        uint256 amount,
        bytes32 indexed hashedSecret,
        uint256 expiryTime,
        address feeAssetId,
        uint256 feeAmount,
        uint256 nonce,
        bytes preimage
    );

    event CancelSwap(
        address indexed maker,
        address indexed taker,
        address assetId,
        uint256 amount,
        bytes32 indexed hashedSecret,
        uint256 expiryTime,
        address feeAssetId,
        uint256 feeAmount,
        uint256 nonce,
        uint256 cancelFeeAmount
    );

    constructor() public {
        adminAddresses[msg.sender] = true;
        operator = msg.sender;

        slowWithdrawDelay = MAX_SLOW_WITHDRAW_DELAY;

        IERC1820Registry erc1820 = IERC1820Registry(
            0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24
        );

        erc1820.setInterfaceImplementer(
            address(this),
            keccak256("ERC777TokensRecipient"),
            address(this)
        );
    }

    modifier onlyAdmin() {
        require(adminAddresses[msg.sender], "Invalid sender");
        _;
    }

    modifier onlyActiveState() {
        require(state == State.Active, "Invalid state");
        _;
    }

    modifier onlyEscalatedAdminState() {
        require(adminState == AdminState.Escalated, "Invalid state");
        _;
    }

    function setState(State _state) external onlyOwner { state = _state; }
    function setAdminState(AdminState _state) external onlyOwner { adminState = _state; }

    function setOperator(address _operator) external onlyOwner {
        _validateAddress(operator);
        operator = _operator;
    }

    function setSlowWithdrawDelay(uint256 _delay) external onlyOwner {
        require(_delay <= MAX_SLOW_WITHDRAW_DELAY, "Invalid delay");
        slowWithdrawDelay = _delay;
    }

    function addAdmin(address _admin) external onlyOwner {
        _validateAddress(_admin);
        require(!adminAddresses[_admin], "Admin already added");
        adminAddresses[_admin] = true;
        emit AddAdmin(_admin);
    }

    function removeAdmin(address _admin) external onlyOwner {
        _validateAddress(_admin);
        require(adminAddresses[_admin], "Admin not yet added");
        delete adminAddresses[_admin];
        emit RemoveAdmin(_admin);
    }

    function whitelistToken(address _assetId) external onlyOwner {
        _validateAddress(_assetId);
        require(!tokenWhitelist[_assetId], "Token already whitelisted");
        tokenWhitelist[_assetId] = true;
        emit WhitelistToken(_assetId);
    }

    function unwhitelistToken(address _assetId) external onlyOwner {
        _validateAddress(_assetId);
        require(tokenWhitelist[_assetId], "Token not yet whitelisted");
        delete tokenWhitelist[_assetId];
        emit UnwhitelistToken(_assetId);
    }

    function whitelistSpender(address _spender) external onlyOwner {
        _validateAddress(_spender);
        require(!spenderWhitelist[_spender], "Spender already added");
        spenderWhitelist[_spender] = true;
        emit AddSpender(_spender);
    }

    function unwhitelistSpender(address _spender) external onlyOwner {
        _validateAddress(_spender);
        require(spenderWhitelist[_spender], "Spender not yet added");
        delete spenderWhitelist[_spender];
        emit RemoveSpender(_spender);
    }

    function authorizeSpender(
        address _user,
        address _spender,
        uint256 _nonce,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    )
        external
        onlyAdmin
    {
        require(spenderWhitelist[_spender], "Invalid spender");
        _markNonce(_nonce);

        _validateSignature(_user, _v, _r, _s,
            keccak256(abi.encode(
                AUTHORIZE_SPENDER_TYPEHASH,
                _user,
                _spender,
                _nonce
            ))
        );
        spenderAuthorizations[_user][_spender] = true;
        emit AuthorizeSpender(_user, _spender, _nonce);
    }

    function unauthorizeSpender(address _spender) external {
        require(!spenderWhitelist[_spender], "Spender still active");

        address user = msg.sender;
        require(
            spenderAuthorizations[user][_spender],
            "Spender not yet authorized"
        );

        delete spenderAuthorizations[user][_spender];
        emit UnauthorizeSpender(user, _spender);
    }

    function spendFrom(
        address _from,
        address _to,
        address _assetId,
        uint256 _amount
    )
        external
    {
        require(
            spenderAuthorizations[_from][msg.sender],
            "Spender not yet approved"
        );

        _validateAddress(_to);

        balances[_from][_assetId] = balances[_from][_assetId].sub(_amount);
        balances[_to][_assetId] = balances[_to][_assetId].add(_amount);

        emit SpendFrom(_from, _to, _assetId, _amount);
    }

    function deposit() external payable onlyActiveState {
        require(msg.value > 0, "Invalid value");
        _increaseBalance(msg.sender, ETHER_ADDR, msg.value, REASON_DEPOSIT, 0, 0);
        emit Deposit(msg.sender, msg.value);
    }

    function depositToken(
        address _user,
        address _assetId,
        uint256 _nonce
    )
        external
        onlyAdmin
        onlyActiveState
    {
        require(
            tokenWhitelist[_assetId] == false,
            "Whitelisted tokens cannot use this method of transfer"
        );
        _markNonce(_nonce);
        _validateContractAddress(_assetId);

        ERC20Token token = ERC20Token(_assetId);
        uint256 initialBalance = token.balanceOf(address(this));
        uint256 amount = token.allowance(_user, address(this));
        uint256 maxAmount = token.balanceOf(_user);

        // ensure that "amount" does not exceed what the user has
        if (amount > maxAmount) { amount = maxAmount; }
        if (amount == 0) { return; }

        // ERC20Token cannot be used for transferFrom calls because some
        // tokens have a transferFrom which returns a boolean and some do not
        // having two overloaded transferFrom methods does not work
        // as the signatures are the same but the return values are not
        bytes memory payload = abi.encodeWithSignature(
                                   "transferFrom(address,address,uint256)",
                                   _user,
                                   address(this),
                                   amount
                               );
        bytes memory returnData = _callContract(_assetId, payload);
        // ensure that asset transfer succeeded
        _validateTransferResult(returnData);

        uint256 finalBalance = token.balanceOf(address(this));
        uint256 transferredAmount = finalBalance - initialBalance;

        _increaseBalance(
            _user,
            _assetId,
            transferredAmount,
            REASON_DEPOSIT,
            _nonce,
            0
        );

        emit DepositToken(_user, _assetId, transferredAmount, _nonce);
    }

    // ERC223
    function tokenFallback(
        address _user,
        uint _amount,
        bytes calldata /* _data */
    )
        external
        onlyActiveState
    {
        address assetId = msg.sender;
        require(tokenWhitelist[assetId] == true, "Token not whitelisted");
        _increaseBalance(_user, assetId, _amount, REASON_DEPOSIT, 0, 0);
        emit TokenFallback(_user, assetId, _amount);
    }

    // ERC777
    function tokensReceived(
        address /* _operator */,
        address _user,
        address _to,
        uint _amount,
        bytes calldata /* _userData */,
        bytes calldata /* _operatorData */
    )
        external
        onlyActiveState
    {
        if (_to != address(this)) { return; }
        address assetId = msg.sender;
        require(tokenWhitelist[assetId] == true, "Token not whitelisted");
        _increaseBalance(_user, assetId, _amount, REASON_DEPOSIT, 0, 0);
        emit TokensReceived(_user, assetId, _amount);
    }

    // values = [
    //    * at index 0
    //    lengths // [0]
    //        numMakes, // bits(0..8)
    //        numFills, // bits(8..16)
    //        numMatches, // bits(16..24)
    //
    //    * starting at index 1
    //    * nonces must be sorted in ascending order
    //    make.dataA // [i]
    //        makerIndex, // bits(0..8)
    //        make.offerAssetIdIndex, // bits(8..16)
    //        make.wantAssetIdIndex, // bits(16..24)
    //        make.feeAssetIdIndex, // bits(24..32)
    //        make.v // bits(32..40)
    //        make.nonce // bits(40..128)
    //        make.feeAmount // bits(128..256)
    //    make.dataB // [i + 1]
    //        make.offerAmount, // bits(0..128)
    //        make.wantAmount, // bits(128..256)
    //
    //    * starting at index 1 + numMakes * 2
    //    * nonces must be sorted in ascending order
    //    fill.dataA // [i]
    //        fillerIndex, // bits(0..8)
    //        fill.offerAssetIdIndex, // bits(8..16)
    //        fill.wantAssetIdIndex, // bits(16..24)
    //        fill.feeAssetIdIndex, // bits(24..32)
    //        fill.v // bits(32..40)
    //        fill.nonce // bits(40..128)
    //        fill.feeAmount // bits(128..256)
    //    fill.dataB // [i + 1]
    //        fill.offerAmount, // bits(0..128)
    //        fill.wantAmount, // bits(128..256)
    //
    //    * starting at index 3 + numMakes * 5 + numFills * 5
    //    matchData
    //        match.makeIndex, // bits(0..8)
    //        match.fillIndex, // bits(6..16)
    //        match.takeAmount // bits(16..256)
    // ]
    //
    // hashes = [
    //     r, // 0
    //     s // 1
    // ]
    //
    // list of user addresses and assetIds
    // addresses = [
    //    account1,
    //    account2,
    //    assetId1,
    //    assetId2,
    // ]
    function trade(
        uint256[] memory _values,
        bytes32[] memory _hashes,
        address[] memory _addresses
    )
        public
        onlyAdmin
        onlyActiveState
    {
        // cache operator value
        _addresses[_addresses.length - 1] = operator;
        _validateTradeInputs(_values, _hashes, _addresses);
        // VALIDATE NONCE UNIQUENESS FOR MAKES (loop makes)
        // VALIDATE NONCE UNIQUENESS FOR FILLS (loop fills)
        _validateNonceUniqueness(_values);

        // VALIDATE MATCHES (loop matches)
        // VALIDATE FILL SIGNATURES AND AMOUNTS (loop fills)
        // VALIDATE MAKE SIGNATURES AND AMOUNTS (loop makes)
        // CACHE OFFERS (loop makes)
        // CACHE BALANCES (loop makes + fills)
        // VALIDATE BALANCE MAP UNIQUENESS (loop makes + fills)

        // INCREASE BALANCE OF FILLERS FOR FILL.WANT_AMOUNT (loop fills)
        // INCREASE BALANCE OF OPERATOR FOR FILL.FEE_AMOUNT (loop fills)
        _creditFillBalances(_values, _addresses);

        // INCREASE BALANCE OF MAKERS FOR RECEIVE_AMOUNT (loop matches)
        _creditMakerBalances(_values, _addresses);

        // INCREASE BALANCE OF OPERATOR FOR MAKE.FEE_AMOUNT (loop makes)
        _creditMakerFeeBalances(_values, _addresses);

        // DECREASE BALANCE OF FILLERS FOR FILL.OFFER_AMOUNT (loop fills)
        // DECREASE BALANCE OF FILLERS FOR FILL.FEE_AMOUNT (loop fills)
        _deductFillBalances(_values, _addresses);

        // DECREASE BALANCE OF MAKERS FOR MAKE.OFFER_AMOUNT (loop makes)
        // DECREASE BALANCE OF MAKERS FOR MAKE.FEE_AMOUNT (loop makes)
        _deductMakerBalances(_values, _addresses);

        // UPDATE CACHED NONCES WITH MAKE NONCES (loop makes)
        // DECREASE OFFERS BY MATCH.TAKE_AMOUNT (loop matches)
        // VALIDATE THAT FILL NONCES ARE NOT YET TAKEN (loop fills)
        // UPDATE CACHED NONCES WITH FILL NONCES (loop fills)
        // STORE NONCES (loop makes + fills)
        // STORE OFFERS (loop makes)
    }

    function _deductMakerBalances(
        uint256[] memory _values,
        address[] memory _addresses
    )
        private
    {
        uint256 i = 1;
        // i + numMakes * 2
        uint256 end = i + (_values[0] & ~(~uint256(0) << 8)) * 2;

        // loop makes
        for(i; i < end; i += 2) {
            uint256 nonce = (_values[i] & ~(~uint256(0) << 128)) >> 40;
            if (_nonceTaken(nonce)) { continue; }

            address maker = _addresses[_values[i] & ~(~uint256(0) << 8)];
            address offerAssetId = _addresses[(_values[i] & ~(~uint256(0) << 16)) >> 8];
            uint256 offerAmount = _values[i + 1] & ~(~uint256(0) << 128);

            balances[maker][offerAssetId] = balances[maker][offerAssetId].sub(offerAmount);

            address wantAssetId = _addresses[(_values[i] & ~(~uint256(0) << 24)) >> 16];
            address feeAssetId = _addresses[(_values[i] & ~(~uint256(0) << 32)) >> 24];
            uint256 feeAmount = _values[i] >> 128;
            if (wantAssetId != feeAssetId && feeAmount > 0) {
                balances[maker][feeAssetId] = balances[maker][feeAssetId].sub(feeAmount);
            }
        }
    }

    function _deductFillBalances(
        uint256[] memory _values,
        address[] memory _addresses
    )
        private
    {
        // 1 + numMakes * 2
        uint256 i = 1 + (_values[0] & ~(~uint256(0) << 8)) * 2;
        // i + numFills * 2
        uint256 end = i + ((_values[0] & ~(~uint256(0) << 16)) >> 8) * 2;

        // loop fills
        for(i; i < end; i += 2) {
            address filler = _addresses[_values[i] & ~(~uint256(0) << 8)];
            address offerAssetId = _addresses[(_values[i] & ~(~uint256(0) << 16)) >> 8];
            uint256 offerAmount = _values[i + 1] & ~(~uint256(0) << 128);

            address wantAssetId = _addresses[(_values[i] & ~(~uint256(0) << 24)) >> 16];
            address feeAssetId = _addresses[(_values[i] & ~(~uint256(0) << 32)) >> 24];
            uint256 feeAmount = _values[i] >> 128;

            balances[filler][offerAssetId] = balances[filler][offerAssetId].sub(offerAmount);

            if (wantAssetId != feeAssetId && feeAmount > 0) {
                balances[filler][feeAssetId] = balances[filler][feeAssetId].sub(feeAmount);
            }
        }
    }

    function _creditMakerFeeBalances(
        uint256[] memory _values,
        address[] memory _addresses
    )
        private
    {
        address operatorAddress = _addresses[_addresses.length - 1];
        uint256 i = 1;
        // i + numMakes * 2
        uint256 end = i + (_values[0] & ~(~uint256(0) << 8)) * 2;

        // loop makes
        for(i; i < end; i += 2) {
            uint256 nonce = (_values[i] & ~(~uint256(0) << 128)) >> 40;
            if (_nonceTaken(nonce)) { continue; }

            address feeAssetId = _addresses[(_values[i] & ~(~uint256(0) << 32)) >> 24];
            uint256 feeAmount = _values[i] >> 128;
            if (feeAmount > 0) {
                balances[operatorAddress][feeAssetId] = balances[operatorAddress][feeAssetId].add(feeAmount);
            }
        }
    }

    function _creditMakerBalances(
        uint256[] memory _values,
        address[] memory _addresses
    )
        private
    {
        uint256 i = 1;
        // i += numMakes * 2
        i += (_values[0] & ~(~uint256(0) << 8)) * 2;
        // i += numFills * 2
        i += ((_values[0] & ~(~uint256(0) << 16)) >> 8) * 2;

        uint256 end = _values.length;

        // loop matches
        for(i; i < end; i++) {
            uint256 makeIndex = _values[i] & ~(~uint256(0) << 8);
            address maker = _addresses[_values[1 + makeIndex * 2] & ~(~uint256(0) << 8)];
            address wantAssetId = _addresses[(_values[1 + makeIndex * 2] & ~(~uint256(0) << 24)) >> 16];

            // takeAmount
            uint256 amount = _values[i] >> 16;
            // receiveAmount = takeAmount * wantAmount / offerAmount
            amount = amount.mul(_values[2 + makeIndex * 2] >> 128)
                           .div(_values[2 + makeIndex * 2] & ~(~uint256(0) << 128));

            address feeAssetId = _addresses[(_values[1 + makeIndex * 2] & ~(~uint256(0) << 32)) >> 24];
            if (wantAssetId == feeAssetId) {
                amount = amount.sub(_values[1 + makeIndex * 2] >> 128);
            }
            balances[maker][wantAssetId] = balances[maker][wantAssetId].add(amount);
        }
    }

    function _creditFillBalances(
        uint256[] memory _values,
        address[] memory _addresses
    )
        private
    {
        address operatorAddress = _addresses[_addresses.length - 1];
        // 1 + numMakes * 2
        uint256 i = 1 + (_values[0] & ~(~uint256(0) << 8)) * 2;
        // i + numFills * 2
        uint256 end = i + ((_values[0] & ~(~uint256(0) << 16)) >> 8) * 2;

        // loop fills
        for(i; i < end; i += 2) {
            address filler = _addresses[_values[i] & ~(~uint256(0) << 8)];
            address wantAssetId = _addresses[(_values[i] & ~(~uint256(0) << 24)) >> 16];
            uint256 wantAmount = _values[i + 1] >> 128;

            address feeAssetId = _addresses[(_values[i] & ~(~uint256(0) << 32)) >> 24];
            uint256 feeAmount = _values[i] >> 128;

            if (wantAssetId == feeAssetId) { wantAmount -= feeAmount; }

            balances[filler][wantAssetId] = balances[filler][wantAssetId].add(wantAmount);

            if (feeAmount > 0) {
                balances[operatorAddress][feeAssetId] = balances[operatorAddress][feeAssetId].add(feeAmount);
            }
        }
    }

    function _validateTradeInputs(
        uint256[] memory _values,
        bytes32[] memory _hashes,
        address[] memory _addresses
    )
        private
        pure
    {
        uint256 numMakes = _values[0] & ~(~uint256(0) << 8);
        uint256 numFills = (_values[0] & ~(~uint256(0) << 16)) >> 8;
        uint256 numMatches = (_values[0] & ~(~uint256(0) << 24)) >> 16;

        // sanity check on input length so that we will not need safe math methods
        // for array index calculations
        require(
            numMakes + numFills + numMatches + _addresses.length < 10000,
            "Input too large"
        );

        require(
            numMakes > 0 && numFills > 0 && numMatches > 0,
            "Invalid input"
        );

        require(
            _values.length == 1 + numMakes * 2 + numFills * 2 + numMatches,
            "Invalid _values.length"
        );

        require(
            _hashes.length == (numMakes + numFills) * 2,
            "Invalid _hashes.length"
        );
    }

    function _validateNonceUniqueness(uint256[] memory _values) private pure {
        uint256 lengths = _values[0];
        uint256 numMakes = lengths & ~(~uint256(0) << 8);
        uint256 numFills = (lengths & ~(~uint256(0) << 16)) >> 8;
        _validateNonceUniquenessInSet(_values, 0, numMakes);
        _validateNonceUniquenessInSet(_values, numMakes, numFills);
    }

    function _validateNonceUniquenessInSet(
        uint256[] memory _values,
        uint256 start,
        uint256 length
    )
        private
        pure
    {
        uint256 prevNonce = 0;
        uint256 mask = ~(~uint256(0) << 128);

        start = start * 2 + 1;
        uint256 end = start + length * 2;

        for(uint256 i = start; i < end; i += 2) {
            uint256 nonce = (_values[i] & mask) >> 40;

            if (i == start) {
                prevNonce = nonce;
            } else {
                require(nonce > prevNonce, "Invalid nonces");
                prevNonce = nonce;
            }
        }
    }

    function withdraw(
        address payable _withdrawer,
        address _assetId,
        uint256 _amount,
        address _feeAssetId,
        uint256 _feeAmount,
        uint256 _nonce,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    )
        external
        onlyAdmin
        onlyActiveState
    {
        _markNonce(_nonce);

        _validateSignature(_withdrawer, _v, _r, _s,
            keccak256(abi.encode(
                WITHDRAW_TYPEHASH,
                _withdrawer,
                _assetId,
                _amount,
                _feeAssetId,
                _feeAmount,
                _nonce
            ))
        );

        _withdraw(
            _withdrawer,
            _assetId,
            _amount,
            _feeAssetId,
            _feeAmount,
            _nonce
        );

        emit Withdraw(
            _withdrawer,
            _assetId,
            _amount,
            _feeAssetId,
            _feeAmount,
            _nonce
        );
    }

    function adminWithdraw(
        address payable _withdrawer,
        address _assetId,
        uint256 _amount
    )
        external
        onlyAdmin
        onlyEscalatedAdminState
    {
        _withdraw(_withdrawer, _assetId, _amount, address(0), 0, 0);
        emit AdminWithdraw(_withdrawer, _assetId, _amount);
    }

    function announceWithdraw(
        address _assetId,
        uint256 _amount
    )
        external
    {
        require(
            _amount > 0 && _amount <= balances[msg.sender][_assetId],
            "Invalid amount"
        );

        WithdrawalAnnouncement storage announcement = withdrawlAnnouncements[msg.sender][_assetId];

        uint256 withdrawableAt = now + slowWithdrawDelay;
        announcement.withdrawableAt = withdrawableAt;
        announcement.amount = _amount;

        emit AnnounceWithdraw(msg.sender, _assetId, _amount, withdrawableAt);
    }

    function slowWithdraw(
        address payable _withdrawer,
        address _assetId
    )
        external
    {
        WithdrawalAnnouncement memory announcement = withdrawlAnnouncements[msg.sender][_assetId];
        uint256 amount = announcement.amount;

        require(amount > 0, "Invalid amount");
        require(
            announcement.withdrawableAt != 0 && announcement.withdrawableAt <= now,
            "Insufficient delay"
        );

        delete withdrawlAnnouncements[_withdrawer][_assetId];
        _withdraw(_withdrawer, _assetId, amount, address(0), 0, 0);
        emit SlowWithdraw(_withdrawer, _assetId, amount);
    }

    // _addresses => [0]: maker, [1]: taker, [2]: assetId, [3]: feeAssetId
    // _values => [0]: amount, [1]: expiryTime, [2]: feeAmount, [3]: nonce
    // _hashes => [0]: hashedSecret, [1]: r, [2]: s
    function createSwap(
        address[4] calldata _addresses,
        uint256[4] calldata _values,
        bytes32[3] calldata _hashes,
        uint8 _v
    )
        external
        onlyAdmin
        onlyActiveState
    {
        require(_values[0] > 0, "Invalid amount");
        require(_values[1] > now, "Invalid expiry time");
        _markNonce(_values[3]);

        bytes32 swapHash = _hashSwap(_addresses, _values, _hashes[0]);

        require(!atomicSwaps[swapHash], "Invalid swap");
        _validateSignature(_addresses[0], _v, _hashes[1], _hashes[2], swapHash);

        if (_addresses[3] == _addresses[2]) { // feeAssetId == assetId
            require(_values[2] < _values[0], "Invalid fee amount"); // feeAmount < amount
        } else {
            _decreaseBalance(
                _addresses[0], // maker
                _addresses[3], // feeAssetId
                _values[2], // feeAmount
                REASON_SWAP_FEE_GIVE,
                _values[3], // nonce
                0
            );
        }

        _decreaseBalance(
            _addresses[0], // maker
            _addresses[2], // assetId
            _values[0], // amount
            REASON_SWAP_GIVE,
            _values[3], // nonce
            0
        );


        atomicSwaps[swapHash] = true;

        emit CreateSwap(
            _addresses[0], // maker
            _addresses[1], // taker
            _addresses[2], // assetId
            _values[0], // amount
            _hashes[0], // hashedSecret
            _values[1], // expiryTime
            _addresses[3], // feeAssetId
            _values[2], // feeAmount
            _values[3] // nonce
        );
    }

    // _addresses => [0]: maker, [1]: taker, [2]: assetId, [3]: feeAssetId
    // _values => [0]: amount, [1]: expiryTime, [2]: feeAmount, [3]: nonce
    function executeSwap(
        address[4] calldata _addresses,
        uint256[4] calldata _values,
        bytes32 _hashedSecret,
        bytes calldata _preimage
    )
        external
    {
        bytes32 swapHash = _hashSwap(_addresses, _values, _hashedSecret);
        require(atomicSwaps[swapHash], "Swap is not active");
        require(
            sha256(abi.encodePacked(sha256(_preimage))) == _hashedSecret,
            "Invalid preimage"
        );

        uint256 takeAmount = _values[0];
        if (_addresses[3] == _addresses[2]) { // feeAssetId == assetId
            takeAmount = takeAmount.sub(_values[2]);
        }

        delete atomicSwaps[swapHash];

        _increaseBalance(
            _addresses[1], // taker
            _addresses[2], // assetId
            takeAmount,
            REASON_SWAP_RECEIVE,
            _values[3], // nonce
            0
        );

        _increaseBalance(
            operator,
            _addresses[3], // feeAssetId
            _values[2], // feeAmount
            REASON_SWAP_FEE_RECEIVE,
            _values[3], // nonce
            0
        );

        emit ExecuteSwap(
            _addresses[0], // maker
            _addresses[1], // taker
            _addresses[2], // assetId
            _values[0], // amount
            _hashedSecret, // hashedSecret
            _values[1], // expiryTime
            _addresses[3], // feeAssetId
            _values[2], // feeAmount
            _values[3], // nonce
            _preimage
        );
    }

    // _addresses => [0]: maker, [1]: taker, [2]: assetId, [3]: feeAssetId
    // _values => [0]: amount, [1]: expiryTime, [2]: feeAmount, [3]: nonce
    function cancelSwap(
        address[4] calldata _addresses,
        uint256[4] calldata _values,
        bytes32 _hashedSecret,
        uint256 _cancelFeeAmount
    )
        external
    {
        require(_values[1] <= now, "Swap not yet expired");
        bytes32 swapHash = _hashSwap(_addresses, _values, _hashedSecret);
        require(atomicSwaps[swapHash], "Swap is not active");

        uint256 cancelFeeAmount = _cancelFeeAmount;
        if (!adminAddresses[msg.sender]) { cancelFeeAmount = _values[2]; }

        require(
            cancelFeeAmount <= _values[2], // cancelFeeAmount < feeAmount
            "Invalid cancel fee amount"
        );

        uint256 refundAmount = _values[0];
        if (_addresses[3] == _addresses[2]) { // feeAssetId == assetId
            refundAmount = refundAmount.sub(cancelFeeAmount);
        }

        delete atomicSwaps[swapHash];

        _increaseBalance(
            _addresses[0], // maker
            _addresses[2], // assetId
            refundAmount,
            REASON_SWAP_CANCEL_RECEIVE,
            _values[3], // nonce
            0
        );

        _increaseBalance(
            operator,
            _addresses[3], // feeAssetId
            cancelFeeAmount,
            REASON_SWAP_CANCEL_FEE_RECEIVE,
            _values[3],
            0
        );

        if (_addresses[3] != _addresses[2]) { // feeAssetId != assetId
            uint256 refundFeeAmount = _values[2].sub(cancelFeeAmount);
            _increaseBalance(
                _addresses[0], // maker
                _addresses[3], // feeAssetId
                refundFeeAmount,
                REASON_SWAP_CANCEL_FEE_REFUND,
                _values[3],
                0
            );
        }

        emit CancelSwap(
            _addresses[0], // maker
            _addresses[1], // taker
            _addresses[2], // assetId
            _values[0], // amount
            _hashedSecret, // hashedSecret
            _values[1], // expiryTime
            _addresses[3], // feeAssetId
            _values[2], // feeAmount
            _values[3], // nonce
            cancelFeeAmount // cancelFeeAmount
        );
    }

    function _hashSwap(
        address[4] memory _addresses,
        uint256[4] memory _values,
        bytes32 _hashedSecret
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(
                            SWAP_TYPEHASH,
                            _addresses[0], // maker
                            _addresses[1], // taker
                            _addresses[2], // assetId
                            _values[0], // amount
                            _hashedSecret, // hashedSecret
                            _values[1], // expiryTime
                            _addresses[3], // feeAssetId
                            _values[2], // feeAmount
                            _values[3] // nonce
                        ));
    }

    function _withdraw(
        address payable _withdrawer,
        address _assetId,
        uint256 _amount,
        address _feeAssetId,
        uint256 _feeAmount,
        uint256 _nonce
    )
        private
    {
        require(_amount > 0, 'Invalid amount');

        uint256 withdrawAmount = _decreaseBalanceWithFees(
            _withdrawer,
            _assetId,
            _amount,
            _feeAssetId,
            _feeAmount,
            REASON_WITHDRAW,
            REASON_WITHDRAW_FEE_GIVE,
            REASON_WITHDRAW_FEE_RECEIVE,
            _nonce,
            0
        );

        if (_assetId == ETHER_ADDR) {
            _withdrawer.transfer(withdrawAmount);
            return;
        }

        _validateContractAddress(_assetId);

        bytes memory payload = abi.encodeWithSignature(
                                   "transfer(address,uint256)",
                                   _withdrawer,
                                   withdrawAmount
                               );
        bytes memory returnData = _callContract(_assetId, payload);

        // ensure that asset transfer succeeded
        _validateTransferResult(returnData);
    }

    function _nonceTaken(uint256 _nonce) private view returns (bool) {
        uint256 slotData = _nonce.div(256);
        uint256 shiftedBit = 1 << _nonce.mod(256);
        uint256 bits = usedNonces[slotData];

        return bits & shiftedBit != 0;
    }

    function _markNonce(uint256 _nonce) private {
        require(_nonce != 0, "Invalid nonce");

        uint256 slotData = _nonce.div(256);
        uint256 shiftedBit = 1 << _nonce.mod(256);
        uint256 bits = usedNonces[slotData];

        require(bits & shiftedBit == 0, "Nonce already used");

        usedNonces[slotData] = bits | shiftedBit;
    }

    function _validateSignature(
        address _user,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        bytes32 _hash
    )
        private
        pure
    {
        bytes32 eip712Hash = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            _hash
        ));
        require(_user == ecrecover(eip712Hash, _v, _r, _s), "Invalid signature");
    }

    function _callContract(
        address _contract,
        bytes memory _payload
    )
        private
        returns (bytes memory)
    {
        bool success;
        bytes memory returnData;

        (success, returnData) = _contract.call(_payload);
        require(success, "contract call failed");

        return returnData;
    }

    // returns remaining amount after fees
    function _decreaseBalanceWithFees(
        address _user,
        address _assetId,
        uint256 _amount,
        address _feeAssetId,
        uint256 _feeAmount,
        uint256 _reasonCode,
        uint256 _feeGiveReasonCode,
        uint256 _feeReceiveReasonCode,
        uint256 _nonceA,
        uint256 _nonceB
    )
        private
        returns (uint256)
    {
        _decreaseBalance(
            _user,
            _assetId,
            _amount,
            _reasonCode,
            _nonceA,
            _nonceB
        );

        _increaseBalance(
            operator,
            _feeAssetId,
            _feeAmount,
            _feeReceiveReasonCode,
            _nonceA,
            _nonceB
        );

        if (_feeAssetId != _assetId) {
            _decreaseBalance(
                _user,
                _feeAssetId,
                _feeAmount,
                _feeGiveReasonCode,
                _nonceA,
                _nonceB
            );
            return _amount;
        }

        return _amount.sub(_feeAmount);
    }

    function _increaseBalance(
        address _user,
        address _assetId,
        uint256 _amount,
        uint256 _reasonCode,
        uint256 _nonceA,
        uint256 _nonceB
    )
        private
    {
        if (_amount == 0) { return; }
        balances[_user][_assetId] = balances[_user][_assetId].add(_amount);
        emit BalanceIncrease(
            _user,
            _assetId,
            _amount,
            _reasonCode,
            _nonceA,
            _nonceB
        );
    }

    function _decreaseBalance(
        address _user,
        address _assetId,
        uint256 _amount,
        uint256 _reasonCode,
        uint256 _nonceA,
        uint256 _nonceB
    )
        private
    {
        _decreaseBalance(_user, _assetId, _amount);

        emit BalanceDecrease(
            _user,
            _assetId,
            _amount,
            _reasonCode,
            _nonceA,
            _nonceB
        );
    }

    function _decreaseBalance(
        address _user,
        address _assetId,
        uint256 _amount
    )
        private
    {
        if (_amount == 0) { return; }
        balances[_user][_assetId] = balances[_user][_assetId].sub(_amount);
    }

    function _validateAddress(address _address) private pure {
        require(
            _address != address(0),
            'Invalid address'
        );
    }

    /// @dev Ensure that the address is a deployed contract
    function _validateContractAddress(address _contract) private view {
        assembly {
            if iszero(extcodesize(_contract)) { revert(0, 0) }
        }
    }

    /// @dev Fix for ERC-20 tokens that do not have proper return type
    /// See: https://github.com/ethereum/solidity/issues/4116
    /// https://medium.com/loopring-protocol/an-incompatibility-in-smart-contract-threatening-dapp-ecosystem-72b8ca5db4da
    /// https://github.com/sec-bit/badERC20Fix/blob/master/badERC20Fix.sol
    function _validateTransferResult(bytes memory data) private pure {
        require(
            data.length == 0 ||
            (data.length == 32 && _getUint256FromBytes(data) != 0),
            "Invalid transfer"
        );
    }

    function _getUint256FromBytes(
        bytes memory data
    )
        private
        pure
        returns (uint256)
    {
        uint256 parsed;
        assembly { parsed := mload(add(data, 32)) }
        return parsed;
    }
}
