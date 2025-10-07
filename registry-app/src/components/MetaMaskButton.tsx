'use client';

import { useState, useEffect } from 'react';
import { useAccount, useConnect, useDisconnect } from 'wagmi';
import { metaMask } from 'wagmi/connectors';

export function MetaMaskButton() {
  const [mounted, setMounted] = useState(false);
  const { address, isConnected } = useAccount();
  const { connect } = useConnect();
  const { disconnect } = useDisconnect();

  useEffect(() => {
    setMounted(true);
  }, []);

  const handleConnect = () => {
    connect({ connector: metaMask() });
  };

  if (!mounted) {
    return (
      <div className="w-32 h-10 bg-slate-700 animate-pulse rounded-lg"></div>
    );
  }

  if (isConnected && address) {
    return (
      <div className="flex items-center space-x-3">
        <div className="flex items-center space-x-2 bg-slate-800 px-4 py-2 rounded-lg border border-slate-600">
          <div className="w-2 h-2 bg-green-500 rounded-full"></div>
          <span className="text-slate-300 text-sm font-mono">
            {address.slice(0, 6)}...{address.slice(-4)}
          </span>
        </div>
        <button
          onClick={() => disconnect()}
          className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white text-sm font-medium rounded-lg transition-colors"
        >
          Disconnect
        </button>
      </div>
    );
  }

  return (
    <button
      onClick={handleConnect}
      className="flex items-center space-x-2 px-4 py-2 bg-orange-600 hover:bg-orange-700 text-white font-medium rounded-lg transition-colors shadow-lg"
    >
      <svg className="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
        <path d="M3.483 2.103L12 8.686l8.514-6.583c.37-.288.906-.262 1.245.06.338.32.365.84.063 1.192L12 11.314 2.175 3.355c-.302-.352-.275-.872.063-1.192.339-.322.875-.348 1.245-.06z"/>
        <path d="M21.822 6.817L12 14.686 2.178 6.817c-.302-.352-.275-.872.063-1.192.339-.322.875-.348 1.245-.06L12 12.144l8.514-6.579c.37-.288.906-.262 1.245.06.338.32.365.84.063 1.192z"/>
      </svg>
      <span>Connect MetaMask</span>
    </button>
  );
}