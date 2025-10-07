const { ethers } = require('ethers');

// Configuration from environment variables
const getConfig = () => ({
  alchemyRpcUrl: process.env.ALCHEMY_RPC_URL,
});

module.exports = async function handler(req, res) {
  // Enable CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { owner, salt, factoryAddress, factoryType = 'simple' } = req.body;

  try {
    console.log(`Calculate account address request: owner=${owner}, salt=${salt}, factory=${factoryAddress}, type=${factoryType}`);

    const config = getConfig();
    if (!config.alchemyRpcUrl) {
      return res.status(500).json({ error: 'RPC URL not configured' });
    }

    // Create provider using environment RPC URL
    const provider = new ethers.JsonRpcProvider(config.alchemyRpcUrl);

    let predictedAddress;

    if (factoryType === 'simple') {
      // Use getCalculatedAddress for our working factory (avoids ethers.js bug)
      const factoryAbi = [
        "function getCalculatedAddress(address owner, uint256 salt) view returns (address)",
        "function accountImplementation() view returns (address)"
      ];

      const factoryContract = new ethers.Contract(factoryAddress, factoryAbi, provider);
      predictedAddress = await factoryContract.getCalculatedAddress(owner, salt);
    } else {
      // For official/alchemy factories, use raw call to avoid ethers.js Contract bug
      const factoryInterface = new ethers.Interface([
        "function getAddress(address owner, uint256 salt) view returns (address)"
      ]);

      // Encode the function call
      const callData = factoryInterface.encodeFunctionData('getAddress', [owner, salt]);

      // Make raw call
      const rawResult = await provider.call({
        to: factoryAddress,
        data: callData
      });

      // Decode the result
      const decodedResult = factoryInterface.decodeFunctionResult('getAddress', rawResult);
      predictedAddress = decodedResult[0];
    }

    console.log(`Address calculated: ${predictedAddress}`);
    res.status(200).json({ predictedAddress });

  } catch (error) {
    console.error('Calculate address error:', error);
    res.status(500).json({
      error: 'Failed to calculate address',
      details: error.reason || error.message
    });
  }
}
