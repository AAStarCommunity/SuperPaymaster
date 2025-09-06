'use client';

import { useState, useEffect, Suspense } from 'react';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { MetaMaskButton } from '@/components/MetaMaskButton';
import { formatEther, parseEther } from 'viem';
import { toast } from 'react-hot-toast';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';

import { SUPER_PAYMASTER_ABI } from '@/lib/contracts';
import { SINGLETON_PAYMASTER_CONTRACTS } from '@/lib/compiled';
import { OperatorStats } from '@/types';

function ManagePaymasterContent() {
  const { address, isConnected } = useAccount();
  const searchParams = useSearchParams();
  const paymasterAddress = searchParams.get('address');
  const [paymasterVersion, setPaymasterVersion] = useState<'v6' | 'v7' | 'v8'>('v7');
  const [mounted, setMounted] = useState(false);
  
  const [stats, setStats] = useState<OperatorStats | null>(null);
  const [newFeeRate, setNewFeeRate] = useState<string>('100');
  const [withdrawAmount, setWithdrawAmount] = useState<string>('0.1');
  const [depositAmount, setDepositAmount] = useState<string>('0.1');
  
  useEffect(() => {
    setMounted(true);
  }, []);

  const { writeContract, data: hash, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  // Detect paymaster version based on EntryPoint address
  const { data: entryPoint } = useReadContract({
    address: paymasterAddress as `0x${string}`,
    abi: [
      {
        inputs: [],
        name: "entryPoint",
        outputs: [{ name: "", type: "address" }],
        stateMutability: "view",
        type: "function"
      }
    ],
    functionName: 'entryPoint',
    query: {
      enabled: !!paymasterAddress && mounted,
    },
  });
  
  // Determine version based on EntryPoint address and SuperPaymaster registration
  useEffect(() => {
    if (entryPoint && paymasterAddress) {
      const epLower = entryPoint.toLowerCase();
      if (epLower === '0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789') {
        setPaymasterVersion('v6');
      } else if (epLower === '0x0000000071727de22e5e9d8baf0edac6f37da032') {
        // Both v7 and v8 use the same EntryPoint, check which SuperPaymaster has this paymaster registered
        // We'll check v8 first, then v7 as fallback
        setPaymasterVersion('v8'); // Default to v8, will be corrected by registration check
      }
    }
  }, [entryPoint, paymasterAddress]);
  
  // Get the correct ABI based on version
  const paymasterABI = paymasterVersion === 'v6' 
    ? SINGLETON_PAYMASTER_CONTRACTS.v6?.abi
    : paymasterVersion === 'v7'
    ? SINGLETON_PAYMASTER_CONTRACTS.v7?.abi
    : SINGLETON_PAYMASTER_CONTRACTS.v8?.abi;
  
  // Read paymaster balance from EntryPoint
  const { data: paymasterBalance } = useReadContract({
    address: entryPoint as `0x${string}`,
    abi: [
      {
        inputs: [{ name: "account", type: "address" }],
        name: "balanceOf",
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
        type: "function"
      }
    ],
    functionName: 'balanceOf',
    args: [paymasterAddress as `0x${string}`],
    query: {
      enabled: !!paymasterAddress && !!entryPoint && mounted,
      refetchInterval: 10000, // Refetch every 10 seconds
    },
  });

  // SuperPaymaster contract addresses - hardcoded from deployment
  const SUPER_PAYMASTER_ADDRESSES = {
    v6: "0x7417bAd0C641Ab74DB2B3Fe8971214E1F3812217",
    v7: "0x4e67678AF714f6B5A8882C2e5a78B15B08a79575", 
    v8: "0x2868a75dbaD3D10546382E7DAeDba2Ee05ACe320"
  };

  // Get contract address for selected version with fallback
  const getContractAddress = (version: 'v6' | 'v7' | 'v8') => {
    const envAddress = version === 'v6' 
      ? process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V6
      : version === 'v7'
      ? process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7
      : process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V8;
    return envAddress || SUPER_PAYMASTER_ADDRESSES[version];
  };

  const superPaymasterAddress = getContractAddress(paymasterVersion);
  
  // Check registration in v8 SuperPaymaster
  const { data: paymasterInfoV8 } = useReadContract({
    address: getContractAddress('v8') as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getPaymasterInfo',
    args: [paymasterAddress as `0x${string}`],
    query: {
      enabled: !!paymasterAddress && mounted && entryPoint?.toLowerCase() === '0x0000000071727de22e5e9d8baf0edac6f37da032',
    },
  });

  // Check registration in v7 SuperPaymaster
  const { data: paymasterInfoV7 } = useReadContract({
    address: getContractAddress('v7') as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getPaymasterInfo',
    args: [paymasterAddress as `0x${string}`],
    query: {
      enabled: !!paymasterAddress && mounted && entryPoint?.toLowerCase() === '0x0000000071727de22e5e9d8baf0edac6f37da032',
    },
  });

  // Check registration in v6 SuperPaymaster  
  const { data: paymasterInfoV6 } = useReadContract({
    address: getContractAddress('v6') as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getPaymasterInfo',
    args: [paymasterAddress as `0x${string}`],
    query: {
      enabled: !!paymasterAddress && mounted && entryPoint?.toLowerCase() === '0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789',
    },
  });

  // Determine correct version and paymaster info based on registration
  const paymasterInfo = paymasterVersion === 'v6' ? paymasterInfoV6 
    : paymasterVersion === 'v7' ? paymasterInfoV7 
    : paymasterInfoV8;

  // Smart version detection for v7/v8 based on actual registration
  useEffect(() => {
    if (entryPoint?.toLowerCase() === '0x0000000071727de22e5e9d8baf0edac6f37da032') {
      // Check v8 first
      if (paymasterInfoV8 && paymasterInfoV8.paymaster !== '0x0000000000000000000000000000000000000000') {
        setPaymasterVersion('v8');
      } else if (paymasterInfoV7 && paymasterInfoV7.paymaster !== '0x0000000000000000000000000000000000000000') {
        setPaymasterVersion('v7');
      }
      // If neither has registration, keep current version (default v8)
    }
  }, [paymasterInfoV8, paymasterInfoV7, entryPoint]);

  const handleUpdateFeeRate = async () => {
    if (!paymasterAddress || !newFeeRate) return;

    const currentSuperPaymasterAddress = getContractAddress(paymasterVersion);
    if (!currentSuperPaymasterAddress) {
      toast.error('SuperPaymaster contract not found');
      return;
    }

    try {
      writeContract({
        address: currentSuperPaymasterAddress as `0x${string}`,
        abi: SUPER_PAYMASTER_ABI,
        functionName: 'updateFeeRate',
        args: [BigInt(newFeeRate)],
      });
    } catch (error) {
      toast.error('Failed to update fee rate');
    }
  };

  const handleDeposit = async () => {
    if (!paymasterAddress || !depositAmount || !entryPoint) return;

    try {
      // Deposit to EntryPoint for this paymaster
      writeContract({
        address: entryPoint as `0x${string}`,
        abi: [
          {
            inputs: [{ name: "account", type: "address" }],
            name: "depositTo",
            outputs: [],
            stateMutability: "payable",
            type: "function"
          }
        ],
        functionName: 'depositTo',
        args: [paymasterAddress as `0x${string}`],
        value: parseEther(depositAmount),
      });
    } catch (error) {
      toast.error('Failed to deposit');
    }
  };

  const handleWithdraw = async () => {
    if (!paymasterAddress || !withdrawAmount || !address || !entryPoint || !paymasterABI) {
      if (!paymasterABI) {
        toast.error(`Paymaster ABI not available for version ${paymasterVersion}`);
      }
      return;
    }

    try {
      // Withdraw from EntryPoint using paymaster's withdraw function
      writeContract({
        address: paymasterAddress as `0x${string}`,
        abi: paymasterABI,
        functionName: 'withdrawTo',
        args: [address as `0x${string}`, parseEther(withdrawAmount)],
      });
    } catch (error) {
      toast.error('Failed to withdraw');
    }
  };

  // Show success messages
  useEffect(() => {
    if (isSuccess) {
      toast.success('Transaction successful!');
    }
  }, [isSuccess]);

  if (!paymasterAddress) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 flex items-center justify-center">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-white mb-4">Invalid Paymaster Address</h1>
          <Link
            href="/"
            className="px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors"
          >
            Back to Dashboard
          </Link>
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
              <Link href="/" className="flex items-center space-x-4 hover:opacity-80 transition-opacity">
                <div className="w-10 h-10 bg-gradient-to-r from-purple-500 to-pink-600 rounded-lg flex items-center justify-center">
                  <span className="text-white font-bold text-xl">⚙️</span>
                </div>
                <div>
                  <h1 className="text-2xl font-bold text-white">Manage Paymaster</h1>
                  <p className="text-slate-400 text-sm">Control your gas sponsorship service (Version: {paymasterVersion.toUpperCase()})</p>
                </div>
              </Link>
            </div>
            <MetaMaskButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Breadcrumb */}
        <nav className="mb-8">
          <div className="flex items-center space-x-2 text-sm">
            <Link href="/" className="text-purple-400 hover:text-purple-300">Dashboard</Link>
            <span className="text-slate-500">›</span>
            <span className="text-slate-300">Manage Paymaster</span>
          </div>
        </nav>

        {/* Paymaster Overview */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 mb-8">
          <div className="p-6">
            <h2 className="text-xl font-bold text-white mb-4">📋 Paymaster Overview</h2>
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <div className="space-y-4">
                <div className="flex justify-between">
                  <span className="text-slate-400">Contract Address:</span>
                  <span className="text-white font-mono text-sm">{paymasterAddress}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-slate-400">Current Balance:</span>
                  <span className="text-green-400 font-bold">
                    {paymasterBalance ? `${formatEther(paymasterBalance)} ETH` : 'Loading...'}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span className="text-slate-400">Registration Status:</span>
                  <span className={`font-medium ${
                    paymasterInfo && paymasterInfo.paymaster !== '0x0000000000000000000000000000000000000000' 
                      ? 'text-green-400' 
                      : 'text-yellow-400'
                  }`}>
                    {paymasterInfo && paymasterInfo.paymaster !== '0x0000000000000000000000000000000000000000' 
                      ? 'Registered' 
                      : 'Not Registered'
                    }
                  </span>
                </div>
                {paymasterInfo && paymasterInfo.paymaster !== '0x0000000000000000000000000000000000000000' && (
                  <>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Fee Rate:</span>
                      <span className="text-white">{(Number(paymasterInfo.feeRate) / 100).toFixed(2)}%</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Success Rate:</span>
                      <span className="text-white">
                        {paymasterInfo.totalAttempts > BigInt(0) 
                          ? `${((Number(paymasterInfo.successCount) / Number(paymasterInfo.totalAttempts)) * 100).toFixed(1)}%`
                          : '0%'
                        }
                      </span>
                    </div>
                  </>
                )}
              </div>
              <div className="space-y-4">
                {paymasterInfo && paymasterInfo.paymaster !== '0x0000000000000000000000000000000000000000' && (
                  <>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Name:</span>
                      <span className="text-white">{paymasterInfo.name}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Total Operations:</span>
                      <span className="text-white">{paymasterInfo.totalAttempts.toString()}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Successful Operations:</span>
                      <span className="text-green-400">{paymasterInfo.successCount.toString()}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Status:</span>
                      <span className={`font-medium ${paymasterInfo.isActive ? 'text-green-400' : 'text-red-400'}`}>
                        {paymasterInfo.isActive ? 'Active' : 'Inactive'}
                      </span>
                    </div>
                  </>
                )}
              </div>
            </div>
          </div>
        </div>

        {/* Management Actions */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
          {/* Fund Management */}
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700">
            <div className="p-6">
              <h3 className="text-lg font-bold text-white mb-4">💰 Fund Management</h3>
              
              <div className="space-y-4">
                {/* Deposit */}
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">
                    Deposit ETH
                  </label>
                  <div className="flex space-x-2">
                    <div className="relative flex-1">
                      <input
                        type="number"
                        step="0.01"
                        min="0"
                        value={depositAmount}
                        onChange={(e) => setDepositAmount(e.target.value)}
                        className="w-full px-3 py-2 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                        placeholder="0.1"
                      />
                      <div className="absolute right-3 top-2 text-slate-400 text-sm">ETH</div>
                    </div>
                    <button
                      onClick={handleDeposit}
                      disabled={!isConnected || isPending || isConfirming}
                      className="px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors flex items-center space-x-2"
                    >
                      {(isPending || isConfirming) && <div className="spinner"></div>}
                      <span>Deposit</span>
                    </button>
                  </div>
                </div>

                {/* Withdraw */}
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">
                    Withdraw ETH
                  </label>
                  <div className="flex space-x-2">
                    <div className="relative flex-1">
                      <input
                        type="number"
                        step="0.01"
                        min="0"
                        value={withdrawAmount}
                        onChange={(e) => setWithdrawAmount(e.target.value)}
                        className="w-full px-3 py-2 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                        placeholder="0.1"
                      />
                      <div className="absolute right-3 top-2 text-slate-400 text-sm">ETH</div>
                    </div>
                    <button
                      onClick={handleWithdraw}
                      disabled={!isConnected || isPending || isConfirming}
                      className="px-4 py-2 bg-yellow-600 hover:bg-yellow-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors flex items-center space-x-2"
                    >
                      {(isPending || isConfirming) && <div className="spinner"></div>}
                      <span>Withdraw</span>
                    </button>
                  </div>
                </div>

                {/* Balance Warning */}
                {paymasterBalance && paymasterBalance < parseEther('0.01') && (
                  <div className="bg-yellow-500/10 border border-yellow-500/20 rounded-lg p-3">
                    <p className="text-yellow-400 text-sm">
                      ⚠️ Low balance! Your paymaster may not be selected for routing.
                    </p>
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* Registration Management */}
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700">
            <div className="p-6">
              <h3 className="text-lg font-bold text-white mb-4">📝 Registration Settings</h3>
              
              <div className="space-y-4">
                {paymasterInfo && paymasterInfo.paymaster !== '0x0000000000000000000000000000000000000000' ? (
                  <>
                    {/* Update Fee Rate */}
                    <div>
                      <label className="block text-sm font-medium text-slate-300 mb-2">
                        Update Fee Rate
                      </label>
                      <div className="flex space-x-2">
                        <div className="relative flex-1">
                          <input
                            type="number"
                            min="0"
                            max="10000"
                            value={newFeeRate}
                            onChange={(e) => setNewFeeRate(e.target.value)}
                            className="w-full px-3 py-2 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                            placeholder="100"
                          />
                          <div className="absolute right-3 top-2 text-slate-400 text-sm">
                            {(parseInt(newFeeRate) / 100).toFixed(2)}%
                          </div>
                        </div>
                        <button
                          onClick={handleUpdateFeeRate}
                          disabled={!isConnected || isPending || isConfirming}
                          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors flex items-center space-x-2"
                        >
                          {(isPending || isConfirming) && <div className="spinner"></div>}
                          <span>Update</span>
                        </button>
                      </div>
                      <p className="mt-1 text-xs text-slate-400">
                        Lower fees increase chances of selection
                      </p>
                    </div>

                    {/* Current Registration Info */}
                    <div className="bg-slate-700/50 rounded-lg p-3">
                      <p className="text-green-400 text-sm mb-2">✅ Registered with SuperPaymaster</p>
                      <div className="space-y-1 text-xs">
                        <div className="flex justify-between">
                          <span className="text-slate-400">Current Fee Rate:</span>
                          <span className="text-white">{(Number(paymasterInfo.feeRate) / 100).toFixed(2)}%</span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400">Operations Served:</span>
                          <span className="text-white">{paymasterInfo.totalAttempts.toString()}</span>
                        </div>
                      </div>
                    </div>
                  </>
                ) : (
                  <div className="text-center py-8">
                    <div className="w-12 h-12 bg-yellow-500/20 rounded-lg flex items-center justify-center mx-auto mb-4">
                      <span className="text-yellow-400 text-xl">📝</span>
                    </div>
                    <p className="text-slate-400 mb-4">Not registered with SuperPaymaster</p>
                    <Link
                      href="/register"
                      className="inline-block px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors"
                    >
                      Register Now
                    </Link>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>

        {/* Performance Analytics */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 mb-8">
          <div className="p-6">
            <h3 className="text-lg font-bold text-white mb-4">📊 Performance Analytics</h3>
            
            {paymasterInfo && paymasterInfo.paymaster !== '0x0000000000000000000000000000000000000000' ? (
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div className="text-center">
                  <div className="text-2xl font-bold text-blue-400 mb-1">
                    {paymasterInfo.totalAttempts.toString()}
                  </div>
                  <p className="text-slate-400 text-sm">Total Operations</p>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-green-400 mb-1">
                    {paymasterInfo.totalAttempts > BigInt(0) 
                      ? `${((Number(paymasterInfo.successCount) / Number(paymasterInfo.totalAttempts)) * 100).toFixed(1)}%`
                      : '0%'
                    }
                  </div>
                  <p className="text-slate-400 text-sm">Success Rate</p>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-purple-400 mb-1">
                    {(Number(paymasterInfo.feeRate) / 100).toFixed(2)}%
                  </div>
                  <p className="text-slate-400 text-sm">Current Fee Rate</p>
                </div>
              </div>
            ) : (
              <div className="text-center py-8 text-slate-400">
                <p>Register your paymaster to view performance analytics</p>
              </div>
            )}
          </div>
        </div>

        {/* Quick Actions */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <Link
            href="/examples"
            className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6 hover:border-blue-500 transition-colors group"
          >
            <div className="w-12 h-12 bg-blue-500/20 rounded-lg flex items-center justify-center mb-4 group-hover:bg-blue-500/30 transition-colors">
              <span className="text-blue-400 text-xl">📚</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">View Examples</h3>
            <p className="text-slate-400 text-sm">Integration examples and best practices</p>
          </Link>

          <Link
            href="/deploy"
            className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6 hover:border-purple-500 transition-colors group"
          >
            <div className="w-12 h-12 bg-purple-500/20 rounded-lg flex items-center justify-center mb-4 group-hover:bg-purple-500/30 transition-colors">
              <span className="text-purple-400 text-xl">🚀</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Deploy Another</h3>
            <p className="text-slate-400 text-sm">Deploy additional paymaster contracts</p>
          </Link>

          <Link
            href="/"
            className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6 hover:border-green-500 transition-colors group"
          >
            <div className="w-12 h-12 bg-green-500/20 rounded-lg flex items-center justify-center mb-4 group-hover:bg-green-500/30 transition-colors">
              <span className="text-green-400 text-xl">🏠</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Dashboard</h3>
            <p className="text-slate-400 text-sm">Return to main dashboard</p>
          </Link>
        </div>

        {/* Transaction Status */}
        {hash && (
          <div className="mt-8 bg-blue-500/10 border border-blue-500/20 rounded-xl p-6">
            <h3 className="text-lg font-semibold text-blue-400 mb-2">Transaction Status</h3>
            <p className="text-slate-300 mb-2">Transaction Hash:</p>
            <p className="font-mono text-sm text-blue-400 break-all mb-3">{hash}</p>
            <p className="text-slate-400 text-sm">
              Status: {isConfirming ? 'Confirming...' : isSuccess ? 'Confirmed' : 'Pending'}
            </p>
            <a
              href={`${process.env.NEXT_PUBLIC_EXPLORER_URL}/tx/${hash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center mt-3 text-blue-400 hover:text-blue-300 text-sm"
            >
              View on Explorer →
            </a>
          </div>
        )}
      </main>
    </div>
  );
}

export default function ManagePaymaster() {
  return (
    <Suspense fallback={
      <div className="min-h-screen bg-slate-900 flex items-center justify-center">
        <div className="text-center">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-purple-500 mx-auto mb-4"></div>
          <p className="text-slate-400">Loading paymaster management...</p>
        </div>
      </div>
    }>
      <ManagePaymasterContent />
    </Suspense>
  );
}