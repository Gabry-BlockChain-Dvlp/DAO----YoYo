require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

module.exports = {
  solidity: "0.8.27",
  paths: { sources: "./src", tests: "./test-hardhat", cache: "./cache-hardhat", artifacts: "./artifacts-hardhat" },
};
