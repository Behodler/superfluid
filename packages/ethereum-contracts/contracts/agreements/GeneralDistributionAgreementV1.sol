// SPDX-License-Identifier: AGPLv3
pragma solidity 0.8.19;

import {
    EnumerableSet
} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {
    ISuperfluid,
    ISuperfluidGovernance,
    ISuperApp,
    SuperAppDefinitions,
    ContextDefinitions,
    SuperfluidGovernanceConfigs
} from "../interfaces/superfluid/ISuperfluid.sol";
import "@superfluid-finance/solidity-semantic-money/src/SemanticMoney.sol";
import {
    TokenMonad
} from "@superfluid-finance/solidity-semantic-money/src/TokenMonad.sol";
import { SuperTokenPool } from "../superfluid/SuperTokenPool.sol";
import {
    SuperTokenPoolDeployerLibrary
} from "../libs/SuperTokenPoolDeployerLibrary.sol";
import {
    IGeneralDistributionAgreementV1
} from "../interfaces/agreements/IGeneralDistributionAgreementV1.sol";
import {
    ISuperfluidToken
} from "../interfaces/superfluid/ISuperfluidToken.sol";
import { ISuperTokenPool } from "../interfaces/superfluid/ISuperTokenPool.sol";
import { AgreementBase } from "./AgreementBase.sol";
import { AgreementLibrary } from "./AgreementLibrary.sol";

/**
 * @title General Distribution Agreement
 * @author Superfluid
 * @notice
 *
 * Storage Layout Notes
 * Agreement State
 * NOTE The Agreement State slot is computed with the following function:
 * keccak256(abi.encode("AgreementState", msg.sender, account, slotId))
 * slotId               = 0
 * msg.sender           = address of GDAv1
 * account              = pool address
 * Pool Agreement State stores the address of the pool which indicates existence.
 *
 *
 * Agreement Data
 * NOTE The Agreement Data slot is calculated with the following function:
 * keccak256(abi.encode("AgreementData", agreementClass, agreementId))
 * agreementClass       = address of GDAv1
 * agreementId          = UniversalIndexId | DistributionFlowId
 *
 * UniversalIndexId     = keccak256(abi.encode("universalIndex", account))
 * UniversalIndexId stores a BasicParticle struct for an `account`.
 *
 * DistributionFlowId   =
 * keccak256(abi.encode(block.chainId, "distributionFlow", from, pool))
 * DistributionFlowId stores FlowDistributionData between a sender (from) and pool.
 */
