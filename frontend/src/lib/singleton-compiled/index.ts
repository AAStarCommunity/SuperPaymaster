import { CompiledContract, SingletonPaymasterContracts } from './types';

// Import compiled contracts
let SingletonPaymasterV6: any = null;
let SingletonPaymasterV7: any = null; 
let SingletonPaymasterV8: any = null;

try {
  SingletonPaymasterV6 = require('./SingletonPaymasterV6.json');
} catch (e) {
  console.warn('SingletonPaymasterV6 not found');
}

try {
  SingletonPaymasterV7 = require('./SingletonPaymasterV7.json');
} catch (e) {
  console.warn('SingletonPaymasterV7 not found');
}

try {
  SingletonPaymasterV8 = require('./SingletonPaymasterV8.json');
} catch (e) {
  console.warn('SingletonPaymasterV8 not found');
}

// EntryPoint addresses
const ENTRY_POINTS = {
  v6: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789",
  v7: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", 
  v8: "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
};

export const SINGLETON_PAYMASTER_CONTRACTS: Partial<SingletonPaymasterContracts> = {};

// Add V6 if available
if (SingletonPaymasterV6) {
  SINGLETON_PAYMASTER_CONTRACTS.v6 = {
    abi: SingletonPaymasterV6.abi,
    bytecode: SingletonPaymasterV6.bytecode?.object || SingletonPaymasterV6.bytecode,
    contractName: 'SingletonPaymasterV6',
    name: 'Pimlico Singleton Paymaster V6',
    description: 'Pimlico singleton paymaster for EntryPoint v0.6',
    entryPoint: ENTRY_POINTS.v6
  };
}

// Add V7 if available
if (SingletonPaymasterV7) {
  SINGLETON_PAYMASTER_CONTRACTS.v7 = {
    abi: SingletonPaymasterV7.abi,
    bytecode: SingletonPaymasterV7.bytecode?.object || SingletonPaymasterV7.bytecode,
    contractName: 'SingletonPaymasterV7',
    name: 'Pimlico Singleton Paymaster V7',
    description: 'Pimlico singleton paymaster for EntryPoint v0.7',
    entryPoint: ENTRY_POINTS.v7
  };
}

// Add V8 if available  
if (SingletonPaymasterV8) {
  SINGLETON_PAYMASTER_CONTRACTS.v8 = {
    abi: SingletonPaymasterV8.abi,
    bytecode: SingletonPaymasterV8.bytecode?.object || SingletonPaymasterV8.bytecode,
    contractName: 'SingletonPaymasterV8',
    name: 'Pimlico Singleton Paymaster V8', 
    description: 'Pimlico singleton paymaster for EntryPoint v0.8',
    entryPoint: ENTRY_POINTS.v8
  };
}

export default SINGLETON_PAYMASTER_CONTRACTS as SingletonPaymasterContracts;
