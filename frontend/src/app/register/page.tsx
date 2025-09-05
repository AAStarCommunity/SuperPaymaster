'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from 'wagmi';
import { MetaMaskButton } from '@/components/MetaMaskButton';
import { parseEther, isAddress } from 'viem';
import { toast } from 'react-hot-toast';
import Link from 'next/link';

import { SUPER_PAYMASTER_ABI, PaymasterVersion } from '@/lib/contracts';

interface RegisterFormData {
  paymasterAddress: string;
  feeRate: string;
  name: string;
  version: PaymasterVersion;
}

export default function RegisterPaymaster() {
  const { address, isConnected } = useAccount();
  const [formData, setFormData] = useState<RegisterFormData>({
    paymasterAddress: '',
    feeRate: '100', // 1%
    name: '',
    version: 'v7'
  });
  const [isSubmitting, setIsSubmitting] = useState(false);

  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  // Get contract address for selected version
  const getContractAddress = (version: PaymasterVersion) => {
    switch (version) {
      case 'v6': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V6;
      case 'v7': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7;
      case 'v8': return process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V8;
    }
  };

  const contractAddress = getContractAddress(formData.version);

  // Check if paymaster is already registered
  const { data: existingPaymaster } = useReadContract({
    address: contractAddress as `0x${string}`,
    abi: SUPER_PAYMASTER_ABI,
    functionName: 'getPaymasterInfo',
    args: [formData.paymasterAddress as `0x${string}`],
    query: {
      enabled: isAddress(formData.paymasterAddress),
    },
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    
    if (!isConnected) {
      toast.error('Please connect your wallet first');
      return;
    }

    if (!contractAddress) {
      toast.error('SuperPaymaster contract not deployed for this version');
      return;
    }

    if (!isAddress(formData.paymasterAddress)) {
      toast.error('Invalid paymaster address');
      return;
    }

    const feeRateBps = parseInt(formData.feeRate);
    if (isNaN(feeRateBps) || feeRateBps < 0 || feeRateBps > 10000) {
      toast.error('Fee rate must be between 0 and 10000 basis points (0-100%)');
      return;
    }

    if (!formData.name.trim()) {
      toast.error('Please provide a name for your paymaster');
      return;
    }

    setIsSubmitting(true);

    try {
      writeContract({
        address: contractAddress as `0x${string}`,
        abi: SUPER_PAYMASTER_ABI,
        functionName: 'registerPaymaster',
        args: [
          formData.paymasterAddress as `0x${string}`,
          BigInt(feeRateBps),
          formData.name
        ],
      });
    } catch (err) {
      console.error('Registration error:', err);
      toast.error('Failed to register paymaster');
      setIsSubmitting(false);
    }
  };

  // Handle successful transaction
  if (isSuccess) {
    toast.success('Paymaster registered successfully!');
    // Reset form
    setFormData({
      paymasterAddress: '',
      feeRate: '100',
      name: '',
      version: 'v7'
    });
    setIsSubmitting(false);
  }

  // Handle transaction error
  if (error) {
    toast.error(`Registration failed: ${error.message}`);
    setIsSubmitting(false);
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-blue-900 to-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700 bg-slate-900/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            <div className="flex items-center space-x-4">
              <Link href="/" className="flex items-center space-x-4 hover:opacity-80 transition-opacity">
                <div className="w-10 h-10 bg-gradient-to-r from-blue-500 to-purple-600 rounded-lg flex items-center justify-center">
                  <span className="text-white font-bold text-xl">S</span>
                </div>
                <div>
                  <h1 className="text-2xl font-bold text-white">SuperPaymaster</h1>
                  <p className="text-slate-400 text-sm">Register Paymaster</p>
                </div>
              </Link>
            </div>
            <MetaMaskButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Breadcrumb */}
        <nav className="mb-8">
          <div className="flex items-center space-x-2 text-sm">
            <Link href="/" className="text-blue-400 hover:text-blue-300">Dashboard</Link>
            <span className="text-slate-500">›</span>
            <span className="text-slate-300">Register Paymaster</span>
          </div>
        </nav>

        {/* Registration Form */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700">
          <div className="p-6 border-b border-slate-700">
            <h2 className="text-2xl font-bold text-white mb-2">Register Your Paymaster</h2>
            <p className="text-slate-400">
              Add your paymaster contract to the SuperPaymaster marketplace to start receiving user operations.
            </p>
          </div>

          <form onSubmit={handleSubmit} className="p-6 space-y-6">
            {/* Version Selection */}
            <div>
              <label className="block text-sm font-medium text-slate-300 mb-2">
                SuperPaymaster Version
              </label>
              <div className="flex space-x-4">
                {(['v6', 'v7', 'v8'] as PaymasterVersion[]).map((version) => (
                  <button
                    key={version}
                    type="button"
                    onClick={() => setFormData({ ...formData, version })}
                    className={`px-4 py-2 rounded-lg font-medium transition-all ${
                      formData.version === version
                        ? 'bg-blue-600 text-white shadow-lg shadow-blue-500/25'
                        : 'bg-slate-700 text-slate-300 hover:bg-slate-600'
                    }`}
                  >
                    EntryPoint {version.toUpperCase()}
                  </button>
                ))}
              </div>
              <p className="mt-2 text-sm text-slate-400">
                Select the EntryPoint version your paymaster is compatible with
              </p>
            </div>

            {/* Paymaster Address */}
            <div>
              <label htmlFor="paymasterAddress" className="block text-sm font-medium text-slate-300 mb-2">
                Paymaster Contract Address
              </label>
              <input
                type="text"
                id="paymasterAddress"
                value={formData.paymasterAddress}
                onChange={(e) => setFormData({ ...formData, paymasterAddress: e.target.value })}
                className="w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="0x..."
                required
              />
              {formData.paymasterAddress && !isAddress(formData.paymasterAddress) && (
                <p className="mt-1 text-sm text-red-400">Invalid Ethereum address</p>
              )}
              {existingPaymaster && existingPaymaster.paymaster !== '0x0000000000000000000000000000000000000000' && (
                <p className="mt-1 text-sm text-yellow-400">⚠️ This paymaster is already registered</p>
              )}
            </div>

            {/* Name */}
            <div>
              <label htmlFor="name" className="block text-sm font-medium text-slate-300 mb-2">
                Paymaster Name
              </label>
              <input
                type="text"
                id="name"
                value={formData.name}
                onChange={(e) => setFormData({ ...formData, name: e.target.value })}
                className="w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                placeholder="My Awesome Paymaster"
                required
              />
              <p className="mt-1 text-sm text-slate-400">
                A friendly name to identify your paymaster in the marketplace
              </p>
            </div>

            {/* Fee Rate */}
            <div>
              <label htmlFor="feeRate" className="block text-sm font-medium text-slate-300 mb-2">
                Fee Rate (Basis Points)
              </label>
              <div className="relative">
                <input
                  type="number"
                  id="feeRate"
                  value={formData.feeRate}
                  onChange={(e) => setFormData({ ...formData, feeRate: e.target.value })}
                  className="w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  placeholder="100"
                  min="0"
                  max="10000"
                  required
                />
                <div className="absolute right-3 top-3 text-slate-400 text-sm">
                  {formData.feeRate ? `${(parseInt(formData.feeRate) / 100).toFixed(2)}%` : '0%'}
                </div>
              </div>
              <p className="mt-1 text-sm text-slate-400">
                100 basis points = 1%. Lower fees increase chances of selection.
              </p>
            </div>

            {/* Requirements */}
            <div className="bg-slate-700/50 rounded-lg p-4 border border-slate-600">
              <h3 className="text-lg font-medium text-white mb-2">⚡ Requirements</h3>
              <ul className="space-y-2 text-sm text-slate-400">
                <li className="flex items-center">
                  <span className="w-2 h-2 bg-blue-400 rounded-full mr-3"></span>
                  Your paymaster must implement the correct interface for the selected version
                </li>
                <li className="flex items-center">
                  <span className="w-2 h-2 bg-blue-400 rounded-full mr-3"></span>
                  Maintain sufficient ETH balance in the EntryPoint for gas payments
                </li>
                <li className="flex items-center">
                  <span className="w-2 h-2 bg-blue-400 rounded-full mr-3"></span>
                  Ensure your paymaster can handle user operation validation
                </li>
                <li className="flex items-center">
                  <span className="w-2 h-2 bg-blue-400 rounded-full mr-3"></span>
                  Consider adding stake to improve routing priority
                </li>
              </ul>
            </div>

            {/* Submit Button */}
            <div className="flex justify-end space-x-4">
              <Link
                href="/"
                className="px-6 py-3 bg-slate-700 hover:bg-slate-600 text-white font-medium rounded-lg transition-colors"
              >
                Cancel
              </Link>
              <button
                type="submit"
                disabled={!isConnected || isSubmitting || isPending || isConfirming}
                className="px-6 py-3 bg-blue-600 hover:bg-blue-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors flex items-center space-x-2"
              >
                {(isSubmitting || isPending || isConfirming) && (
                  <div className="spinner"></div>
                )}
                <span>
                  {isPending || isConfirming ? 'Registering...' : 'Register Paymaster'}
                </span>
              </button>
            </div>
          </form>
        </div>

        {/* Help Section */}
        <div className="mt-8 bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700 p-6">
          <h3 className="text-lg font-semibold text-white mb-4">📚 Need Help?</h3>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <Link
              href="/deploy"
              className="p-4 bg-slate-700/50 rounded-lg hover:bg-slate-700/70 transition-colors border border-slate-600"
            >
              <h4 className="font-medium text-white mb-2">🚀 Deploy a Paymaster</h4>
              <p className="text-slate-400 text-sm">
                Don't have a paymaster contract? Deploy one using our templates.
              </p>
            </Link>
            <Link
              href="/examples"
              className="p-4 bg-slate-700/50 rounded-lg hover:bg-slate-700/70 transition-colors border border-slate-600"
            >
              <h4 className="font-medium text-white mb-2">📖 View Examples</h4>
              <p className="text-slate-400 text-sm">
                See integration examples and best practices for paymasters.
              </p>
            </Link>
          </div>
        </div>

        {/* Transaction Status */}
        {hash && (
          <div className="mt-6 bg-blue-500/10 border border-blue-500/20 rounded-xl p-6">
            <h3 className="text-lg font-semibold text-blue-400 mb-2">Transaction Submitted</h3>
            <p className="text-slate-300 mb-2">Transaction Hash:</p>
            <p className="font-mono text-sm text-blue-400 break-all">{hash}</p>
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