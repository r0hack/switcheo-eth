pragma solidity 0.5.0;

import "./lib/math/SafeMath.sol";

contract BrokerV2 {
    using SafeMath for uint256;

    // Ether token "address" is set as the constant 0x00
    address constant ETHER_ADDR = address(0);

    // bytes4(keccak256('transferFrom(address,address,uint256)')) == 0x23b872dd
    bytes4 constant ENCODED_TRANSFER_FROM = 0x23b872dd;

    // deposits
    uint256 constant REASON_DEPOSIT = 0x01;

    // The coordinator sends trades (balance transitions) to the exchange
    address public coordinator;
    // The operator receives fees
    address public operator;

    // User balances by: userAddress => assetId => balance
    mapping(address => mapping(address => uint256)) public balances;

    // Emitted on any balance state transition (+ve)
    event BalanceIncrease(address indexed user, address indexed assetId, uint256 amount, uint256 indexed reason);

    constructor() public {
        coordinator = msg.sender;
        operator = msg.sender;
    }

    modifier onlyCoordinator() {
        require(msg.sender == coordinator, "Invalid sender");
        _;
    }

    function deposit() external payable {
        require(msg.value > 0, 'Invalid value');
        _increaseBalance(msg.sender, ETHER_ADDR, msg.value, REASON_DEPOSIT);
    }

    function depositToken(
        address _user,
        address _assetId,
        uint256 _amount
    )
        external
    {
        require(_amount > 0, 'Invalid value');
        _increaseBalance(_user, _assetId, _amount, REASON_DEPOSIT);

        _validateContractAddress(_assetId);

        bool success;
        bytes memory returnData;
        bytes memory payload = abi.encode(
                                   ENCODED_TRANSFER_FROM,
                                   _user,
                                   address(this),
                                   _amount
                               );

        (success, returnData) = _assetId.call(payload);

        require(success, 'transferFrom call failed');
        // ensure that asset transfer succeeded
        _validateTransferResult(returnData);
    }

    function _increaseBalance(
        address _user,
        address _assetId,
        uint256 _amount,
        uint256 _reasonCode
    )
        private
    {
        balances[_user][_assetId] = balances[_user][_assetId].add(_amount);
        emit BalanceIncrease(_user, _assetId, _amount, _reasonCode);
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

    function _getUint256FromBytes(bytes memory data) private pure returns (uint256) {
        uint256 parsed;
        assembly { parsed := mload(add(data, 32)) }
        return parsed;
    }
}
