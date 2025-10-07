'use client';

import { useState, useEffect } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt, usePublicClient } from 'wagmi';
import { MetaMaskButton } from '@/components/MetaMaskButton';
import { formatEther, parseEther } from 'viem';
import { toast } from 'react-hot-toast';
import Link from 'next/link';

type EntryPointVersion = 'v6' | 'v7' | 'v8';

interface DeploymentStep {
  id: string;
  title: string;
  description: string;
  status: 'pending' | 'active' | 'completed' | 'error';
}

export default function DeploySuperPaymaster() {
  const [mounted, setMounted] = useState(false);
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const [selectedVersion, setSelectedVersion] = useState<EntryPointVersion>('v7');
  const [currentStep, setCurrentStep] = useState(0);
  const [deployedAddress, setDeployedAddress] = useState<string>('');
  const [estimatedGas, setEstimatedGas] = useState<string>('');

  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const { isLoading: isConfirming, isSuccess, data: receipt } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    setMounted(true);
  }, []);

  const getEntryPointAddress = (version: EntryPointVersion) => {
    switch (version) {
      case 'v6': return process.env.NEXT_PUBLIC_ENTRY_POINT_V6;
      case 'v7': return process.env.NEXT_PUBLIC_ENTRY_POINT_V7;
      case 'v8': return process.env.NEXT_PUBLIC_ENTRY_POINT_V8;
    }
  };

  const isAlreadyDeployed = (version: EntryPointVersion) => {
    switch (version) {
      case 'v6': return !!process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V6;
      case 'v7': return !!process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7;
      case 'v8': return !!process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V8;
    }
  };

  const steps: DeploymentStep[] = [
    {
      id: 'select',
      title: 'Select EntryPoint Version',
      description: 'Choose which EntryPoint version to deploy SuperPaymaster for',
      status: currentStep === 0 ? 'active' : currentStep > 0 ? 'completed' : 'pending',
    },
    {
      id: 'deploy',
      title: 'Deploy Contract',
      description: 'Deploy the SuperPaymaster router contract to the blockchain',
      status: currentStep === 1 ? 'active' : currentStep > 1 ? 'completed' : 'pending',
    },
    {
      id: 'configure',
      title: 'Update Configuration',
      description: 'Update environment variables with the deployed address',
      status: currentStep === 2 ? 'active' : currentStep > 2 ? 'completed' : 'pending',
    },
    {
      id: 'verify',
      title: 'Verify Deployment',
      description: 'Verify the contract on Etherscan',
      status: currentStep === 3 ? 'active' : currentStep > 3 ? 'completed' : 'pending',
    },
  ];

  // Watch for successful deployment
  useEffect(() => {
    if (isSuccess && receipt) {
      const contractAddress = receipt.contractAddress;
      if (contractAddress) {
        setDeployedAddress(contractAddress);
        setCurrentStep(2);
        toast.success('SuperPaymaster deployed successfully!');
      }
    }
  }, [isSuccess, receipt]);

  // Estimate gas costs
  useEffect(() => {
    const estimateGas = async () => {
      if (!publicClient) return;
      
      try {
        // Rough estimate based on SuperPaymaster contract size
        const gasPrice = await publicClient.getGasPrice();
        const estimatedGasUnits = BigInt(2500000); // ~2.5M gas for deployment
        const totalCost = gasPrice * estimatedGasUnits;
        setEstimatedGas(formatEther(totalCost));
      } catch (error) {
        console.error('Gas estimation error:', error);
        setEstimatedGas('0.05'); // Fallback estimate
      }
    };

    if (mounted) {
      estimateGas();
    }
  }, [publicClient, mounted]);

  const handleDeploy = async () => {
    if (!isConnected || !address) {
      toast.error('Please connect your wallet first');
      return;
    }

    const entryPointAddress = getEntryPointAddress(selectedVersion);
    if (!entryPointAddress) {
      toast.error('Invalid EntryPoint address');
      return;
    }

    try {
      setCurrentStep(1);
      toast.error('SuperPaymaster deployment requires manual deployment via Forge script. Please contact the administrator.');
      setCurrentStep(0);
      return;
    } catch (err) {
      console.error('Deployment error:', err);
      toast.error('Failed to deploy SuperPaymaster');
      setCurrentStep(0);
    }
  };

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text);
    toast.success('Address copied to clipboard');
  };

  const getStatusIcon = (status: DeploymentStep['status']) => {
    switch (status) {
      case 'completed': return '✅';
      case 'active': return '🔄';
      case 'error': return '❌';
      default: return '⭕';
    }
  };

  if (!mounted) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900">
        <div className="flex items-center justify-center min-h-screen">
          <div className="animate-spin rounded-full h-32 w-32 border-b-2 border-white"></div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700 bg-slate-900/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            <div className="flex items-center space-x-4">
              <Link href="/admin" className="flex items-center space-x-4 hover:opacity-80 transition-opacity">
                <div className="w-10 h-10 bg-gradient-to-r from-purple-500 to-pink-600 rounded-lg flex items-center justify-center">
                  <span className="text-white font-bold text-xl">🚀</span>
                </div>
                <div>
                  <h1 className="text-2xl font-bold text-white">Deploy SuperPaymaster</h1>
                  <p className="text-slate-400 text-sm">Deploy the SuperPaymaster router contract</p>
                </div>
              </Link>
            </div>
            <MetaMaskButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        
        {/* Progress Steps */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-8 mb-8">
          <h2 className="text-2xl font-bold text-white mb-6">Deployment Progress</h2>
          
          <div className="space-y-4">
            {steps.map((step, index) => (
              <div key={step.id} className="flex items-center space-x-4 p-4 rounded-lg bg-slate-700/30">
                <div className={`w-12 h-12 rounded-full flex items-center justify-center text-xl ${
                  step.status === 'completed' ? 'bg-green-500/20 text-green-400' :
                  step.status === 'active' ? 'bg-blue-500/20 text-blue-400' :
                  step.status === 'error' ? 'bg-red-500/20 text-red-400' :
                  'bg-slate-600/20 text-slate-400'
                }`}>
                  {getStatusIcon(step.status)}
                </div>
                <div className="flex-1">
                  <h3 className="text-lg font-semibold text-white">{step.title}</h3>
                  <p className="text-slate-400 text-sm">{step.description}</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Step 1: Version Selection */}
        {currentStep === 0 && (
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-8 mb-8">
            <h2 className="text-xl font-bold text-white mb-6">Select EntryPoint Version</h2>
            
            <div className="space-y-4">
              {(['v6', 'v7', 'v8'] as EntryPointVersion[]).map((version) => {
                const isDeployed = isAlreadyDeployed(version);
                
                return (
                  <div
                    key={version}
                    className={`p-4 rounded-lg border cursor-pointer transition-all ${
                      selectedVersion === version
                        ? 'border-purple-500 bg-purple-500/10'
                        : isDeployed 
                          ? 'border-gray-500 bg-gray-500/10 opacity-50 cursor-not-allowed'
                          : 'border-slate-600 bg-slate-700/30 hover:border-slate-500'
                    }`}
                    onClick={() => !isDeployed && setSelectedVersion(version)}
                  >
                    <div className="flex items-center justify-between">
                      <div>
                        <h3 className="text-lg font-semibold text-white">EntryPoint {version.toUpperCase()}</h3>
                        <p className="text-slate-400 text-sm">
                          Address: {getEntryPointAddress(version)}
                        </p>
                      </div>
                      <div className="flex items-center space-x-2">
                        {isDeployed && (
                          <span className="px-3 py-1 bg-green-500/20 text-green-400 text-sm rounded-full">
                            Already Deployed
                          </span>
                        )}
                        {selectedVersion === version && !isDeployed && (
                          <span className="px-3 py-1 bg-purple-500/20 text-purple-400 text-sm rounded-full">
                            Selected
                          </span>
                        )}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>

            {/* Gas Estimation */}
            <div className="mt-6 p-4 bg-slate-700/30 rounded-lg">
              <div className="flex items-center justify-between">
                <div>
                  <h4 className="text-white font-medium">Estimated Deployment Cost</h4>
                  <p className="text-slate-400 text-sm">Gas cost on Sepolia testnet</p>
                </div>
                <div className="text-right">
                  <p className="text-xl font-bold text-white">{estimatedGas} ETH</p>
                  <p className="text-slate-400 text-sm">+ Network fees</p>
                </div>
              </div>
            </div>

            <div className="flex justify-end mt-6">
              <button
                onClick={() => setCurrentStep(1)}
                disabled={!isConnected || isAlreadyDeployed(selectedVersion)}
                className="px-6 py-3 bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 disabled:from-slate-600 disabled:to-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors"
              >
                {!isConnected ? 'Connect Wallet First' : 
                 isAlreadyDeployed(selectedVersion) ? 'Already Deployed' : 
                 'Continue to Deployment'}
              </button>
            </div>
          </div>
        )}

        {/* Step 2: Deployment Instructions */}
        {currentStep === 1 && (
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-8 mb-8">
            <h2 className="text-xl font-bold text-white mb-6">Deploy SuperPaymaster Contract</h2>
            
            <div className="space-y-6">
              <div className="p-4 bg-slate-700/30 rounded-lg">
                <h3 className="text-lg font-semibold text-white mb-2">Deployment Details</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-slate-400">EntryPoint Version:</span>
                    <span className="text-white">{selectedVersion.toUpperCase()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">EntryPoint Address:</span>
                    <span className="text-white font-mono text-xs">{getEntryPointAddress(selectedVersion)}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">Network:</span>
                    <span className="text-white">Sepolia Testnet</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">Your Address:</span>
                    <span className="text-white font-mono text-xs">{address}</span>
                  </div>
                </div>
              </div>

              <div className="p-4 bg-blue-500/10 border border-blue-500/20 rounded-lg">
                <h3 className="text-blue-400 font-medium mb-2">👨‍💼 Administrator Deployment Instructions</h3>
                <p className="text-blue-300 text-sm mb-4">
                  SuperPaymaster deployment is a <strong>one-time administrator operation</strong>. Once deployed, all paymaster operators can register their paymasters to this router.
                </p>
                
                <div className="space-y-4">
                  <div className="p-3 bg-blue-500/10 border border-blue-500/20 rounded-lg">
                    <h4 className="text-blue-400 font-medium text-sm mb-2">⚡ Option 1: Automated Script (推荐)</h4>
                    <div className="bg-slate-900 p-3 rounded text-green-400 text-sm font-mono">
                      cd SuperPaymaster-Contract<br/>
                      ./deploy-superpaymaster.sh
                    </div>
                  </div>
                  
                  <div className="p-3 bg-gray-500/10 border border-gray-500/20 rounded-lg">
                    <h4 className="text-gray-400 font-medium text-sm mb-2">🔧 Option 2: Manual Forge</h4>
                    <div className="bg-slate-900 p-3 rounded text-green-400 text-sm font-mono">
                      export SEPOLIA_PRIVATE_KEY="your_private_key_here"<br/>
                      forge script script/DeploySuperpaymaster.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
                    </div>
                  </div>
                </div>
              </div>

              <div className="p-4 bg-yellow-500/10 border border-yellow-500/20 rounded-lg">
                <h3 className="text-yellow-400 font-medium mb-2">⚠️ Important Notes</h3>
                <ul className="text-yellow-300 text-sm space-y-1">
                  <li>• You will become the owner of the deployed SuperPaymaster contract</li>
                  <li>• Make sure you have enough Sepolia ETH for deployment (~0.1 ETH recommended)</li>
                  <li>• The script will deploy and fund the contract with 0.1 ETH automatically</li>
                  <li>• Keep your private key secure and never share it</li>
                </ul>
              </div>

              <div className="flex space-x-4">
                <button
                  onClick={() => setCurrentStep(0)}
                  className="px-6 py-3 bg-slate-600 hover:bg-slate-700 text-white font-medium rounded-lg transition-colors"
                >
                  Back
                </button>
                <button
                  onClick={() => {
                    setCurrentStep(2);
                    // Simulate deployed address for demo (in real scenario, user would input this)
                    setDeployedAddress('0x1234567890123456789012345678901234567890');
                  }}
                  className="flex-1 px-6 py-3 bg-gradient-to-r from-blue-600 to-purple-600 hover:from-blue-700 hover:to-purple-700 text-white font-medium rounded-lg transition-colors"
                >
                  I have deployed the contract
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Step 3: Configuration */}
        {currentStep === 2 && (
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-8 mb-8">
            <h2 className="text-xl font-bold text-white mb-6">Enter Deployed Contract Address</h2>
            
            <div className="space-y-6">
              <div className="p-4 bg-blue-500/10 border border-blue-500/20 rounded-lg">
                <h3 className="text-blue-400 font-medium mb-2">📋 Enter Deployment Information</h3>
                <p className="text-blue-300 text-sm mb-4">
                  Please enter the SuperPaymaster contract address that was output from the Forge deployment script.
                </p>
              </div>

              <div>
                <label className="block text-sm font-medium text-slate-300 mb-3">
                  SuperPaymaster Contract Address
                </label>
                <input
                  type="text"
                  value={deployedAddress}
                  onChange={(e) => setDeployedAddress(e.target.value)}
                  placeholder="0x..."
                  className={`w-full px-4 py-3 bg-slate-700 border rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:border-transparent font-mono text-sm ${
                    deployedAddress && !deployedAddress.match(/^0x[a-fA-F0-9]{40}$/)
                      ? 'border-red-500 focus:ring-red-500'
                      : 'border-slate-600 focus:ring-purple-500'
                  }`}
                />
                {deployedAddress && !deployedAddress.match(/^0x[a-fA-F0-9]{40}$/) && (
                  <p className="mt-2 text-red-400 text-sm">Please enter a valid Ethereum address</p>
                )}
                {deployedAddress && deployedAddress.match(/^0x[a-fA-F0-9]{40}$/) && (
                  <p className="mt-2 text-green-400 text-sm">✓ Valid contract address</p>
                )}
              </div>

              {deployedAddress && deployedAddress.match(/^0x[a-fA-F0-9]{40}$/) && (
                <div className="p-4 bg-green-500/10 border border-green-500/20 rounded-lg">
                  <h3 className="text-green-400 font-medium mb-2">✅ Ready for Configuration</h3>
                  <p className="text-green-300 text-sm mb-4">
                    Please update your environment variables with the deployed contract address:
                  </p>
                  <div className="bg-slate-900 p-4 rounded-lg">
                    <code className="text-green-400 text-sm">
                      NEXT_PUBLIC_SUPER_PAYMASTER_{selectedVersion.toUpperCase()}="{deployedAddress}"
                    </code>
                  </div>
                  <div className="mt-3 flex items-center space-x-2">
                    <button
                      onClick={() => copyToClipboard(deployedAddress)}
                      className="px-3 py-1 bg-green-600 hover:bg-green-700 text-white text-sm rounded-lg transition-colors"
                    >
                      Copy Address
                    </button>
                    <button
                      onClick={() => copyToClipboard(`NEXT_PUBLIC_SUPER_PAYMASTER_${selectedVersion.toUpperCase()}="${deployedAddress}"`)}
                      className="px-3 py-1 bg-blue-600 hover:bg-blue-700 text-white text-sm rounded-lg transition-colors"
                    >
                      Copy Env Variable
                    </button>
                  </div>
                </div>
              )}

              <div className="flex space-x-4">
                <button
                  onClick={() => setCurrentStep(1)}
                  className="px-6 py-3 bg-slate-600 hover:bg-slate-700 text-white font-medium rounded-lg transition-colors"
                >
                  Back
                </button>
                <button
                  onClick={() => setCurrentStep(3)}
                  disabled={!deployedAddress || !deployedAddress.match(/^0x[a-fA-F0-9]{40}$/)}
                  className="flex-1 px-6 py-3 bg-gradient-to-r from-blue-600 to-purple-600 hover:from-blue-700 hover:to-purple-700 disabled:from-slate-600 disabled:to-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors"
                >
                  Continue to Verification
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Step 4: Verification */}
        {currentStep === 3 && deployedAddress && (
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-8 mb-8">
            <h2 className="text-xl font-bold text-white mb-6">Verify Contract</h2>
            
            <div className="space-y-6">
              <div className="p-4 bg-slate-700/30 rounded-lg">
                <h3 className="text-lg font-semibold text-white mb-4">Contract Verification</h3>
                <p className="text-slate-400 text-sm mb-4">
                  Verify your contract on Etherscan to make it publicly accessible:
                </p>
                
                <div className="space-y-3">
                  <div>
                    <label className="block text-sm text-slate-400 mb-1">Contract Address:</label>
                    <div className="flex items-center space-x-2">
                      <code className="flex-1 bg-slate-900 p-2 rounded text-green-400 text-sm font-mono">
                        {deployedAddress}
                      </code>
                      <button
                        onClick={() => copyToClipboard(deployedAddress)}
                        className="px-3 py-2 bg-blue-600 hover:bg-blue-700 text-white text-sm rounded transition-colors"
                      >
                        Copy
                      </button>
                    </div>
                  </div>
                  
                  <div>
                    <label className="block text-sm text-slate-400 mb-1">Etherscan Link:</label>
                    <a
                      href={`${process.env.NEXT_PUBLIC_EXPLORER_URL}/address/${deployedAddress}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="block bg-slate-900 p-2 rounded text-blue-400 text-sm hover:text-blue-300 transition-colors"
                    >
                      View on Sepolia Etherscan →
                    </a>
                  </div>
                </div>
              </div>

              <div className="p-4 bg-green-500/10 border border-green-500/20 rounded-lg">
                <h3 className="text-green-400 font-medium mb-2">🎉 Deployment Complete!</h3>
                <p className="text-green-300 text-sm mb-4">
                  Your SuperPaymaster contract has been successfully deployed and is ready to use.
                </p>
                
                <div className="flex space-x-3">
                  <Link
                    href="/admin"
                    className="px-4 py-2 bg-green-600 hover:bg-green-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    Go to Management
                  </Link>
                  <Link
                    href="/"
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    View Dashboard
                  </Link>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Information Cards */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div className="bg-slate-800/30 rounded-xl p-6 border border-slate-700">
            <div className="w-12 h-12 bg-blue-500/20 rounded-lg flex items-center justify-center mb-4">
              <span className="text-blue-400 text-xl">📋</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">What is SuperPaymaster?</h3>
            <p className="text-slate-400 text-sm">
              SuperPaymaster is a router contract that automatically selects the best available paymaster 
              for gas sponsorship, optimizing costs and success rates for UserOperations.
            </p>
          </div>

          <div className="bg-slate-800/30 rounded-xl p-6 border border-slate-700">
            <div className="w-12 h-12 bg-purple-500/20 rounded-lg flex items-center justify-center mb-4">
              <span className="text-purple-400 text-xl">🔧</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Next Steps</h3>
            <p className="text-slate-400 text-sm">
              After deployment, register individual paymasters to your SuperPaymaster instance 
              and start routing UserOperations through the optimized system.
            </p>
          </div>
        </div>
      </main>
    </div>
  );
}