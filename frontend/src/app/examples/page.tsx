'use client';

import { useState } from 'react';
import Link from 'next/link';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { tomorrow } from 'react-syntax-highlighter/dist/esm/styles/prism';
import { toast } from 'react-hot-toast';

interface CodeExample {
  id: string;
  title: string;
  description: string;
  language: string;
  code: string;
  category: 'integration' | 'smart-contracts' | 'frontend' | 'backend';
}

const CODE_EXAMPLES: CodeExample[] = [
  {
    id: 'basic-integration',
    title: 'Basic SuperPaymaster Integration',
    description: 'Get the best paymaster and use it in your UserOperation',
    language: 'javascript',
    category: 'integration',
    code: `import { ethers } from 'ethers';

// SuperPaymaster contract setup
const superPaymasterAddress = '0x...'; // Your deployed SuperPaymaster
const superPaymasterABI = [...]; // SuperPaymaster ABI

const provider = new ethers.providers.JsonRpcProvider('https://eth-sepolia.g.alchemy.com/v2/...');
const router = new ethers.Contract(superPaymasterAddress, superPaymasterABI, provider);

// Get the best available paymaster
async function getBestPaymaster() {
  try {
    const [paymasterAddress, feeRate] = await router.getBestPaymaster();
    console.log('Best paymaster:', paymasterAddress);
    console.log('Fee rate:', feeRate.toString(), 'basis points');
    return { paymasterAddress, feeRate };
  } catch (error) {
    console.error('No paymaster available:', error);
    return null;
  }
}

// Create a sponsored UserOperation
async function createSponsoredUserOp(userOp) {
  const bestPaymaster = await getBestPaymaster();
  
  if (!bestPaymaster) {
    throw new Error('No paymaster available');
  }

  // Use SuperPaymaster as the paymaster
  const sponsoredUserOp = {
    ...userOp,
    paymaster: superPaymasterAddress,
    paymasterAndData: superPaymasterAddress + '0'.repeat(40), // Minimal paymaster data
  };

  return sponsoredUserOp;
}

// Example usage
async function sendSponsoredTransaction() {
  const userOp = {
    sender: '0x...',        // Your smart account address
    nonce: '0x0',
    callData: '0x...',      // Your transaction call data
    callGasLimit: '0x30d40',
    verificationGasLimit: '0x30d40',
    preVerificationGas: '0x5208',
    maxFeePerGas: '0x59682f00',
    maxPriorityFeePerGas: '0x59682f00',
    signature: '0x...'      // Your signature
  };

  const sponsoredUserOp = await createSponsoredUserOp(userOp);
  
  // Submit to bundler
  const bundlerUrl = 'https://api.pimlico.io/v1/sepolia/rpc?apikey=...';
  const response = await fetch(bundlerUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'eth_sendUserOperation',
      params: [sponsoredUserOp, '0x...'], // EntryPoint address
      id: 1
    })
  });
  
  const result = await response.json();
  console.log('UserOperation sent:', result.result);
}`
  },
  {
    id: 'smart-contract-integration',
    title: 'Smart Contract Integration',
    description: 'Use SuperPaymaster directly in your smart contracts',
    language: 'solidity',
    category: 'smart-contracts',
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IPaymasterRouter.sol";

contract MyDApp {
    IPaymasterRouter public immutable superPaymaster;
    
    constructor(address _superPaymaster) {
        superPaymaster = IPaymasterRouter(_superPaymaster);
    }
    
    /// @notice Get the best paymaster for gas sponsorship
    function getBestSponsor() external view returns (
        address paymaster, 
        uint256 feeRate
    ) {
        return superPaymaster.getBestPaymaster();
    }
    
    /// @notice Check if gas sponsorship is available
    function isSponsorshipAvailable() external view returns (bool) {
        try superPaymaster.getBestPaymaster() returns (address paymaster, uint256) {
            return paymaster != address(0);
        } catch {
            return false;
        }
    }
    
    /// @notice Get all active paymasters
    function getAvailableSponsors() external view returns (address[] memory) {
        return superPaymaster.getActivePaymasters();
    }
    
    /// @notice Get sponsorship options with details
    function getSponsorshipOptions() external view returns (
        address[] memory paymasters,
        string[] memory names,
        uint256[] memory feeRates,
        bool[] memory availability
    ) {
        address[] memory activePaymasters = superPaymaster.getActivePaymasters();
        uint256 length = activePaymasters.length;
        
        paymasters = activePaymasters;
        names = new string[](length);
        feeRates = new uint256[](length);
        availability = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            try superPaymaster.getPaymasterInfo(activePaymasters[i]) returns (
                IPaymasterRouter.PaymasterPool memory pool
            ) {
                names[i] = pool.name;
                feeRates[i] = pool.feeRate;
                availability[i] = pool.isActive;
            } catch {
                names[i] = "Unknown";
                feeRates[i] = 0;
                availability[i] = false;
            }
        }
    }
    
    /// @notice Estimate gas cost with sponsorship
    function estimateSponsoredCost(uint256 gasEstimate) 
        external 
        view 
        returns (uint256 totalCost, uint256 sponsorFee) 
    {
        (, uint256 feeRate) = superPaymaster.getBestPaymaster();
        
        // Calculate base cost
        uint256 baseCost = gasEstimate * tx.gasprice;
        
        // Calculate sponsor fee (in basis points)
        sponsorFee = (baseCost * feeRate) / 10000;
        totalCost = baseCost + sponsorFee;
    }
}`
  },
  {
    id: 'react-hook',
    title: 'React Hook for SuperPaymaster',
    description: 'Custom React hook to integrate SuperPaymaster in your dApp',
    language: 'typescript',
    category: 'frontend',
    code: `import { useState, useEffect, useCallback } from 'react';
import { useContractRead, useContractWrite } from 'wagmi';
import { toast } from 'react-hot-toast';

interface PaymasterInfo {
  address: string;
  feeRate: bigint;
  name: string;
  isActive: boolean;
  successRate: number;
}

interface UseSuperPaymasterReturn {
  bestPaymaster: PaymasterInfo | null;
  allPaymasters: PaymasterInfo[];
  isLoading: boolean;
  error: string | null;
  getBestPaymaster: () => Promise<PaymasterInfo | null>;
  sponsorUserOperation: (userOp: any) => Promise<any>;
}

export function useSuperPaymaster(
  contractAddress: string,
  abi: any[]
): UseSuperPaymasterReturn {
  const [bestPaymaster, setBestPaymaster] = useState<PaymasterInfo | null>(null);
  const [allPaymasters, setAllPaymasters] = useState<PaymasterInfo[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Read best paymaster
  const { data: bestPaymasterData, refetch: refetchBest } = useContractRead({
    address: contractAddress as \`0x\${string}\`,
    abi,
    functionName: 'getBestPaymaster',
  });

  // Read all active paymasters
  const { data: activePaymastersData, refetch: refetchActive } = useContractRead({
    address: contractAddress as \`0x\${string}\`,
    abi,
    functionName: 'getActivePaymasters',
  });

  // Get best paymaster function
  const getBestPaymaster = useCallback(async (): Promise<PaymasterInfo | null> => {
    try {
      setIsLoading(true);
      setError(null);
      
      const { data } = await refetchBest();
      
      if (!data || data[0] === '0x0000000000000000000000000000000000000000') {
        setError('No paymaster available');
        return null;
      }

      const [address, feeRate] = data as [string, bigint];
      
      // Get additional info
      const paymasterInfo: PaymasterInfo = {
        address,
        feeRate,
        name: 'Best Paymaster',
        isActive: true,
        successRate: 0,
      };

      setBestPaymaster(paymasterInfo);
      return paymasterInfo;
      
    } catch (err) {
      const errorMsg = 'Failed to get best paymaster';
      setError(errorMsg);
      toast.error(errorMsg);
      return null;
    } finally {
      setIsLoading(false);
    }
  }, [refetchBest]);

  // Sponsor user operation
  const sponsorUserOperation = useCallback(async (userOp: any) => {
    const paymaster = await getBestPaymaster();
    
    if (!paymaster) {
      throw new Error('No paymaster available for sponsorship');
    }

    // Return sponsored user operation
    return {
      ...userOp,
      paymaster: contractAddress,
      paymasterAndData: contractAddress + '0'.repeat(40),
      // You might want to add more complex paymaster data here
    };
  }, [contractAddress, getBestPaymaster]);

  // Load all paymasters info
  useEffect(() => {
    const loadAllPaymasters = async () => {
      if (!activePaymastersData) return;

      try {
        setIsLoading(true);
        const addresses = activePaymastersData as string[];
        
        const paymasterInfos = await Promise.all(
          addresses.map(async (address) => {
            try {
              // In a real app, you'd call getPaymasterInfo for each
              return {
                address,
                feeRate: 0n,
                name: 'Unknown Paymaster',
                isActive: true,
                successRate: 0,
              };
            } catch {
              return null;
            }
          })
        );

        setAllPaymasters(paymasterInfos.filter(Boolean) as PaymasterInfo[]);
      } catch (err) {
        setError('Failed to load paymasters');
      } finally {
        setIsLoading(false);
      }
    };

    loadAllPaymasters();
  }, [activePaymastersData]);

  // Auto-fetch best paymaster on mount
  useEffect(() => {
    getBestPaymaster();
  }, [getBestPaymaster]);

  return {
    bestPaymaster,
    allPaymasters,
    isLoading,
    error,
    getBestPaymaster,
    sponsorUserOperation,
  };
}

// Usage example:
// const { bestPaymaster, sponsorUserOperation, isLoading } = useSuperPaymaster(
//   '0x...', // SuperPaymaster contract address
//   SuperPaymasterABI
// );`
  },
  {
    id: 'nodejs-backend',
    title: 'Node.js Backend Integration',
    description: 'Server-side integration for managing paymaster operations',
    language: 'typescript',
    category: 'backend',
    code: `import { ethers } from 'ethers';
import express from 'express';
import cors from 'cors';

class SuperPaymasterService {
  private provider: ethers.providers.JsonRpcProvider;
  private router: ethers.Contract;
  private signer: ethers.Wallet;

  constructor(
    rpcUrl: string,
    contractAddress: string,
    contractAbi: any[],
    privateKey: string
  ) {
    this.provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    this.signer = new ethers.Wallet(privateKey, this.provider);
    this.router = new ethers.Contract(contractAddress, contractAbi, this.signer);
  }

  // Get best paymaster
  async getBestPaymaster() {
    try {
      const [address, feeRate] = await this.router.getBestPaymaster();
      return {
        success: true,
        data: { address, feeRate: feeRate.toString() }
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Failed to get best paymaster'
      };
    }
  }

  // Get all active paymasters with details
  async getAllPaymasters() {
    try {
      const addresses = await this.router.getActivePaymasters();
      
      const paymasters = await Promise.all(
        addresses.map(async (address: string) => {
          try {
            const info = await this.router.getPaymasterInfo(address);
            return {
              address,
              name: info.name,
              feeRate: info.feeRate.toString(),
              isActive: info.isActive,
              successCount: info.successCount.toString(),
              totalAttempts: info.totalAttempts.toString(),
              successRate: info.totalAttempts.gt(0) 
                ? (info.successCount.mul(100).div(info.totalAttempts)).toString()
                : '0'
            };
          } catch {
            return null;
          }
        })
      );

      return {
        success: true,
        data: paymasters.filter(Boolean)
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Failed to get paymasters'
      };
    }
  }

  // Register a new paymaster (admin only)
  async registerPaymaster(address: string, feeRate: number, name: string) {
    try {
      const tx = await this.router.registerPaymaster(
        address,
        feeRate,
        name
      );
      
      const receipt = await tx.wait();
      
      return {
        success: true,
        data: {
          transactionHash: tx.hash,
          blockNumber: receipt.blockNumber
        }
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Failed to register paymaster'
      };
    }
  }

  // Sponsor a user operation
  async sponsorUserOperation(userOp: any) {
    const bestPaymaster = await this.getBestPaymaster();
    
    if (!bestPaymaster.success) {
      throw new Error('No paymaster available');
    }

    return {
      ...userOp,
      paymaster: this.router.address,
      paymasterAndData: this.router.address + '0'.repeat(40)
    };
  }

  // Get router statistics
  async getRouterStats() {
    try {
      const stats = await this.router.getRouterStats();
      
      return {
        success: true,
        data: {
          totalPaymasters: stats.totalPaymasters.toString(),
          activePaymasters: stats.activePaymasters.toString(),
          totalSuccessfulRoutes: stats.totalSuccessfulRoutes.toString(),
          totalRoutes: stats.totalRoutes.toString(),
          successRate: stats.totalRoutes.gt(0)
            ? (stats.totalSuccessfulRoutes.mul(100).div(stats.totalRoutes)).toString()
            : '0'
        }
      };
    } catch (error: any) {
      return {
        success: false,
        error: error.message || 'Failed to get router stats'
      };
    }
  }
}

// Express API setup
const app = express();
app.use(cors());
app.use(express.json());

const paymasterService = new SuperPaymasterService(
  process.env.RPC_URL!,
  process.env.SUPER_PAYMASTER_ADDRESS!,
  [], // SuperPaymaster ABI
  process.env.PRIVATE_KEY!
);

// API Routes
app.get('/api/paymaster/best', async (req, res) => {
  const result = await paymasterService.getBestPaymaster();
  res.json(result);
});

app.get('/api/paymaster/all', async (req, res) => {
  const result = await paymasterService.getAllPaymasters();
  res.json(result);
});

app.get('/api/router/stats', async (req, res) => {
  const result = await paymasterService.getRouterStats();
  res.json(result);
});

app.post('/api/paymaster/register', async (req, res) => {
  const { address, feeRate, name } = req.body;
  
  if (!address || feeRate === undefined || !name) {
    return res.status(400).json({
      success: false,
      error: 'Missing required fields: address, feeRate, name'
    });
  }

  const result = await paymasterService.registerPaymaster(address, feeRate, name);
  res.json(result);
});

app.post('/api/userop/sponsor', async (req, res) => {
  try {
    const sponsoredUserOp = await paymasterService.sponsorUserOperation(req.body);
    res.json({
      success: true,
      data: sponsoredUserOp
    });
  } catch (error: any) {
    res.json({
      success: false,
      error: error.message
    });
  }
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'OK', timestamp: new Date().toISOString() });
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  console.log(\`SuperPaymaster API server running on port \${PORT}\`);
});`
  },
  {
    id: 'user-operation-example',
    title: 'Complete UserOperation Example',
    description: 'Full example of creating and submitting a sponsored UserOperation',
    language: 'javascript',
    category: 'integration',
    code: `import { ethers } from 'ethers';

class UserOperationBuilder {
  constructor(provider, bundlerUrl, superPaymasterAddress) {
    this.provider = provider;
    this.bundlerUrl = bundlerUrl;
    this.superPaymasterAddress = superPaymasterAddress;
  }

  // Build a complete UserOperation with SuperPaymaster sponsorship
  async buildSponsoredUserOperation({
    sender,          // Smart account address
    target,          // Target contract address
    callData,        // Call data for the transaction
    signer          // EOA signer for the smart account
  }) {
    try {
      // 1. Get nonce
      const nonce = await this.getUserOpNonce(sender);
      
      // 2. Build initial UserOperation
      const userOp = {
        sender,
        nonce: ethers.utils.hexlify(nonce),
        callData,
        callGasLimit: '0x0',
        verificationGasLimit: '0x0',
        preVerificationGas: '0x0',
        maxFeePerGas: '0x0',
        maxPriorityFeePerGas: '0x0',
        paymaster: this.superPaymasterAddress,
        paymasterAndData: this.superPaymasterAddress,
        signature: '0x'
      };

      // 3. Estimate gas
      const gasEstimate = await this.estimateUserOpGas(userOp);
      userOp.callGasLimit = gasEstimate.callGasLimit;
      userOp.verificationGasLimit = gasEstimate.verificationGasLimit;
      userOp.preVerificationGas = gasEstimate.preVerificationGas;

      // 4. Get gas prices
      const gasPrice = await this.provider.getGasPrice();
      userOp.maxFeePerGas = gasPrice.toHexString();
      userOp.maxPriorityFeePerGas = gasPrice.toHexString();

      // 5. Sign the UserOperation
      const userOpHash = await this.getUserOpHash(userOp);
      const signature = await signer.signMessage(ethers.utils.arrayify(userOpHash));
      userOp.signature = signature;

      return userOp;
      
    } catch (error) {
      console.error('Failed to build UserOperation:', error);
      throw error;
    }
  }

  // Submit UserOperation to bundler
  async submitUserOperation(userOp) {
    try {
      const response = await fetch(this.bundlerUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: 'eth_sendUserOperation',
          params: [userOp, process.env.ENTRY_POINT_ADDRESS],
          id: 1
        })
      });

      const result = await response.json();
      
      if (result.error) {
        throw new Error(result.error.message);
      }

      return {
        userOpHash: result.result,
        userOp
      };
      
    } catch (error) {
      console.error('Failed to submit UserOperation:', error);
      throw error;
    }
  }

  // Wait for UserOperation to be included in a block
  async waitForUserOpReceipt(userOpHash, maxWaitTime = 60000) {
    const startTime = Date.now();
    
    while (Date.now() - startTime < maxWaitTime) {
      try {
        const response = await fetch(this.bundlerUrl, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            jsonrpc: '2.0',
            method: 'eth_getUserOperationReceipt',
            params: [userOpHash],
            id: 1
          })
        });

        const result = await response.json();
        
        if (result.result) {
          return result.result;
        }
        
        // Wait 2 seconds before checking again
        await new Promise(resolve => setTimeout(resolve, 2000));
        
      } catch (error) {
        console.error('Error checking UserOp receipt:', error);
      }
    }
    
    throw new Error('UserOperation receipt not found within timeout');
  }

  // Helper methods
  async getUserOpNonce(sender) {
    // Implementation depends on your smart account setup
    // This is a simplified example
    return 0;
  }

  async estimateUserOpGas(userOp) {
    const response = await fetch(this.bundlerUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'eth_estimateUserOperationGas',
        params: [userOp, process.env.ENTRY_POINT_ADDRESS],
        id: 1
      })
    });

    const result = await response.json();
    return result.result;
  }

  async getUserOpHash(userOp) {
    // Implementation depends on your smart account and EntryPoint
    // This would typically involve calling the EntryPoint contract
    return ethers.utils.keccak256('0x'); // Placeholder
  }
}

// Usage example
async function sponsoredTransactionExample() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
  
  const builder = new UserOperationBuilder(
    provider,
    'https://api.pimlico.io/v1/sepolia/rpc?apikey=YOUR_KEY',
    '0x...' // SuperPaymaster address
  );

  // Example: Send ETH transfer
  const target = '0x...'; // Recipient address
  const amount = ethers.utils.parseEther('0.01');
  const callData = '0x'; // Simple ETH transfer has no calldata

  try {
    console.log('Building sponsored UserOperation...');
    const userOp = await builder.buildSponsoredUserOperation({
      sender: '0x...', // Your smart account address
      target,
      callData,
      signer
    });

    console.log('Submitting UserOperation...');
    const { userOpHash } = await builder.submitUserOperation(userOp);
    console.log('UserOperation hash:', userOpHash);

    console.log('Waiting for confirmation...');
    const receipt = await builder.waitForUserOpReceipt(userOpHash);
    console.log('UserOperation confirmed!', receipt);

  } catch (error) {
    console.error('Sponsored transaction failed:', error);
  }
}

// Run the example
sponsoredTransactionExample();`
  }
];

export default function APIExamples() {
  const [selectedCategory, setSelectedCategory] = useState<string>('integration');
  const [selectedExample, setSelectedExample] = useState<CodeExample>(CODE_EXAMPLES[0]);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const categories = [
    { id: 'integration', name: 'Integration', icon: '🔌' },
    { id: 'smart-contracts', name: 'Smart Contracts', icon: '📜' },
    { id: 'frontend', name: 'Frontend', icon: '⚛️' },
    { id: 'backend', name: 'Backend', icon: '🚀' }
  ];

  const filteredExamples = CODE_EXAMPLES.filter(example => 
    example.category === selectedCategory
  );

  const copyToClipboard = async (code: string, id: string) => {
    try {
      await navigator.clipboard.writeText(code);
      setCopiedId(id);
      toast.success('Code copied to clipboard!');
      setTimeout(() => setCopiedId(null), 2000);
    } catch (error) {
      toast.error('Failed to copy code');
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-green-900 to-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700 bg-slate-900/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            <div className="flex items-center space-x-4">
              <Link href="/" className="flex items-center space-x-4 hover:opacity-80 transition-opacity">
                <div className="w-10 h-10 bg-gradient-to-r from-green-500 to-blue-600 rounded-lg flex items-center justify-center">
                  <span className="text-white font-bold text-xl">📚</span>
                </div>
                <div>
                  <h1 className="text-2xl font-bold text-white">API Examples</h1>
                  <p className="text-slate-400 text-sm">Integration guides and code samples</p>
                </div>
              </Link>
            </div>
            <ConnectButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Breadcrumb */}
        <nav className="mb-8">
          <div className="flex items-center space-x-2 text-sm">
            <Link href="/" className="text-green-400 hover:text-green-300">Dashboard</Link>
            <span className="text-slate-500">›</span>
            <span className="text-slate-300">API Examples</span>
          </div>
        </nav>

        {/* Introduction */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6 mb-8">
          <h2 className="text-xl font-bold text-white mb-4">🚀 SuperPaymaster Integration Guide</h2>
          <p className="text-slate-300 mb-4">
            SuperPaymaster enables seamless gas sponsorship for your dApp users. Browse the examples below 
            to learn how to integrate SuperPaymaster into your application.
          </p>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div className="bg-slate-700/50 rounded-lg p-4">
              <h3 className="font-semibold text-white mb-2">🎯 Quick Start</h3>
              <p className="text-slate-400 text-sm">
                Use getBestPaymaster() to find the most cost-effective sponsor for your user operations.
              </p>
            </div>
            <div className="bg-slate-700/50 rounded-lg p-4">
              <h3 className="font-semibold text-white mb-2">⚡ Automatic Routing</h3>
              <p className="text-slate-400 text-sm">
                SuperPaymaster automatically selects the best paymaster based on fees and availability.
              </p>
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-4 gap-8">
          {/* Sidebar */}
          <div className="lg:col-span-1">
            <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-4 sticky top-4">
              <h3 className="font-semibold text-white mb-4">Categories</h3>
              
              {/* Category Tabs */}
              <div className="space-y-2 mb-6">
                {categories.map((category) => (
                  <button
                    key={category.id}
                    onClick={() => {
                      setSelectedCategory(category.id);
                      const firstExample = CODE_EXAMPLES.find(ex => ex.category === category.id);
                      if (firstExample) setSelectedExample(firstExample);
                    }}
                    className={`w-full text-left px-3 py-2 rounded-lg transition-colors flex items-center space-x-2 ${
                      selectedCategory === category.id
                        ? 'bg-green-600 text-white'
                        : 'text-slate-400 hover:text-white hover:bg-slate-700'
                    }`}
                  >
                    <span>{category.icon}</span>
                    <span>{category.name}</span>
                  </button>
                ))}
              </div>

              {/* Example List */}
              <div className="space-y-2">
                <h4 className="text-sm font-medium text-slate-400 mb-2">Examples</h4>
                {filteredExamples.map((example) => (
                  <button
                    key={example.id}
                    onClick={() => setSelectedExample(example)}
                    className={`w-full text-left px-3 py-2 rounded-lg transition-colors text-sm ${
                      selectedExample.id === example.id
                        ? 'bg-slate-700 text-white'
                        : 'text-slate-400 hover:text-white hover:bg-slate-700'
                    }`}
                  >
                    {example.title}
                  </button>
                ))}
              </div>
            </div>
          </div>

          {/* Main Content */}
          <div className="lg:col-span-3">
            <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700">
              {/* Example Header */}
              <div className="p-6 border-b border-slate-700">
                <div className="flex justify-between items-start mb-4">
                  <div>
                    <h2 className="text-xl font-bold text-white mb-2">{selectedExample.title}</h2>
                    <p className="text-slate-400">{selectedExample.description}</p>
                  </div>
                  <div className="flex items-center space-x-2">
                    <span className="px-2 py-1 bg-slate-700 text-slate-300 text-xs rounded-lg">
                      {selectedExample.language}
                    </span>
                    <button
                      onClick={() => copyToClipboard(selectedExample.code, selectedExample.id)}
                      className="px-3 py-1 bg-green-600 hover:bg-green-700 text-white text-xs rounded-lg transition-colors flex items-center space-x-1"
                    >
                      {copiedId === selectedExample.id ? (
                        <>
                          <span>✓</span>
                          <span>Copied</span>
                        </>
                      ) : (
                        <>
                          <span>📋</span>
                          <span>Copy</span>
                        </>
                      )}
                    </button>
                  </div>
                </div>
              </div>

              {/* Code Block */}
              <div className="relative">
                <SyntaxHighlighter
                  language={selectedExample.language}
                  style={tomorrow}
                  className="!bg-slate-900 !rounded-none"
                  customStyle={{
                    margin: 0,
                    padding: '1.5rem',
                    fontSize: '0.875rem',
                    lineHeight: '1.5',
                  }}
                  showLineNumbers
                  wrapLines
                  lineNumberStyle={{ color: '#64748b', fontSize: '0.75rem' }}
                >
                  {selectedExample.code}
                </SyntaxHighlighter>
              </div>
            </div>

            {/* Quick Reference */}
            <div className="mt-8 bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6">
              <h3 className="text-lg font-bold text-white mb-4">📖 Quick Reference</h3>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
                <div>
                  <h4 className="font-semibold text-green-400 mb-2">Contract Addresses (Sepolia)</h4>
                  <div className="space-y-1 text-slate-400">
                    <div>SuperPaymasterV7: <code className="text-white">{process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7 || 'Not deployed'}</code></div>
                    <div>EntryPoint V7: <code className="text-white">{process.env.NEXT_PUBLIC_ENTRY_POINT_V7}</code></div>
                  </div>
                </div>
                <div>
                  <h4 className="font-semibold text-green-400 mb-2">Key Functions</h4>
                  <div className="space-y-1 text-slate-400">
                    <div><code className="text-white">getBestPaymaster()</code> - Find cheapest sponsor</div>
                    <div><code className="text-white">getActivePaymasters()</code> - List all sponsors</div>
                    <div><code className="text-white">registerPaymaster()</code> - Add new sponsor</div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}