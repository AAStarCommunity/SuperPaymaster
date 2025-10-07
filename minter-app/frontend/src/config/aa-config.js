// ERC-4337 Account Abstraction Configuration
// All RPC calls go through backend proxy for security

export const AA_NETWORKS = {
  // Sepolia Testnet - Only supported network for now
  11155111: {
    chainId: 11155111,
    name: "Sepolia",
    shortName: "sepolia",
    blockExplorer: "https://sepolia.etherscan.io",
    entryPoint: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789", // EntryPoint v0.6
    factories: {
      simple: {
        name: "WorkingFactory",
        address: "0xFc411603D1F1e2B1E9F692E2cBBb74Fd4f2feE18", // Working factory with getCalculatedAddress (final fix)
        type: "simple",
        version: "v0.6",
        description: "Working factory that avoids ethers.js Contract bug by using getCalculatedAddress",
        abi: [
          "function createAccount(address owner, uint256 salt) returns (address ret)",
          "function getCalculatedAddress(address owner, uint256 salt) view returns (address)",
          "function accountImplementation() view returns (address)",
          "function entryPoint() view returns (address)"
        ]
      },
      official: {
        name: "SimpleAccountFactory (Official)",
        address: "0x9406Cc6185a346906296840746125a0E44976454", // Official ERC-4337 SimpleAccountFactory
        type: "official",
        version: "v0.6",
        description: "Official SimpleAccountFactory from account-abstraction repository",
        abi: [
          "function createAccount(address owner, uint256 salt) returns (address ret)",
          "function getAddress(address owner, uint256 salt) view returns (address)", // 注意：这个有ethers.js bug
          "function accountImplementation() view returns (address)"
        ],
        note: "⚠️ getAddress function has ethers.js Contract bug, use at your own risk"
      }
    },
    isSupported: true
  }
};

// Default factory type preference
export const DEFAULT_FACTORY_TYPE = 'simple';

// EntryPoint version info
export const ENTRYPOINT_INFO = {
  version: "v0.6.0",
  address: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789",
  description: "Official EntryPoint v0.6 - CREATE2 deployed on all networks"
};

// Utility functions
export function getNetworkConfig(chainId) {
  return AA_NETWORKS[chainId];
}

export function getSupportedNetworks() {
  return Object.values(AA_NETWORKS).filter(network => network.isSupported);
}

export function getFactoryConfig(chainId, factoryType = DEFAULT_FACTORY_TYPE) {
  const network = getNetworkConfig(chainId);
  return network?.factories?.[factoryType];
}

export function isNetworkSupported(chainId) {
  const network = getNetworkConfig(chainId);
  return network?.isSupported || false;
}

export function validateNetworkConfig(chainId, factoryType = DEFAULT_FACTORY_TYPE) {
  const network = getNetworkConfig(chainId);
  if (!network) {
    return { isValid: false, error: `Network ${chainId} is not configured` };
  }
  
  if (!network.isSupported) {
    return { isValid: false, error: `Network ${network.name} is not supported yet` };
  }
  
  const factory = network.factories?.[factoryType];
  if (!factory) {
    return { isValid: false, error: `Factory type ${factoryType} not available on ${network.name}` };
  }
  
  return { isValid: true, network, factory };
}