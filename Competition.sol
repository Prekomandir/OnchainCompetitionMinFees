//SPDX-License-Identifier:Unlincensed
pragma solidity ^0.8.10;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
//import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

//**************************VRFv2Consumer is the standard Chainlink contract for getting random values
//**************************Contract Main is the one I wrote so you can skip VRF
contract VRFv2Consumer is VRFConsumerBaseV2 {
    VRFCoordinatorV2Interface COORDINATOR;

    // Your subscription ID.
    uint64 public s_subscriptionId;

    // Rinkeby coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address public vrfCoordinator = 0x6168499c0cFfCaCD319c818142124B7A15E857ab;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 public keyHash =
        0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 public callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 public requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
    uint32 public numWords = 2;

    uint256[] public s_randomWords;
    uint256 public s_requestId;
    address s_owner;

    constructor(uint64 subscriptionId) VRFConsumerBaseV2(vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_owner = msg.sender;
        s_subscriptionId = subscriptionId;
    }

    // Assumes the subscription is funded sufficiently.
    function requestRandomWords() public onlyOwner {
        // Will revert if subscription is not set and funded.
        s_requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
    }

    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        s_randomWords = randomWords;
    }

    modifier onlyOwner() {
        require(msg.sender == s_owner);
        _;
    }
}

contract Main is Ownable {
    VRFv2Consumer VRFContract;
    // this is the structure of a single competition based on the LP pair involved, it's dynamic and changes with each new competition for a given pair
    struct Competition {
        uint256 reward;
        uint256 duration;
        uint256 minToken;
        bool competitionActive;
    }
    //this connects the struct above with the LP address
    mapping(address => Competition) public pairCompetition;
    //this checks if the user registered, with connected functionality below it removes the need for users to spend gas each time they enter a new competition
    mapping(address => bool) public registered;

    //this returns the address of an ERC20 token for a given LP address
    mapping(address => address) private pairToToken;
    //this tracks balance a user has of any relevant ERC20 token on the same blockchain at the start of a competition
    mapping(address => mapping(address => uint256)) private userTokenBalance;
    //some useful global modifiers, it might be impractical to let users to make competitions last for years
    // because a new competition can't be started if there's one already ongoing for the LP in question
    // minReward will protect from people initializing competitions with 1$ or less, taking the competition for themselves with no gain for users.
    uint256 private maxDuration;
    uint256 private minReward;
    //this is where the fee can go if you want it to go straight to your wallet
    address private feeWallet;
    address[] private competitors;

    constructor(address _VRFContract) {
        VRFContract = VRFv2Consumer(_VRFContract);
    }

    //one time registration so users can join competitions
    function register() external {
        require(registered[msg.sender] == false, "Already in");

        registered[msg.sender] = true;
        competitors.push(msg.sender);
    }

    //same as above but let's a user join an already ongoing competition, with current design user can only join competition if they registered before it started
    function registerAndJoinOngoingCompetition(address _pair) external {
        require(registered[msg.sender] == false, "Already in");
        registered[msg.sender] = true;
        competitors.push(msg.sender);
        userTokenBalance[pairToToken[_pair]][msg.sender] = IERC20(
            pairToToken[_pair]
        ).balanceOf(msg.sender);
    }

    //same as register but can register 100 users at once (the max amount could be removed but I suggest leaving it at 100 ). Can be done by the contract from the part of the fees,
    //or by those who want to create the competition to incentivize users to join in and buy their token
    function massRegister(address[] memory _addressList) external {
        require(_addressList.length <= 100, "Maximum of 100 addresses allowed");
        for (uint256 i = 0; i < _addressList.length; i++) {
            if (registered[_addressList[i]] == false) {
                registered[_addressList[i]] = true;
                competitors.push(_addressList[i]);
            }
        }
    }

    function startCompetition(
        address _pair,
        address _token,
        uint256 _minToken,
        uint256 _duration
    ) external payable {
        require(
            pairCompetition[_pair].competitionActive == false,
            "Competition already ongoing"
        );
        require(
            pairCompetition[_pair].duration <= maxDuration,
            "Competition too long"
        );
        require(msg.value >= minReward, "Reward too low");
        //this is where the fee is sent to smart contract
        uint256 fee = (msg.value * 15) / 100;
        (bool success, ) = feeWallet.call{value: fee}("");
        require(success, "Transfer failed.");
        //this is where the competition is defined
        pairToToken[_pair] = _token;
        pairCompetition[_pair].reward = msg.value - fee;
        pairCompetition[_pair].minToken = _minToken;
        pairCompetition[_pair].duration = _duration + block.timestamp;
        pairCompetition[_pair].competitionActive = true;
        //this checks balance of all registered users at the start,
        // so their eligibility for a reward can be determined by comparing this value with the amount of tokens they hold when the competition ends.
        // @notice there has to be a certain function to record token transfers because otherwise a user could transfer a large amount of tokens to another wallet
        // before the start of the competition and return the amount back after its initialized. Outside of code this can be mitigated by competitions that are not fully
        // announced before they are initialized.
        for (uint256 i = 0; i < competitors.length; i++) {
            userTokenBalance[competitors[i]][_token] = IERC20(_token).balanceOf(
                competitors[i]
            );
        }
    }

    // not finished yet because adding VRF in the equation is fairly simple and this won't affect the rest of the code
    function endCompetition(address _pair) external {
        require(
            pairCompetition[_pair].competitionActive == true,
            "Competition closed"
        );
        require(
            pairCompetition[_pair].duration <= block.timestamp,
            "Competition ongoing"
        );
        pairCompetition[_pair].competitionActive = false;
        //insert VRF functionality
        uint256 randomNum = VRFContract.s_randomWords(0);
    }

    function changeGlobalRestrictions(uint256 _maxDuration, uint256 _minReward)
        external
        onlyOwner
    {
        maxDuration = _maxDuration;
        minReward = _minReward;
    }

    function changeVRFContract(address _VRFContract) external onlyOwner {
        VRFContract = VRFv2Consumer(_VRFContract);
    }
}