contract GeneralDistributionAgreementV1 is
    AgreementBase,
    TokenMonad,
    IGeneralDistributionAgreementV1
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;
    using SemanticMoney for BasicParticle;

    struct FlowDistributionData {
        int96 flowRate;
        uint96 deposit;
    }

    mapping(address owner => EnumerableSet.AddressSet connections)
        internal _connectionsMap;
    mapping(bytes32 flowAddress => FlowRate flowRate) public flowRates;

    constructor(ISuperfluid host) AgreementBase(address(host)) {}

    function realtimeBalanceVectorAt(
        ISuperfluidToken token,
        address account,
        uint256 time
    ) public view override returns (int256 available, int256 deposit) {
        BasicParticle memory uIndexData = _getUIndex(
            abi.encode(token),
            account
        );

        available = Value.unwrap(uIndexData.rtb(Time.wrap(uint32(time))));

        if (_isPool(token, account)) {
            available =
                available +
                ISuperTokenPool(account).getPendingDistribution();
        }

        {
            EnumerableSet.AddressSet storage connections = _connectionsMap[
                account
            ];
            for (uint256 i = 0; i < connections.length(); ++i) {
                address p = connections.at(i);
                available =
                    available +
                    ISuperTokenPool(p).getClaimable(uint32(time), account);
            }
        }

        deposit = 0;
    }

    function realtimeBalanceOf(
        ISuperfluidToken token,
        address account,
        uint256 time
    )
        public
        view
        override
        returns (int256 rtb, uint256 dep, uint256 owedDeposit)
    {
        (int256 available, int256 deposit) = realtimeBalanceVectorAt(
            token,
            account,
            time
        );
        rtb = available - deposit;

        // @note this is currently just 0
        dep = uint256(deposit);
        owedDeposit = 0;
    }

    /// @dev ISuperAgreement.realtimeBalanceOf implementation
    function realtimeBalanceOfNow(
        ISuperfluidToken token,
        address account
    ) external view override returns (int256 rtb) {
        (rtb, , ) = realtimeBalanceOf(token, account, block.timestamp);
    }

    function getNetFlowRate(
        ISuperfluidToken token,
        address account
    ) external view override returns (int96 netFlowRate) {
        BasicParticle memory uIndexData = _getUIndex(
            abi.encode(token),
            account
        );
        netFlowRate = int96(FlowRate.unwrap(uIndexData._flow_rate));

        if (_isPool(token, account)) {
            netFlowRate =
                netFlowRate +
                ISuperTokenPool(account).getPendingDistributionFlowRate();
        }

        {
            EnumerableSet.AddressSet storage connections = _connectionsMap[
                account
            ];
            for (uint i = 0; i < connections.length(); ++i) {
                ISuperTokenPool p = ISuperTokenPool(connections.at(i));
                netFlowRate = netFlowRate + p.getMemberFlowRate(account);
            }
        }
    }

    function getFlowRate(
        ISuperfluidToken token,
        address from,
        address to
    ) external view override returns (int96) {
        return (
            int96(
                FlowRate.unwrap(
                    flowRates[_getDistributionFlowId(from, ISuperTokenPool(to))]
                )
            )
        );
    }

    function getFlowDistributionActualFlowRate(
        ISuperfluidToken token,
        address from,
        ISuperTokenPool to,
        int96 requestedFlowRate
    ) external view override returns (int96 finalFlowRate) {
        Time t = Time.wrap(uint32(block.timestamp));
        bytes32 distributionFlowAddress = _getDistributionFlowId(from, to);

        BasicParticle memory fromUIndexData = _getUIndex(
            abi.encode(token),
            from
        );

        PDPoolIndex memory pdpIndex = _getPDPIndex("", address(to));

        FlowRate actualFlowRate;
        FlowRate flowRateDelta = FlowRate.wrap(requestedFlowRate) -
            _getFlowRate("", distributionFlowAddress);
        (fromUIndexData, pdpIndex, actualFlowRate) = fromUIndexData
            .shift_flow2b(pdpIndex, flowRateDelta, t);
        finalFlowRate = int96(FlowRate.unwrap(actualFlowRate));
    }

    // test view function conditions where net flow rate makes sense given pending distribution
    // balance of the pool will capture pending flow rate

    function createPool(
        address admin,
        ISuperfluidToken token
    ) external override returns (ISuperTokenPool pool) {
        pool = ISuperTokenPool(
            address(
                SuperTokenPoolDeployerLibrary.deploy(
                    admin,
                    GeneralDistributionAgreementV1(address(this)),
                    token
                )
            )
        );
        _setPool(token, address(pool));

        emit PoolCreated(token, admin, pool);
    }

    // @note This is same as approveSubscription
    function connectPool(
        ISuperTokenPool pool,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        return connectPool(pool, true, ctx);
    }

    // @note This is same as revokeSubscription
    function disconnectPool(
        ISuperTokenPool pool,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        return connectPool(pool, false, ctx);
    }

    function connectPool(
        ISuperTokenPool pool,
        bool doConnect,
        bytes calldata ctx
    ) public returns (bytes memory newCtx) {
        ISuperfluidToken token = pool._superToken();
        ISuperfluid.Context memory currentContext = AgreementLibrary
            .authorizeTokenAccess(token, ctx);
        address msgSender = currentContext.msgSender;
        newCtx = ctx;
        if (doConnect) {
            if (!_connectionsMap[msgSender].contains(address(pool))) {
                _connectionsMap[msgSender].add(address(pool));
                assert(
                    pool.operatorConnectMember(
                        uint32(block.timestamp),
                        msgSender,
                        true
                    )
                );
            }
        } else {
            if (_connectionsMap[msgSender].contains(address(pool))) {
                _connectionsMap[msgSender].remove(address(pool));
                assert(
                    pool.operatorConnectMember(
                        uint32(block.timestamp),
                        msgSender,
                        false
                    )
                );
            }
        }

        emit PoolConnectionUpdated(token, msgSender, pool, doConnect);
    }

    function isMemberConnected(
        address pool,
        address member
    ) external view override returns (bool) {
        return _connectionsMap[member].contains(pool);
    }

    // # Universal Index operations
    //
    // Universal Index packing:
    //
    // -------- ------------------ ------------------ ------------------
    // WORD 1: |     flowRate     |     settledAt    |       free       |
    // -------- ------------------ ------------------ ------------------
    //         |        96b       |       32b        |        128b      |
    // -------- ------------------ ------------------ ------------------
    // WORD 2: |                      settledValue                      |
    // -------- ------------------ ------------------ ------------------
    //         |                          256b                          |
    // -------- ------------------ ------------------ ------------------

    function _getUniversalIndexId(
        address account
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("universalIndex", account));
    }

    function absorbParticlesFromPool(
        ISuperfluidToken token,
        address[] calldata accounts,
        BasicParticle[] calldata ps
    ) public returns (bool) {
        if (_isPool(token, msg.sender) == false) {
            revert ONLY_SUPER_TOKEN_POOL();
        }
        assert(accounts.length == ps.length);

        bytes memory eff = abi.encode(token);
        for (uint i = 0; i < accounts.length; i++) {
            BasicParticle memory accountParticle = _getUIndex(eff, accounts[i]);

            // update account particle
            _setUIndex(eff, accounts[i], accountParticle.mappend(ps[i]));
        }
        return true;
    }

    function distribute(
        ISuperfluidToken token,
        ISuperTokenPool pool,
        uint256 requestedAmount,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        ISuperfluid.Context memory currentContext = AgreementLibrary
            .authorizeTokenAccess(token, ctx);
        newCtx = ctx;

        (bytes memory eff, Value actualAmount) = _doDistribute(
            abi.encode(token),
            currentContext.msgSender,
            address(pool),
            Value.wrap(requestedAmount.toInt256())
        );

        emit InstantDistributionUpdated(
            token,
            pool,
            currentContext.msgSender,
            uint32(block.timestamp),
            requestedAmount,
            uint256(Value.unwrap(actualAmount)) // upcast from int256 -> uint256 is safe
        );
    }

    function distributeFlow(
        ISuperfluidToken token,
        ISuperTokenPool to,
        int96 requestedFlowRate,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        ISuperfluid.Context memory currentContext = AgreementLibrary
            .authorizeTokenAccess(token, ctx);

        newCtx = ctx;

        Time t = Time.wrap(uint32(block.timestamp));
        bytes32 distributionFlowAddress = _getDistributionFlowId(
            currentContext.msgSender,
            to
        );

        BasicParticle memory fromUIndexData = _getUIndex(
            abi.encode(token),
            currentContext.msgSender
        );
        FlowRate oldFlowRate = fromUIndexData._flow_rate.inv();

        (, FlowRate actualFlowRate) = _doDistributeFlow(
            abi.encode(token),
            currentContext.msgSender,
            address(to),
            distributionFlowAddress,
            FlowRate.wrap(requestedFlowRate),
            t
        );

        {
            emit FlowDistributionUpdated(
                token,
                to,
                currentContext.msgSender,
                uint32(block.timestamp),
                int96(FlowRate.unwrap(oldFlowRate)),
                int96( // newFlowRate
                    FlowRate.unwrap(
                        flowRates[distributionFlowAddress] +
                            actualFlowRate -
                            oldFlowRate
                    )
                )
            );
        }
    }

    function _getDistributionFlowId(
        address from,
        ISuperTokenPool pool
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    "distributionFlow",
                    from,
                    address(pool)
                )
            );
    }

    function _encodeUniversalIndex(
        BasicParticle memory p
    ) internal pure returns (bytes32[] memory data) {
        data = new bytes32[](2);
        data[0] = bytes32(
            (uint256(int256(FlowRate.unwrap(p._flow_rate))) << 160) |
                (uint256(Time.unwrap(p._settled_at)) << 96)
        );
        data[1] = bytes32(uint256(Value.unwrap(p._settled_value)));
    }

    function _decodeUniversalIndexData(
        bytes32[] memory data
    ) internal pure returns (bool exists, BasicParticle memory particle) {
        uint256 wordA = uint256(data[0]);
        uint256 wordB = uint256(data[1]);

        exists = wordA > 0;

        if (exists) {
            particle = BasicParticle({
                _flow_rate: FlowRate.wrap(
                    int96(
                        int256(wordA >> 160) & int256(uint256(type(uint96).max))
                    )
                ),
                _settled_at: Time.wrap(uint32(wordA >> 96)),
                _settled_value: Value.wrap(int256(wordB))
            });
        }
    }

    // TokenMonad virtual functions
    function _getUIndex(
        bytes memory eff,
        address owner
    ) internal view override returns (BasicParticle memory uIndex) {
        address token = abi.decode(eff, (address));
        bytes32[] memory data = ISuperfluidToken(token).getAgreementData(
            address(this),
            _getUniversalIndexId(owner),
            2
        );
        (, uIndex) = _decodeUniversalIndexData(data);
    }

    function _setUIndex(
        bytes memory eff,
        address owner,
        BasicParticle memory p
    ) internal override returns (bytes memory) {
        address token = abi.decode(eff, (address));
        ISuperfluidToken(token).updateAgreementData(
            _getUniversalIndexId(owner),
            _encodeUniversalIndex(p)
        );

        emit UniversalIndexUpdated(
            ISuperfluidToken(token),
            owner,
            Time.unwrap(p._settled_at),
            Value.unwrap(p._settled_value),
            int96(FlowRate.unwrap(p._flow_rate))
        );
    }

    function _getPDPIndex(
        bytes memory eff,
        address pool
    ) internal view override returns (PDPoolIndex memory) {
        return SuperTokenPool(pool).getIndex();
    }

    function _setPDPIndex(
        bytes memory eff,
        address pool,
        PDPoolIndex memory p
    ) internal override returns (bytes memory) {
        assert(SuperTokenPool(pool).operatorSetIndex(p));
    }

    function _getFlowRate(
        bytes memory,
        bytes32 flowHash
    ) internal view override returns (FlowRate) {
        return flowRates[flowHash];
    }

    function _setFlowInfo(
        bytes memory eff,
        bytes32 flowHash,
        address from,
        address to,
        FlowRate flowRate
    ) internal override returns (bytes memory) {
        flowRates[flowHash] = flowRate;
    }

    function _isPool(
        ISuperfluidToken token,
        address pool
    ) internal view virtual returns (bool exists) {
        exists = _getPoolAgreementState(token, pool);
    }

    function _setFlowInfo(
        bytes32 flowHash,
        address /*from*/,
        address /*to*/,
        FlowRate flowRate
    ) internal virtual {
        flowRates[flowHash] = flowRate;
    }

    function _setPool(ISuperfluidToken token, address pool) internal {
        bytes32[] memory data = _encodePoolData(pool);
        token.updateAgreementStateSlot(pool, 0, data);
    }

    // Pool data packing:
    //
    // WORD A: | reserved | poolAddress |
    //         |    96    |     160     |
    //
    function _encodePoolData(
        address pool
    ) internal pure returns (bytes32[] memory data) {
        data = new bytes32[](1);
        data[0] = bytes32(uint256(uint160(pool)));
    }

    function _decodePoolData(
        uint256 data
    ) internal pure returns (bool exist, address pool) {
        exist = data > 0;
        if (exist) {
            pool = address(uint160(data));
        }
    }

    function _getPoolAgreementState(
        ISuperfluidToken token,
        address pool
    ) internal view returns (bool exist) {
        bytes32[] memory data = token.getAgreementStateSlot(
            address(this),
            pool,
            0,
            1
        );
        (exist, ) = _decodePoolData(uint256(data[0]));
    }

    // FlowDistributionData data packing:
    //
    // WORD A: | reserved | deposit | flowRate |
    //         |    64    |   96    |    96    |
    //
    function _encodeFlowDistributionData(
        FlowDistributionData memory flowDistributionData
    ) internal pure returns (bytes32[] memory data) {
        data = new bytes32[](1);
        data[0] = bytes32(
            (uint256(uint96(flowDistributionData.flowRate)) << 96) |
                uint256(flowDistributionData.deposit)
        );
    }

    function _decodeFlowDistributionData(
        uint256 data
    )
        internal
        pure
        returns (bool exist, FlowDistributionData memory flowDistributionData)
    {
        exist = data > 0;
        if (exist) {
            flowDistributionData.deposit = uint96(
                data & uint256(type(uint96).max)
            );
            flowDistributionData.flowRate = int96(int256(data >> 96));
        }
    }

    function _getFlowDistributionData(
        ISuperfluidToken token,
        address from,
        ISuperTokenPool pool
    )
        internal
        view
        returns (bool exist, FlowDistributionData memory flowDistributionData)
    {
        bytes32[] memory data = token.getAgreementData(
            address(this),
            _getDistributionFlowId(from, pool),
            1
        );

        (exist, flowDistributionData) = _decodeFlowDistributionData(
            uint256(data[0])
        );
    }
}