import { createConfig, http } from 'wagmi'
import { mainnet, sepolia } from 'wagmi/chains'
import { metaMask } from 'wagmi/connectors'

export const config = createConfig({
  chains: [sepolia, mainnet],
  connectors: [
    metaMask()
  ],
  transports: {
    [sepolia.id]: http(),
    [mainnet.id]: http(),
  },
  ssr: true,
});

export const SUPPORTED_CHAINS = {
  1: { name: 'Ethereum', icon: '🇪🇹' },
  11155111: { name: 'Sepolia', icon: '🧪' },
} as const;