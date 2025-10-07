'use client';

import { useState, useEffect } from 'react';
import { useAccount, useReadContract } from 'wagmi';
import { MetaMaskButton } from '@/components/MetaMaskButton';
import { toast } from 'react-hot-toast';
import Link from 'next/link';
import { SUPER_PAYMASTER_ABI } from '@/lib/contracts';

interface SuperPaymasterStats {
  totalPaymasters: number;
  activePaymasters: number;
  totalSuccessfulRoutes: number;
  totalRoutes: number;
}

interface PaymasterInfo {
  paymaster: string;
  feeRate: bigint;
  isActive: boolean;
  successCount: bigint;
  totalAttempts: bigint;
  name: string;
}

function PaymasterCard({ address, contractAddress, index }: {
  address: string;
  contractAddress: string;
  index: number;
}) {
  const { data: paymasterInfo } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getPaymasterInfo',
    args: [address as `0x${string}`],
  });

  if (!paymasterInfo) return null;

  const info = paymasterInfo as PaymasterInfo;
  const successRate = Number(info.totalAttempts) > 0 
    ? ((Number(info.successCount) / Number(info.totalAttempts)) * 100).toFixed(1)
    : '0';

  return (
    <div className="bg-slate-700/50 rounded-lg p-4 border border-slate-600">
      <div className="flex items-center justify-between">
        <div className="flex-1">
          <div className="flex items-center space-x-3 mb-2">
            <span className="w-8 h-8 bg-gradient-to-r from-purple-500 to-pink-600 rounded-full flex items-center justify-center text-white text-sm font-bold">
              {index + 1}
            </span>
            <div>
              <h4 className="text-white font-medium">{info.name}</h4>
              <p className="text-slate-400 text-sm font-mono">{address}</p>
            </div>
          </div>
          
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
            <div>
              <p className="text-xs text-slate-500 mb-1">Fee Rate</p>
              <p className="text-sm font-medium text-purple-400">
                {(Number(info.feeRate) / 100).toFixed(2)}%
              </p>
            </div>
            <div>
              <p className="text-xs text-slate-500 mb-1">Success Rate</p>
              <p className="text-sm font-medium text-green-400">{successRate}%</p>
            </div>
            <div>
              <p className="text-xs text-slate-500 mb-1">Total Routes</p>
              <p className="text-sm font-medium text-blue-400">{Number(info.totalAttempts)}</p>
            </div>
            <div>
              <p className="text-xs text-slate-500 mb-1">Status</p>
              <span className={`inline-flex items-center px-2 py-1 rounded-full text-xs font-medium ${
                info.isActive 
                  ? 'bg-green-500/20 text-green-400' 
                  : 'bg-red-500/20 text-red-400'
              }`}>
                {info.isActive ? '🟢 Active' : '🔴 Inactive'}
              </span>
            </div>
          </div>
        </div>
        
        <div className="ml-4">
          <Link
            href={`/manage?address=${address}`}
            className="px-3 py-2 bg-purple-600 hover:bg-purple-700 text-white text-sm font-medium rounded-lg transition-colors"
          >
            Manage
          </Link>
        </div>
      </div>
    </div>
  );
}

