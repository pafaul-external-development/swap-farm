pragma ton-solidity >= 0.39.0;

contract TestContract {
    uint32 testU;
    mapping(address => mapping(uint32 => bool)) testM;
    constructor() public {
        tvm.accept();
        testU = 0;
    }

    function addElements(uint32 iterations) external {
        tvm.accept();
        address t = address(this);
        repeat(iterations) {
            testM[t][testU] = true;
            testU += 1;
        }
    }

    function testIteration() external {
        tvm.accept();
        testM[address(this)][0] = false;
    }

    function test(uint32 index, TvmCell upload) external {
        tvm.accept();
        testM[address(this)][index] = false;
    }
}