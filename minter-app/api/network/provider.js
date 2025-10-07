const { ethers } = require('ethers');

// Configuration from environment variables
const getConfig = () => ({
  alchemyRpcUrl: process.env.ALCHEMY_RPC_URL,
  sepoliaPrivateKey: process.env.SEPOLIA_PRIVATE_KEY,
});

module.exports = async function handler(req, res) {
  // Enable CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { method, params = [], chainId = 11155111 } = req.body;

    if (!method) {
      return res.status(400).json({ error: 'Method is required' });
    }

    // Only allow Sepolia for now
    if (chainId !== 11155111) {
      return res.status(400).json({ error: 'Only Sepolia (11155111) is supported' });
    }

    const config = getConfig();
    if (!config.alchemyRpcUrl) {
      return res.status(500).json({ error: 'RPC URL not configured' });
    }

    // Create provider using environment RPC URL
    const provider = new ethers.JsonRpcProvider(config.alchemyRpcUrl);

    let result;

    switch (method) {
      case 'getCode':
        if (!params[0]) {
          return res.status(400).json({ error: 'Address parameter required for getCode' });
        }
        result = await provider.getCode(params[0]);
        break;

      case 'call':
        if (!params[0]) {
          return res.status(400).json({ error: 'Transaction parameter required for call' });
        }
        result = await provider.call(params[0]);
        break;

      case 'getBalance':
        if (!params[0]) {
          return res.status(400).json({ error: 'Address parameter required for getBalance' });
        }
        result = await provider.getBalance(params[0]);
        break;

      default:
        return res.status(400).json({ error: `Unsupported method: ${method}` });
    }

    res.status(200).json({ result });

  } catch (error) {
    console.error('Provider API error:', error);
    res.status(500).json({ 
      error: 'Internal server error',
      message: error.message 
    });
  }
}