export default function AdminEntry() {
  const { address, isConnected } = useAccount();
  const [mounted, setMounted] = useState(false);
  const [selectedVersion, setSelectedVersion] = useState<'v6' | 'v7' | 'v8'>('v7');

  useEffect(() => {
    setMounted(true);
  }, []);

  // SuperPaymaster contract addresses - hardcoded from deployment
  const SUPER_PAYMASTER_ADDRESSES = {
    v6: "0x7417bAd0C641Ab74DB2B3Fe8971214E1F3812217",
    v7: "0x4e67678AF714f6B5A8882C2e5a78B15B08a79575", 
    v8: "0x2868a75dbaD3D10546382E7DAeDba2Ee05ACe320"
  };

  // Get contract address for selected version
  const getContractAddress = (version: 'v6' | 'v7' | 'v8') => {
    const envAddress = (() => {
      switch (version) {
        case 'v6': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V6;
        case 'v7': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7;
        case 'v8': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V8;
      }
    })();
    return envAddress || SUPER_PAYMASTER_ADDRESSES[version];
  };

  const contractAddress = getContractAddress(selectedVersion);

  // Query router stats
  const { data: routerStats } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getRouterStats',
  });

  // Query active paymasters
  const { data: activePaymasters } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getActivePaymasters',
  });

  // Query paymaster count
  const { data: paymasterCount } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getPaymasterCount',
  });

  // Check if SuperPaymaster is deployed
  const isSuperPaymasterDeployed = () => {
    return !!(SUPER_PAYMASTER_ADDRESSES.v6 || SUPER_PAYMASTER_ADDRESSES.v7 || SUPER_PAYMASTER_ADDRESSES.v8);
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

  const stats = routerStats ? {
    totalPaymasters: Number(routerStats[0]),
    activePaymasters: Number(routerStats[1]),
    totalSuccessfulRoutes: Number(routerStats[2]),
    totalRoutes: Number(routerStats[3])
  } : null;

  const successRate = stats && stats.totalRoutes > 0 
    ? ((stats.totalSuccessfulRoutes / stats.totalRoutes) * 100).toFixed(1)
    : '0';

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700 bg-slate-900/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            <div className="flex items-center space-x-4">
              <Link href="/" className="flex items-center space-x-4 hover:opacity-80 transition-opacity">
                <div className="w-10 h-10 bg-gradient-to-r from-purple-500 to-pink-600 rounded-lg flex items-center justify-center">
                  <span className="text-white font-bold text-xl">📊</span>
                </div>
                <div>
                  <h1 className="text-2xl font-bold text-white">SuperPaymaster Dashboard</h1>
                  <p className="text-slate-400 text-sm">Monitor paymaster router network</p>
                </div>
              </Link>
            </div>
            <MetaMaskButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Version Selector */}
        <div className="mb-8">
          <h2 className="text-xl font-semibold text-white mb-4">Select SuperPaymaster Version</h2>
          <div className="flex space-x-4">
            {(['v6', 'v7', 'v8'] as const).map((version) => (
              <button
                key={version}
                onClick={() => setSelectedVersion(version)}
                className={`px-6 py-3 rounded-lg font-medium transition-all ${
                  selectedVersion === version
                    ? 'bg-purple-600 text-white shadow-lg shadow-purple-500/25'
                    : 'bg-slate-700 text-slate-300 hover:bg-slate-600'
                }`}
              >
                EntryPoint {version.toUpperCase()}
              </button>
            ))}
          </div>
          <div className="mt-3 text-sm text-slate-400">
            Contract: <span className="font-mono text-purple-400">{contractAddress}</span>
          </div>
        </div>

        {/* Statistics Cards */}
        <div className="grid grid-cols-1 md:grid-cols-4 gap-6 mb-8">
          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-slate-400 text-sm">Total Paymasters</p>
                <p className="text-2xl font-bold text-white">{stats?.totalPaymasters || 0}</p>
              </div>
              <div className="w-10 h-10 bg-blue-500/20 rounded-lg flex items-center justify-center">
                <span className="text-blue-400 text-xl">🏪</span>
              </div>
            </div>
          </div>

          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-slate-400 text-sm">Active Paymasters</p>
                <p className="text-2xl font-bold text-green-400">{stats?.activePaymasters || 0}</p>
              </div>
              <div className="w-10 h-10 bg-green-500/20 rounded-lg flex items-center justify-center">
                <span className="text-green-400 text-xl">✅</span>
              </div>
            </div>
          </div>

          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-slate-400 text-sm">Total Routes</p>
                <p className="text-2xl font-bold text-purple-400">{stats?.totalRoutes || 0}</p>
              </div>
              <div className="w-10 h-10 bg-purple-500/20 rounded-lg flex items-center justify-center">
                <span className="text-purple-400 text-xl">🔄</span>
              </div>
            </div>
          </div>

          <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-slate-400 text-sm">Success Rate</p>
                <p className="text-2xl font-bold text-yellow-400">{successRate}%</p>
              </div>
              <div className="w-10 h-10 bg-yellow-500/20 rounded-lg flex items-center justify-center">
                <span className="text-yellow-400 text-xl">📊</span>
              </div>
            </div>
          </div>
        </div>

        {/* Active Paymasters List */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700">
          <div className="p-6 border-b border-slate-700">
            <div className="flex justify-between items-center">
              <h3 className="text-xl font-semibold text-white">Registered Paymasters</h3>
              <div className="flex space-x-3">
                <Link
                  href="/register"
                  className="px-4 py-2 bg-green-600 hover:bg-green-700 text-white text-sm font-medium rounded-lg transition-colors"
                >
                  Register Paymaster
                </Link>
                <Link
                  href="/deploy"
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium rounded-lg transition-colors"
                >
                  Deploy New
                </Link>
              </div>
            </div>
          </div>

          <div className="p-6">
            {activePaymasters && Array.isArray(activePaymasters) && activePaymasters.length > 0 ? (
              <div className="space-y-4">
                {activePaymasters.map((paymasterAddress: string, index: number) => (
                  <PaymasterCard
                    key={paymasterAddress}
                    address={paymasterAddress}
                    contractAddress={contractAddress}
                    index={index}
                  />
                ))}
              </div>
            ) : (
              <div className="text-center py-12">
                <div className="w-16 h-16 bg-slate-700/50 rounded-full flex items-center justify-center mx-auto mb-4">
                  <span className="text-slate-400 text-2xl">🏪</span>
                </div>
                <h3 className="text-lg font-medium text-slate-300 mb-2">No Paymasters Registered</h3>
                <p className="text-slate-400 mb-6">
                  This SuperPaymaster {selectedVersion.toUpperCase()} instance doesn't have any registered paymasters yet.
                </p>
                <div className="flex justify-center space-x-4">
                  <Link
                    href="/register"
                    className="px-6 py-3 bg-green-600 hover:bg-green-700 text-white font-medium rounded-lg transition-colors"
                  >
                    Register First Paymaster
                  </Link>
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Quick Actions */}
        <div className="mt-8 grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="bg-slate-800/30 rounded-xl p-6 border border-slate-700">
            <div className="w-12 h-12 bg-blue-500/20 rounded-lg flex items-center justify-center mb-4">
              <span className="text-blue-400 text-xl">💰</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Fund Management</h3>
            <p className="text-slate-400 text-sm">Deposit and withdraw ETH for gas sponsorship</p>
          </div>

          <div className="bg-slate-800/30 rounded-xl p-6 border border-slate-700">
            <div className="w-12 h-12 bg-green-500/20 rounded-lg flex items-center justify-center mb-4">
              <span className="text-green-400 text-xl">⚙️</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Fee Management</h3>
            <p className="text-slate-400 text-sm">Update fee rates and monitor performance</p>
          </div>

          <div className="bg-slate-800/30 rounded-xl p-6 border border-slate-700">
            <div className="w-12 h-12 bg-purple-500/20 rounded-lg flex items-center justify-center mb-4">
              <span className="text-purple-400 text-xl">📊</span>
            </div>
            <h3 className="text-lg font-semibold text-white mb-2">Analytics</h3>
            <p className="text-slate-400 text-sm">Track usage statistics and revenue</p>
          </div>
        </div>
      </main>
    </div>
  );
}