import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { mainnet, sepolia, arbitrum, polygon, optimism, base } from 'wagmi/chains'

export const config = getDefaultConfig({
  appName: 'SuperPaymaster Dashboard',
  projectId: 'YOUR_WALLETCONNECT_PROJECT_ID', // Get from https://cloud.walletconnect.com
  chains: [mainnet, sepolia, arbitrum, polygon, optimism, base],
  ssr: true,
});

export const SUPPORTED_CHAINS = {
  1: { name: 'Ethereum', icon: '🇪🇹' },
  11155111: { name: 'Sepolia', icon: '🧪' },
  137: { name: 'Polygon', icon: '🟣' },
  42161: { name: 'Arbitrum', icon: '🔵' },
  10: { name: 'Optimism', icon: '🔴' },
  8453: { name: 'Base', icon: '🔷' },
} as const;