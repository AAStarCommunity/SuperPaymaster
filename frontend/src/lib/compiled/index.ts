// Compiled Singleton Paymaster contracts from pimlico/singleton-paymaster
// Generated automatically from submodule compilation

import SingletonPaymasterV6ABI from './SingletonPaymasterV6.abi.json';
import SingletonPaymasterV7ABI from './SingletonPaymasterV7.abi.json';
import SingletonPaymasterV8ABI from './SingletonPaymasterV8.abi.json';

import { SINGLETON_PAYMASTER_V6_BYTECODE } from './SingletonPaymasterV6.bytecode';
import { SINGLETON_PAYMASTER_V7_BYTECODE } from './SingletonPaymasterV7.bytecode';
import { SINGLETON_PAYMASTER_V8_BYTECODE } from './SingletonPaymasterV8.bytecode';

export const SINGLETON_PAYMASTER_CONTRACTS = {
  v6: {
    name: 'Singleton Paymaster V6',
    description: 'Pimlico singleton paymaster for EntryPoint v0.6 - supports Verifying and ERC-20 modes',
    contractName: 'SingletonPaymasterV6',
    abi: SingletonPaymasterV6ABI as const,
    bytecode: SINGLETON_PAYMASTER_V6_BYTECODE,
    entryPoint: '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789'
  },
  v7: {
    name: 'Singleton Paymaster V7',
    description: 'Pimlico singleton paymaster for EntryPoint v0.7 - supports Verifying and ERC-20 modes',
    contractName: 'SingletonPaymasterV7',
    abi: SingletonPaymasterV7ABI as const,
    bytecode: SINGLETON_PAYMASTER_V7_BYTECODE,
    entryPoint: '0x0000000071727De22E5E9d8BAf0edAc6f37da032'
  },
  v8: {
    name: 'Singleton Paymaster V8',
    description: 'Pimlico singleton paymaster for EntryPoint v0.8 - supports Verifying and ERC-20 modes with EIP-7702',
    contractName: 'SingletonPaymasterV8',
    abi: SingletonPaymasterV8ABI as const,
    bytecode: SINGLETON_PAYMASTER_V8_BYTECODE,
    entryPoint: '0x0000000071727De22E5E9d8BAf0edAc6f37da032'
  }
} as const;

export type PaymasterVersion = keyof typeof SINGLETON_PAYMASTER_CONTRACTS;

// Export individual ABIs for convenience
export {
  SingletonPaymasterV6ABI,
  SingletonPaymasterV7ABI,
  SingletonPaymasterV8ABI
};