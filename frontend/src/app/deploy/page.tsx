'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { parseEther, encodeFunctionData, keccak256, toHex } from 'viem';
import { toast } from 'react-hot-toast';
import Link from 'next/link';

import { PaymasterVersion, SUPER_PAYMASTER_ABI } from '@/lib/contracts';
import { PaymasterDeployConfig } from '@/types';

// Simple Paymaster contract templates
const PAYMASTER_TEMPLATES = {
  v7: {
    name: 'Simple Paymaster V7',
    description: 'Basic paymaster that sponsors all operations (for testing)',
    bytecode: '0x6080604052...' // This would be the actual compiled bytecode
  }
};

export default function DeployPaymaster() {
  const { address, isConnected } = useAccount();
  const [config, setConfig] = useState<PaymasterDeployConfig>({
    version: 'v7',
    name: 'My Paymaster',
    initialDeposit: '0.1',
    feeRate: 100,
    autoRegister: true
  });
  const [step, setStep] = useState<'configure' | 'deploy' | 'deposit' | 'register' | 'complete'>('configure');
  const [deployedAddress, setDeployedAddress] = useState<string>('');

  const { writeContract, data: hash, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const getEntryPointAddress = (version: PaymasterVersion) => {
    switch (version) {
      case 'v6': return process.env.NEXT_PUBLIC_ENTRY_POINT_V6;
      case 'v7': return process.env.NEXT_PUBLIC_ENTRY_POINT_V7;
      case 'v8': return process.env.NEXT_PUBLIC_ENTRY_POINT_V8;
      default: return process.env.NEXT_PUBLIC_ENTRY_POINT_V7;
    }
  };

  const handleDeploy = async () => {
    if (!isConnected || !address) {
      toast.error('Please connect your wallet');
      return;
    }

    // For demo purposes, we'll simulate deployment
    // In a real app, you'd use the actual bytecode and constructor parameters
    
    toast.promise(
      new Promise((resolve) => {
        setTimeout(() => {
          // Simulate successful deployment
          const mockAddress = `0x${Math.random().toString(16).substr(2, 40)}`;
          setDeployedAddress(mockAddress);
          setStep('deposit');
          resolve(mockAddress);
        }, 3000);
      }),
      {
        loading: 'Deploying paymaster contract...',
        success: 'Paymaster deployed successfully!',
        error: 'Failed to deploy paymaster'
      }
    );
  };

  const handleDeposit = async () => {
    if (!deployedAddress) return;

    try {
      // Simulate depositing to EntryPoint
      toast.promise(
        new Promise((resolve) => {
          setTimeout(() => {
            setStep(config.autoRegister ? 'register' : 'complete');
            resolve('success');
          }, 2000);
        }),
        {
          loading: 'Depositing ETH to EntryPoint...',
          success: 'Deposit successful!',
          error: 'Failed to deposit'
        }
      );
    } catch (error) {
      toast.error('Failed to deposit ETH');
    }
  };

  const handleRegister = async () => {
    const superPaymasterAddress = process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7;
    
    if (!superPaymasterAddress || !deployedAddress) {
      toast.error('Missing contract addresses');
      return;
    }

    try {
      writeContract({
        address: superPaymasterAddress as `0x${string}`,
        abi: SUPER_PAYMASTER_ABI,
        functionName: 'registerPaymaster',
        args: [
          deployedAddress as `0x${string}`,
          BigInt(config.feeRate),
          config.name
        ],
      });
      
      setStep('complete');
    } catch (error) {
      toast.error('Failed to register paymaster');
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900">
      {/* Header */}
      <header className="border-b border-slate-700 bg-slate-900/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            <div className="flex items-center space-x-4">
              <Link href="/" className="flex items-center space-x-4 hover:opacity-80 transition-opacity">
                <div className="w-10 h-10 bg-gradient-to-r from-purple-500 to-pink-600 rounded-lg flex items-center justify-center">
                  <span className="text-white font-bold text-xl">🚀</span>
                </div>
                <div>
                  <h1 className="text-2xl font-bold text-white">Deploy Paymaster</h1>
                  <p className="text-slate-400 text-sm">Create your own gas sponsorship service</p>
                </div>
              </Link>
            </div>
            <ConnectButton />
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Progress Bar */}
        <div className="mb-8">
          <div className="flex items-center justify-between mb-4">
            {['configure', 'deploy', 'deposit', 'register', 'complete'].map((s, index) => (
              <div
                key={s}
                className={`flex items-center ${
                  index < 4 ? 'flex-1' : ''
                }`}
              >
                <div
                  className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium ${
                    step === s
                      ? 'bg-purple-600 text-white'
                      : ['configure', 'deploy', 'deposit', 'register', 'complete'].indexOf(step) > index
                      ? 'bg-green-600 text-white'
                      : 'bg-slate-700 text-slate-400'
                  }`}
                >
                  {['configure', 'deploy', 'deposit', 'register', 'complete'].indexOf(step) > index ? '✓' : index + 1}
                </div>
                {index < 4 && (
                  <div
                    className={`flex-1 h-0.5 ml-4 ${
                      ['configure', 'deploy', 'deposit', 'register', 'complete'].indexOf(step) > index
                        ? 'bg-green-600'
                        : 'bg-slate-700'
                    }`}
                  />
                )}
              </div>
            ))}
          </div>
          <div className="flex justify-between text-xs text-slate-400">
            <span>Configure</span>
            <span>Deploy</span>
            <span>Deposit</span>
            <span>Register</span>
            <span>Complete</span>
          </div>
        </div>

        {/* Step Content */}
        <div className="bg-slate-800/50 backdrop-blur-sm rounded-xl border border-slate-700">
          {step === 'configure' && (
            <div className="p-6">
              <h2 className="text-2xl font-bold text-white mb-6">Configure Your Paymaster</h2>
              
              <div className="space-y-6">
                {/* Version Selection */}
                <div>
                  <label className="block text-sm font-medium text-slate-300 mb-2">
                    EntryPoint Version
                  </label>
                  <div className="flex space-x-4">
                    {(['v6', 'v7', 'v8'] as PaymasterVersion[]).map((version) => (
                      <button
                        key={version}
                        type="button"
                        onClick={() => setConfig({ ...config, version })}
                        disabled={version !== 'v7'} // Only v7 template available for demo
                        className={`px-4 py-2 rounded-lg font-medium transition-all disabled:opacity-50 disabled:cursor-not-allowed ${
                          config.version === version
                            ? 'bg-purple-600 text-white shadow-lg shadow-purple-500/25'
                            : 'bg-slate-700 text-slate-300 hover:bg-slate-600'
                        }`}
                      >
                        EntryPoint {version.toUpperCase()}
                        {version !== 'v7' && <span className="text-xs block">Coming Soon</span>}
                      </button>
                    ))}
                  </div>
                </div>

                {/* Paymaster Name */}
                <div>
                  <label htmlFor="name" className="block text-sm font-medium text-slate-300 mb-2">
                    Paymaster Name
                  </label>
                  <input
                    type="text"
                    id="name"
                    value={config.name}
                    onChange={(e) => setConfig({ ...config, name: e.target.value })}
                    className="w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                    placeholder="My Awesome Paymaster"
                  />
                </div>

                {/* Initial Deposit */}
                <div>
                  <label htmlFor="deposit" className="block text-sm font-medium text-slate-300 mb-2">
                    Initial ETH Deposit
                  </label>
                  <div className="relative">
                    <input
                      type="number"
                      id="deposit"
                      step="0.01"
                      min="0"
                      value={config.initialDeposit}
                      onChange={(e) => setConfig({ ...config, initialDeposit: e.target.value })}
                      className="w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                      placeholder="0.1"
                    />
                    <div className="absolute right-3 top-3 text-slate-400">ETH</div>
                  </div>
                  <p className="mt-1 text-sm text-slate-400">
                    ETH to deposit for sponsoring user operations
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
                      value={config.feeRate}
                      onChange={(e) => setConfig({ ...config, feeRate: parseInt(e.target.value) })}
                      className="w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:ring-2 focus:ring-purple-500 focus:border-transparent"
                      min="0"
                      max="10000"
                    />
                    <div className="absolute right-3 top-3 text-slate-400 text-sm">
                      {(config.feeRate / 100).toFixed(2)}%
                    </div>
                  </div>
                </div>

                {/* Auto Register */}
                <div className="flex items-center">
                  <input
                    id="autoRegister"
                    type="checkbox"
                    checked={config.autoRegister}
                    onChange={(e) => setConfig({ ...config, autoRegister: e.target.checked })}
                    className="w-4 h-4 text-purple-600 bg-slate-700 border-slate-600 rounded focus:ring-purple-500"
                  />
                  <label htmlFor="autoRegister" className="ml-2 text-sm text-slate-300">
                    Automatically register with SuperPaymaster
                  </label>
                </div>

                {/* Template Info */}
                {config.version === 'v7' && (
                  <div className="bg-slate-700/50 rounded-lg p-4 border border-slate-600">
                    <h3 className="text-lg font-medium text-white mb-2">📋 Template: {PAYMASTER_TEMPLATES.v7.name}</h3>
                    <p className="text-slate-400 text-sm mb-3">{PAYMASTER_TEMPLATES.v7.description}</p>
                    <div className="space-y-2 text-sm">
                      <div className="flex justify-between">
                        <span className="text-slate-400">EntryPoint:</span>
                        <span className="text-white font-mono text-xs">{getEntryPointAddress('v7')}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-slate-400">Owner:</span>
                        <span className="text-white font-mono text-xs">{address}</span>
                      </div>
                    </div>
                  </div>
                )}

                <div className="flex justify-end space-x-4 pt-4">
                  <Link
                    href="/"
                    className="px-6 py-3 bg-slate-700 hover:bg-slate-600 text-white font-medium rounded-lg transition-colors"
                  >
                    Cancel
                  </Link>
                  <button
                    onClick={() => setStep('deploy')}
                    disabled={!isConnected || !config.name.trim()}
                    className="px-6 py-3 bg-purple-600 hover:bg-purple-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors"
                  >
                    Next: Deploy
                  </button>
                </div>
              </div>
            </div>
          )}

          {step === 'deploy' && (
            <div className="p-6 text-center">
              <div className="w-16 h-16 bg-purple-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
                <span className="text-purple-400 text-3xl">🚀</span>
              </div>
              <h2 className="text-2xl font-bold text-white mb-4">Deploy Paymaster Contract</h2>
              <p className="text-slate-400 mb-6">
                Deploy your {PAYMASTER_TEMPLATES[config.version].name} to the blockchain
              </p>
              
              <div className="bg-slate-700/50 rounded-lg p-4 mb-6 text-left">
                <h3 className="font-medium text-white mb-2">Deployment Parameters:</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-slate-400">Name:</span>
                    <span className="text-white">{config.name}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">Version:</span>
                    <span className="text-white">{config.version.toUpperCase()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">EntryPoint:</span>
                    <span className="text-white font-mono text-xs">{getEntryPointAddress(config.version)}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">Owner:</span>
                    <span className="text-white font-mono text-xs">{address}</span>
                  </div>
                </div>
              </div>

              <div className="flex justify-center space-x-4">
                <button
                  onClick={() => setStep('configure')}
                  className="px-6 py-3 bg-slate-700 hover:bg-slate-600 text-white font-medium rounded-lg transition-colors"
                >
                  Back
                </button>
                <button
                  onClick={handleDeploy}
                  disabled={!isConnected}
                  className="px-6 py-3 bg-purple-600 hover:bg-purple-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors flex items-center space-x-2"
                >
                  <span>Deploy Contract</span>
                </button>
              </div>
            </div>
          )}

          {step === 'deposit' && (
            <div className="p-6 text-center">
              <div className="w-16 h-16 bg-green-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
                <span className="text-green-400 text-3xl">💰</span>
              </div>
              <h2 className="text-2xl font-bold text-white mb-4">Fund Your Paymaster</h2>
              <p className="text-slate-400 mb-6">
                Deposit {config.initialDeposit} ETH to the EntryPoint for gas sponsorship
              </p>

              {deployedAddress && (
                <div className="bg-green-500/10 border border-green-500/20 rounded-lg p-4 mb-6">
                  <p className="text-green-400 text-sm mb-2">✅ Paymaster Deployed Successfully!</p>
                  <p className="font-mono text-xs text-white break-all">{deployedAddress}</p>
                </div>
              )}

              <div className="flex justify-center space-x-4">
                <button
                  onClick={handleDeposit}
                  className="px-6 py-3 bg-green-600 hover:bg-green-700 text-white font-medium rounded-lg transition-colors flex items-center space-x-2"
                >
                  <span>Deposit {config.initialDeposit} ETH</span>
                </button>
              </div>
            </div>
          )}

          {step === 'register' && config.autoRegister && (
            <div className="p-6 text-center">
              <div className="w-16 h-16 bg-blue-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
                <span className="text-blue-400 text-3xl">📝</span>
              </div>
              <h2 className="text-2xl font-bold text-white mb-4">Register with SuperPaymaster</h2>
              <p className="text-slate-400 mb-6">
                Register your paymaster with the SuperPaymaster marketplace
              </p>

              <div className="flex justify-center space-x-4">
                <button
                  onClick={() => setStep('complete')}
                  className="px-6 py-3 bg-slate-700 hover:bg-slate-600 text-white font-medium rounded-lg transition-colors"
                >
                  Skip Registration
                </button>
                <button
                  onClick={handleRegister}
                  className="px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-lg transition-colors"
                >
                  Register Now
                </button>
              </div>
            </div>
          )}

          {step === 'complete' && (
            <div className="p-6 text-center">
              <div className="w-16 h-16 bg-green-500/20 rounded-full flex items-center justify-center mx-auto mb-4">
                <span className="text-green-400 text-3xl">🎉</span>
              </div>
              <h2 className="text-2xl font-bold text-white mb-4">Deployment Complete!</h2>
              <p className="text-slate-400 mb-6">
                Your paymaster is now deployed and ready to sponsor user operations
              </p>

              {deployedAddress && (
                <div className="bg-slate-700/50 rounded-lg p-4 mb-6 text-left">
                  <h3 className="font-medium text-white mb-4">📋 Deployment Summary</h3>
                  <div className="space-y-2 text-sm">
                    <div className="flex justify-between">
                      <span className="text-slate-400">Contract Address:</span>
                      <span className="text-white font-mono text-xs">{deployedAddress}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Initial Deposit:</span>
                      <span className="text-white">{config.initialDeposit} ETH</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Fee Rate:</span>
                      <span className="text-white">{(config.feeRate / 100).toFixed(2)}%</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-400">Registered:</span>
                      <span className="text-green-400">{config.autoRegister ? 'Yes' : 'No'}</span>
                    </div>
                  </div>
                </div>
              )}

              <div className="flex justify-center space-x-4">
                <Link
                  href={`/manage?address=${deployedAddress}`}
                  className="px-6 py-3 bg-purple-600 hover:bg-purple-700 text-white font-medium rounded-lg transition-colors"
                >
                  Manage Paymaster
                </Link>
                <Link
                  href="/"
                  className="px-6 py-3 bg-slate-700 hover:bg-slate-600 text-white font-medium rounded-lg transition-colors"
                >
                  Back to Dashboard
                </Link>
              </div>
            </div>
          )}
        </div>
      </main>
    </div>
  );
}