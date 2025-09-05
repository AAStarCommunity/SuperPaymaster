'use client';

import { useState, useEffect } from 'react';
import { useAccount, useChainId, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { formatEther, parseEther } from 'viem';
import { toast } from 'react-hot-toast';

import { CONTRACTS, SUPER_PAYMASTER_ABI, PaymasterVersion } from '@/lib/contracts';
import { PaymasterInfo, RouterStats } from '@/types';

export default function Dashboard() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const [selectedVersion, setSelectedVersion] = useState<PaymasterVersion>('v7');
  const [paymasterData, setPaymasterData] = useState<PaymasterInfo[]>([]);
  const [routerStats, setRouterStats] = useState<RouterStats | null>(null);
  const [loading, setLoading] = useState(true);

  // Get contract address for selected version
  const getContractAddress = (version: PaymasterVersion) => {
    switch (version) {
      case 'v6': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V6 || CONTRACTS.SUPER_PAYMASTER_V6;
      case 'v7': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7 || CONTRACTS.SUPER_PAYMASTER_V7;
      case 'v8': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V8 || CONTRACTS.SUPER_PAYMASTER_V8;
    }
  };

  const contractAddress = getContractAddress(selectedVersion);

  // Read contract data
  const { data: bestPaymaster } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getBestPaymaster',
  });

  const { data: activePaymasters } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getActivePaymasters',
  });

  const { data: stats } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getRouterStats',
  });

  const { data: version } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getVersion',
  });

  // Fetch paymaster details
  useEffect(() => {
    const fetchPaymasterData = async () => {
      if (!activePaymasters || activePaymasters.length === 0) {
        setPaymasterData([]);
        setLoading(false);
        return;
      }

      try {
        setLoading(true);
        // Note: In a real app, you'd batch these calls or use a multicall
        // For demo purposes, we'll show the structure
        setPaymasterData([]);
      } catch (error) {
        console.error('Error fetching paymaster data:', error);
        toast.error('Failed to fetch paymaster data');
      } finally {
        setLoading(false);
      }
    };

    fetchPaymasterData();
  }, [activePaymasters]);

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-blue-900 to-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700 bg-slate-900/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            <div className="flex items-center space-x-4">
              <div className="w-10 h-10 bg-gradient-to-r from-blue-500 to-purple-600 rounded-lg flex items-center justify-center">
                <span className="text-white font-bold text-xl">S</span>
              </div>
              <div>
                <h1 className="text-2xl font-bold text-white">SuperPaymaster</h1>
                <p className="text-slate-400 text-sm">Decentralized Gas Payment Router</p>
              </div>
            </div>
            <ConnectButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Version Selector */}
        <div className="mb-8">
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700">
            <h2 className="text-xl font-semibold text-white mb-4">Select EntryPoint Version</h2>
            <div className="flex space-x-4">
              {(['v6', 'v7', 'v8'] as PaymasterVersion[]).map((v) => (
                <button
                  key={v}
                  onClick={() => setSelectedVersion(v)}
                  className={`px-4 py-2 rounded-lg font-medium transition-all ${
                    selectedVersion === v
                      ? 'bg-blue-600 text-white shadow-lg shadow-blue-500/25'
                      : 'bg-slate-700 text-slate-300 hover:bg-slate-600'
                  }`}
                >
                  EntryPoint {v.toUpperCase()}
                </button>
              ))}
            </div>
            {version && (
              <p className="mt-4 text-slate-400 text-sm">
                Contract Version: <span className="text-blue-400">{version}</span>
              </p>
            )}
          </div>
        </div>

        {/* Stats Overview */}
        {stats && (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
            <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-slate-400 text-sm">Total Paymasters</p>
                  <p className="text-2xl font-bold text-white">{stats[0]?.toString()}</p>
                </div>
                <div className="w-12 h-12 bg-blue-500/20 rounded-lg flex items-center justify-center">
                  <span className="text-blue-400 text-xl">📊</span>
                </div>
              </div>
            </div>
            
            <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-slate-400 text-sm">Active Paymasters</p>
                  <p className="text-2xl font-bold text-green-400">{stats[1]?.toString()}</p>
                </div>
                <div className="w-12 h-12 bg-green-500/20 rounded-lg flex items-center justify-center">
                  <span className="text-green-400 text-xl">✅</span>
                </div>
              </div>
            </div>

            <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-slate-400 text-sm">Total Routes</p>
                  <p className="text-2xl font-bold text-white">{stats[3]?.toString()}</p>
                </div>
                <div className="w-12 h-12 bg-purple-500/20 rounded-lg flex items-center justify-center">
                  <span className="text-purple-400 text-xl">🔄</span>
                </div>
              </div>
            </div>

            <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-slate-400 text-sm">Success Rate</p>
                  <p className="text-2xl font-bold text-green-400">
                    {stats[3] && stats[3] > 0n ? 
                      `${((Number(stats[2]) / Number(stats[3])) * 100).toFixed(1)}%` : 
                      '0%'
                    }
                  </p>
                </div>
                <div className="w-12 h-12 bg-green-500/20 rounded-lg flex items-center justify-center">
                  <span className="text-green-400 text-xl">📈</span>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Best Paymaster */}
        {bestPaymaster && (
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700 mb-8">
            <h2 className="text-xl font-semibold text-white mb-4">🏆 Current Best Paymaster</h2>
            <div className="bg-slate-700/50 rounded-lg p-4">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-slate-400 text-sm">Address</p>
                  <p className="text-white font-mono text-sm">{bestPaymaster[0]}</p>
                </div>
                <div className="text-right">
                  <p className="text-slate-400 text-sm">Fee Rate</p>
                  <p className="text-green-400 font-bold">
                    {((Number(bestPaymaster[1]) / 100)).toFixed(2)}%
                  </p>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Quick Actions */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 mb-8">
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700 hover:border-blue-500 transition-colors group">
            <div className="w-12 h-12 bg-blue-500/20 rounded-lg flex items-center justify-center mb-4 group-hover:bg-blue-500/30 transition-colors">
              <span className="text-blue-400 text-xl">📝</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Register Paymaster</h3>
            <p className="text-slate-400 text-sm mb-4">Add your paymaster to the marketplace</p>
            <button className="w-full bg-blue-600 hover:bg-blue-700 text-white font-medium py-2 px-4 rounded-lg transition-colors">
              Register Now
            </button>
          </div>

          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700 hover:border-purple-500 transition-colors group">
            <div className="w-12 h-12 bg-purple-500/20 rounded-lg flex items-center justify-center mb-4 group-hover:bg-purple-500/30 transition-colors">
              <span className="text-purple-400 text-xl">🚀</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Deploy Paymaster</h3>
            <p className="text-slate-400 text-sm mb-4">Deploy your own paymaster contract</p>
            <button className="w-full bg-purple-600 hover:bg-purple-700 text-white font-medium py-2 px-4 rounded-lg transition-colors">
              Deploy Contract
            </button>
          </div>

          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700 hover:border-green-500 transition-colors group">
            <div className="w-12 h-12 bg-green-500/20 rounded-lg flex items-center justify-center mb-4 group-hover:bg-green-500/30 transition-colors">
              <span className="text-green-400 text-xl">📚</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">API Examples</h3>
            <p className="text-slate-400 text-sm mb-4">Integration guides and code samples</p>
            <button className="w-full bg-green-600 hover:bg-green-700 text-white font-medium py-2 px-4 rounded-lg transition-colors">
              View Examples
            </button>
          </div>
        </div>

        {/* Connection Required Notice */}
        {!isConnected && (
          <div className="bg-yellow-500/10 border border-yellow-500/20 rounded-xl p-6 text-center">
            <div className="w-16 h-16 bg-yellow-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
              <span className="text-yellow-400 text-2xl">🔐</span>
            </div>
            <h3 className="text-xl font-semibold text-white mb-2">Connect Your Wallet</h3>
            <p className="text-slate-400 mb-4">
              Connect your wallet to register paymasters, deploy contracts, and manage your services.
            </p>
            <ConnectButton />
          </div>
        )}

        {/* Contract Info */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl p-6 border border-slate-700">
          <h2 className="text-xl font-semibold text-white mb-4">Contract Information</h2>
          <div className="space-y-3">
            <div className="flex justify-between items-center py-2 border-b border-slate-600">
              <span className="text-slate-400">SuperPaymaster Address:</span>
              <span className="text-white font-mono text-sm">{contractAddress || 'Not deployed'}</span>
            </div>
            <div className="flex justify-between items-center py-2 border-b border-slate-600">
              <span className="text-slate-400">EntryPoint Address:</span>
              <span className="text-white font-mono text-sm">
                {selectedVersion === 'v6' ? process.env.NEXT_PUBLIC_ENTRY_POINT_V6 : 
                 selectedVersion === 'v7' ? process.env.NEXT_PUBLIC_ENTRY_POINT_V7 : 
                 process.env.NEXT_PUBLIC_ENTRY_POINT_V8}
              </span>
            </div>
            <div className="flex justify-between items-center py-2">
              <span className="text-slate-400">Chain ID:</span>
              <span className="text-white">{chainId} (Sepolia Testnet)</span>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}