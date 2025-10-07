module.exports = async function handler(req, res) {
  // Enable CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const factoryInfo = {
      availableFactories: {
        simple: {
          name: "WorkingFactory",
          address: "0xFc411603D1F1e2B1E9F692E2cBBb74Fd4f2feE18",
          type: "simple",
          description: "Custom deployed factory with getCalculatedAddress function",
          status: "✅ Recommended - No ethers.js bug",
          testUrl: "/api/calculateAccountAddress"
        },
        official: {
          name: "SimpleAccountFactory (Official)",
          address: "0x9406Cc6185a346906296840746125a0E44976454",
          type: "official", 
          description: "Official ERC-4337 SimpleAccountFactory",
          status: "✅ Working - Uses raw Interface calls",
          testUrl: "/api/calculateAccountAddress"
        }
      },
      defaultFactory: "simple",
      ethersJsBugInfo: {
        issue: "ethers.js Contract class returns factory address instead of predicted address for getAddress function",
        solution: "Use getCalculatedAddress (WorkingFactory) or raw Interface calls (Official factory)",
        affectedFunction: "getAddress(address,uint256)"
      },
      testParameters: {
        owner: "0x742d35cC6634c0532925A3b8d39E9C4b73e86E7D",
        salt: 0,
        expectedResults: {
          simple: "0x60F358E6C1C0479A9cA9284E3c798DfFc5d75b19",
          official: "0x57f372F761946b4197C7EC82c8D09E1B042380a6"
        }
      }
    };

    res.status(200).json(factoryInfo);

  } catch (error) {
    console.error('Factory info error:', error);
    res.status(500).json({
      error: 'Failed to get factory info',
      details: error.message
    });
  }
}
