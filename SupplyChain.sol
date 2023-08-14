// SPDX-License-Identifier: GPL-3.0

import "./Mapping.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
pragma solidity ^0.8.0;

error notOwner(address);
error unauthorized(address);
error addressZero(address);
error alreadySet(uint256);
error penaltyNotSet();
error alreadySettled();
error insufficientFund();
error sendFailed();
error alreadyCreated();

contract SupplyChain is Mapping, Pausable {
    address public contractOwner;
    address public Infrablok;
    uint256 public balance;

    //Maintaining n metrices per consignment.
    mapping(string => mapping(uint256 => Metric)) public consignmentMetricMap;

    //Maintaing penalty charge per range per consignment.
    mapping(string => mapping(uint256 => Penalty[])) public penaltyMap;

    constructor(address infrablok) {
        contractOwner = msg.sender;
        Infrablok = infrablok;
    }

    modifier onlyContractOwner() {
        if (contractOwner != msg.sender) {
            revert notOwner(msg.sender);
        }
        _;
    }

    modifier onlyInfrablok() {
        if (Infrablok != msg.sender) {
            revert notOwner(msg.sender);
        }
        _;
    }

    function pause() public onlyInfrablok {
        _pause();
    }

    function unpause() public onlyInfrablok {
        _unpause();
    }

    event ContractOwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    event OwnershipChanged(
        string assetID,
        address currentOwner,
        address newOwner
    );

    event settlementDone(
        string invoiceNumber,
        uint256[] metricID,
        address owner,
        address logisticProvider,
        uint256 penaltyAmount,
        uint256 charge,
        uint256 amountTransferred
    );

    event fundReceived(address receiver, uint256 amount);

    function transferContractOwnership(
        address newOwner
    ) public onlyContractOwner whenNotPaused {
        address previousOwner = contractOwner;
        contractOwner = newOwner;
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit ContractOwnershipTransferred(previousOwner, newOwner);
    }

    //This method is used to save product information into the blockchain.
    function createAsset(
        FunctionAsset calldata functionAsset,
        FunctionTraceInfo calldata functionTraceInfo
    ) external onlyContractOwner whenNotPaused {
        address Owner = functionTraceInfo.owner;

        if (Owner == address(0)) Owner = msg.sender;

        //Saving product information in a "asset" struct and pushing it into an "assets" array.
        Asset memory asset = Asset(
            functionAsset.Id,
            functionAsset.MetaData,
            "",
            Owner,
            address(0),
            State.MANUFACTURED
        );

        require(
            !userAssetsMap[Owner][asset.Id],
            "Asset already exists for the user."
        );
        assetIdList.push(asset.Id);

        //Mapping each asset information with asset Id.
        assetMap[asset.Id] = asset;

        //Setting asset Id for each user to true and saving the Ids into an array mapped with user address.
        userAssetsMap[Owner][asset.Id] = true;

        //Saving current package state in "packDetails" struct and saving it into an array mapped with asset Id.
        TraceInfo memory packageDetails = TraceInfo(
            Owner,
            block.timestamp,
            "",
            "",
            functionTraceInfo.location,
            functionTraceInfo.comment
        );
        supplyChain[asset.Id].push(packageDetails);
    }

    // This method is used to package the list of products together.
    function createPackage(
        string calldata packageId,
        string[] calldata productIdList
    ) external onlyContractOwner whenNotPaused {
        for (uint256 i = 0; i < productIdList.length; i++) {
            string memory assetId = productIdList[i];
            //Default "Asset.Owner" value of empty asset is "0x0000000000000000000000000000000000000000".
            require(
                assetMap[assetId].Owner != address(0),
                "Asset doesn't exist."
            );
            if (msg.sender != assetMap[assetId].Owner) {
                revert notOwner(msg.sender);
            }

            if (packageExists[packageId] == true) {
                revert alreadyCreated();
            }

            string memory parentId = assetMap[assetId].ParentId;
            require(
                keccak256(bytes(parentId)) == keccak256(bytes("")),
                "Depackage First."
            );
            
            assetMap[assetId].ParentId = packageId;
            packageMap[packageId].push(assetId);
        }
        packageExists[packageId] = true;
        packageList.push(packageId);
    }

    // This method is used to depackage.
    function dePackage(
        string calldata packageId
    ) external onlyContractOwner whenNotPaused {
        //Fetching product list of given package id.
        string[] memory assetList = packageMap[packageId];
        //Iterating through the product list.
        for (uint256 i = 0; i < assetList.length; i++) {
            string memory assetId = assetList[i];
            if (msg.sender != assetMap[assetId].Owner) {
                revert notOwner(msg.sender);
            }
            //Default "Asset.Owner" value of empty asset is "0x0000000000000000000000000000000000000000".
            if (assetMap[assetId].Owner != address(0)) {
                assetMap[assetId].ParentId = "";
            }
        }
        //Deleting the package mapping.
        delete packageMap[packageId];
        packageExists[packageId] = false;
    }

    // This is a common method for outward/inward/sold.
    //Outward is called by seller who needs to provide logistic as well as buyer address along with other required arguments.
    //Inward is called by the buyer to accept delivery of the poduct from the logistics. The buyer will also provide logistic and his own address(receiverAdd) along with other required arguments. Current owner will be Logistic provider.
    //Sold is called by buyer. Buyer will only provide end user's address as Receiver address along with other required arguments. No logistic address is required (set address(0)).

    function changeOwnership(
        FunctionChaneOwnershipArgs memory changeOwnershipArgs,
        FunctionTraceInfo memory functionTraceInfo
    ) external onlyContractOwner whenNotPaused {
        address Owner = address(0);
        address newOwner = address(0);
        if (changeOwnershipArgs.type_list._type == Type.UNIT) {
            for (
                uint256 i = 0;
                i < changeOwnershipArgs.type_list.IdList.length;
                i++
            ) {
                string memory assetId = changeOwnershipArgs.type_list.IdList[i];

                if (changeOwnershipArgs.functionType == FunctionType.OUTWARD) {
                    //Seller is the current owner.
                    Owner = functionTraceInfo.owner;
                    //Logistic provider is the new owner.
                    newOwner = changeOwnershipArgs.logisticAdd;

                    if (Owner == address(0)) Owner = msg.sender;
                    require(
                        userAssetsMap[Owner][assetId],
                        "You are not the owner."
                    );

                    string memory parentId = assetMap[assetId].ParentId;
                    require(
                        keccak256(bytes(parentId)) == keccak256(bytes("")),
                        "Depackage First."
                    );

                    //Changing the state of product.
                    assetMap[assetId].state = State.INTRANSIT;

                    //Changing the ownership of the product to logistic provider's address.
                    assetMap[assetId].Owner = newOwner;

                    //Updating Buyer Address for each product.
                    assetMap[assetId].OutwardedTo = changeOwnershipArgs
                        .receiverAdd;
                } else if (
                    changeOwnershipArgs.functionType == FunctionType.INWARD
                ) {
                    //Logistic provider is the current owner.
                    Owner = functionTraceInfo.owner;

                    //Buyer is the new owner.
                    newOwner = changeOwnershipArgs.receiverAdd;

                    if (Owner == address(0)) Owner = msg.sender;

                    require(
                        assetMap[assetId].OutwardedTo == newOwner &&
                            changeOwnershipArgs.receiverAdd == newOwner &&
                            userAssetsMap[Owner][assetId]
                    );

                    //Changing the ownership of the product to buyer's address.
                    assetMap[assetId].Owner = newOwner;

                    assetMap[assetId].state = State.STORAGE;
                } else if (
                    changeOwnershipArgs.functionType == FunctionType.SOLD
                ) {
                    //Buyer is the current owner.
                    Owner = functionTraceInfo.owner;

                    //Customer is the new owner.
                    newOwner = changeOwnershipArgs.receiverAdd;

                    //Buyer is the caller of the method.
                    if (Owner == address(0)) Owner = msg.sender;
                    require(
                        userAssetsMap[Owner][assetId],
                        "You are not the owner."
                    );

                    //Changing the ownership of the product to end user's address.
                    assetMap[assetId].Owner = newOwner;
                    //Changing the state of product.
                    assetMap[assetId].state = State.ENDUSER;
                }

                //Updating package details and adding it to supplyChain.
                TraceInfo memory packageDetails = TraceInfo(
                    newOwner,
                    block.timestamp,
                    changeOwnershipArgs.invoiceHash,
                    changeOwnershipArgs.invoiceNum,
                    functionTraceInfo.location,
                    functionTraceInfo.comment
                );
                supplyChain[assetId].push(packageDetails);

                //Deleting the product for current owner(seller).
                userAssetsMap[Owner][assetId] = false;

                //Updating the product for new owner(logistic provider).
                userAssetsMap[newOwner][assetId] = true;

                emit OwnershipChanged(assetId, Owner, assetMap[assetId].Owner);
            }
        } else {
            if (changeOwnershipArgs.type_list._type == Type.PACKAGE) {
                for (
                    uint256 i = 0;
                    i < changeOwnershipArgs.type_list.IdList.length;
                    i++
                ) {
                    string memory packageId = changeOwnershipArgs
                        .type_list
                        .IdList[i];

                    //Fetching product list of given package id.
                    string[] memory assetList = packageMap[packageId];

                    require(assetList.length != 0, "Wrong Package");

                    //Iterating through the product list.
                    for (uint256 j = 0; j < assetList.length; j++) {
                        string memory assetId = assetList[j];
                        //     string memory parentId= assetMap[assetId].ParentId;
                        // require(keccak256(bytes(parentId)) == keccak256(bytes(packageId)),"Package doesn't exist.");

                        if (
                            changeOwnershipArgs.functionType ==
                            FunctionType.OUTWARD
                        ) {
                            //Seller is the current owner.
                            Owner = functionTraceInfo.owner;

                            //Logistic provider is the new owner.
                            newOwner = changeOwnershipArgs.logisticAdd;

                            if (Owner == address(0)) Owner = msg.sender;
                            require(
                                userAssetsMap[Owner][assetId],
                                "You are not the owner."
                            );

                            //Changing the state of product.
                            assetMap[assetId].state = State.INTRANSIT;

                            //Changing the ownership of the product to logistic provider's address.
                            assetMap[assetId].Owner = newOwner;

                            //Updating Buyer Address for each product.
                            assetMap[assetId].OutwardedTo = changeOwnershipArgs
                                .receiverAdd;
                        } else if (
                            changeOwnershipArgs.functionType ==
                            FunctionType.INWARD
                        ) {
                            //Logistic provider is the current owner.
                            Owner = changeOwnershipArgs.logisticAdd;

                            //Buyer is the new owner.
                            newOwner = changeOwnershipArgs.receiverAdd;

                            if (functionTraceInfo.owner == address(0))
                                Owner = msg.sender;

                            require(
                                assetMap[assetId].OutwardedTo == newOwner &&
                                    changeOwnershipArgs.receiverAdd ==
                                    newOwner &&
                                    userAssetsMap[Owner][assetId],
                                "Wrong OutwardedTo or receiverAdd."
                            );

                            //Changing the ownership of the product to buyer's address.
                            assetMap[assetId].Owner = newOwner;

                            assetMap[assetId].state = State.STORAGE;
                        } else if (
                            changeOwnershipArgs.functionType ==
                            FunctionType.SOLD
                        ) {
                            //Buyer is the current owner.

                            Owner = functionTraceInfo.owner;

                            //Customer is the new user.
                            newOwner = changeOwnershipArgs.receiverAdd;
                            //Buyer is the caller of the method.
                            if (Owner == address(0)) Owner = msg.sender;
                            require(
                                userAssetsMap[Owner][assetId],
                                "You are not the owner"
                            );

                            //Changing the ownership of the product to end user's address.
                            assetMap[assetId].Owner = newOwner;
                            //Changing the state of product.
                            assetMap[assetId].state = State.ENDUSER;
                        }

                        //Updating package details and adding it to supplyChain.
                        TraceInfo memory packageDetails = TraceInfo(
                            newOwner,
                            block.timestamp,
                            changeOwnershipArgs.invoiceHash,
                            changeOwnershipArgs.invoiceNum,
                            functionTraceInfo.location,
                            functionTraceInfo.comment
                        );
                        supplyChain[assetId].push(packageDetails);

                        //Deleting the product for current owner(seller).
                        userAssetsMap[Owner][assetId] = false;

                        //Updating the product for new owner(logistic provider).
                        userAssetsMap[newOwner][assetId] = true;

                        emit OwnershipChanged(
                            assetId,
                            Owner,
                            assetMap[assetId].Owner
                        );
                    }
                }
            }
        }
    }

    // This method is used to trace package based on id.
    function productTraceById(
        string memory id
    ) external view returns (TraceInfo[] memory) {
        return supplyChain[id];
    }

    // This method returns list of all the product ids saved in the blockchain.
    function getAllAssets() external view returns (string[] memory) {
        return assetIdList;
    }

    // This method returns list of all the package ids saved in the blockchain.
    function getAllPackages() external view returns (string[] memory) {
        return packageList;
    }

    //This method returns list of product ids mapped with the given package id.
    function getAllProductByPackageId(
        string memory packageId
    ) external view returns (string[] memory) {
        return packageMap[packageId];
    }

    //***********************SLA Methods**********************//
    receive() external payable {
        emit fundReceived(msg.sender, msg.value);
    }

    //This function is sued to deposit fund in the contract
    function depositFund() external payable onlyContractOwner whenNotPaused {
        if (msg.value <= 0) {
            revert insufficientFund();
        }
         balance += msg.value;
        payable(address(this)).transfer(msg.value);
       
    }

    //This function is used to set charges for logistic providers per consignment
    function setLogisticCharge(
        address logisticProvider,
        string calldata invoiceNumber,
        uint256 charge
    ) external onlyContractOwner whenNotPaused {
        logisticCharge[logisticProvider][invoiceNumber] = charge;
    }

    //This function is used to set metrices per consignment.
    function setMetric(
        string calldata invoiceNumber,
        Metric memory metric
    ) external onlyContractOwner whenNotPaused {
        consignmentMetricMap[invoiceNumber][counterMap[invoiceNumber]] = metric;
        counterMap[invoiceNumber]++;
    }

    //This function is used to set penalty charges per violation ranges per consignment and metric id.

    function setPenalty(
        string calldata invoiceNumber,
        uint256 metricID,
        Penalty[] memory penalty
    ) external onlyContractOwner whenNotPaused {
        if (penaltyUpdated[invoiceNumber][metricID] == true) {
            revert alreadySet(metricID);
        }
        penaltyUpdated[invoiceNumber][metricID] = true;
        for (uint8 j = 0; j < penalty.length; j++) {
            penaltyMap[invoiceNumber][metricID].push(penalty[j]);
        }
    }

    //This function is used to take metric inputs per metric id at regular time intervals per consignment and metric id.

    function setMetricValue(
        string calldata invoiceNumber,
        uint256 metricID,
        uint256 metricValue
    ) external onlyContractOwner whenNotPaused {
        if (penaltyUpdated[invoiceNumber][metricID] != true) {
            revert penaltyNotSet();
        }
        //Setting n metric inputs per metric id.

        metricValueMap[invoiceNumber][metricID][
            valueCountMap[invoiceNumber][metricID]
        ] = metricValue;

        valueCountMap[invoiceNumber][metricID]++;

        //Fetching max and min range of metric id.

        uint256 maxRange = consignmentMetricMap[invoiceNumber][metricID]
            .maxRange;

        uint256 minRange = consignmentMetricMap[invoiceNumber][metricID]
            .minRange;

        //Checking if input metric value per mertic id is out of range.

        if (metricValue < minRange || metricValue > maxRange) {
            //Setting violation count for consignment.

            violation[invoiceNumber]++;

            //Setting violation count per metric id.

            violationPerMetric[invoiceNumber][metricID]++;
        }
    }

    //This function is used to calculate penalty per consignment.

    function calculatePenalty(
        string calldata invoiceNumber,
        uint256[] calldata metricID
    ) public view onlyContractOwner whenNotPaused returns (uint256) {
        uint256 totalCharge;

        //Looping through penalty ranges and comparing violation count to fetch penalty charge.

        for (uint8 i = 0; i < metricID.length; i++) {
            if (penaltyUpdated[invoiceNumber][metricID[i]] != true) {
                revert penaltyNotSet();
            }
            //Fetching total violations per metric.
            uint256 violationCount = violationPerMetric[invoiceNumber][
                metricID[i]
            ];

            for (
                uint8 j = 0;
                j < penaltyMap[invoiceNumber][metricID[i]].length;
                j++
            ) {
                uint16 minCount = penaltyMap[invoiceNumber][metricID[i]][j]
                    .minCount;

                uint16 maxCount = penaltyMap[invoiceNumber][metricID[i]][j]
                    .maxCount;

                uint256 charge = penaltyMap[invoiceNumber][metricID[i]][j]
                    .charge;

                if (violationCount >= minCount && violationCount <= maxCount) {
                    totalCharge += charge;
                }
            }
        }

        return totalCharge;
    }

    //This function is used to make final settlement.

    function settlement(
        string calldata invoiceNumber,
        uint256[] calldata metricID,
        address payable logisticProvider
    ) external payable onlyContractOwner whenNotPaused {
        if (settled[logisticProvider][invoiceNumber] == true) {
            revert alreadySettled();
        }

        settled[logisticProvider][invoiceNumber] = true;

        //Calling calculatePenalty function to get penalty charge calculted per consignment.

        uint256 penaltyFee = calculatePenalty(invoiceNumber, metricID);

        if (penaltyFee > balance) {
            revert insufficientFund();
        }

        
        uint256 charge = logisticCharge[logisticProvider][invoiceNumber];
        uint256 amount = charge - penaltyFee;
        balance=balance-amount;

        //Transfering the amount to logistic provider.
        bool sent = logisticProvider.send(amount);

        if (!sent) {
            revert sendFailed();
        }

        emit settlementDone(
            invoiceNumber,
            metricID,
            msg.sender,
            logisticProvider,
            penaltyFee,
            charge,
            amount
        );
    }
}
