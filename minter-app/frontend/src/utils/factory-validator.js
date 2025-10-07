// Factory address validator for testing different known addresses
import { ethers } from 'ethers';

// Known factory addresses to test
export const KNOWN_FACTORIES = {
  // Official eth-infinitism deployments
  official_v06: {
    name: "Official SimpleAccountFactory v0.6",
    address: "0x9406Cc6185a346906296840746125a0E44976454",
    network: "Sepolia"
  },
  
  // Alternative known addresses
  alt1: {
    name: "Alternative SimpleAccountFactory 1",
    address: "0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985",
    network: "Sepolia"
  },
  
  // StackUp deployment
  stackup: {
    name: "StackUp SimpleAccountFactory",
    address: "0x15Ba39aff9834029815652432bf5C1e9269C55C6",
    network: "Sepolia"
  },
  
  // Biconomy deployment
  biconomy: {
    name: "Biconomy SimpleAccountFactory",
    address: "0x000000a56Aaca3e9a4C479ea6b6CD0DbcB6634F5",
    network: "Sepolia"
  }
};

const SIMPLE_FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) returns (address ret)",
  "function getAddress(address owner, uint256 salt) view returns (address)",
  "function accountImplementation() view returns (address)"
];

/**
 * Validate a factory address by testing its interface
 */
export async function validateFactory(factoryAddress, provider) {
  try {
    console.log(`Testing factory: ${factoryAddress}`);
    
    // Check if contract exists
    const code = await provider.getCode(factoryAddress);
    if (code === '0x') {
      return {
        valid: false,
        error: "No contract at address",
        address: factoryAddress
      };
    }
    
    // Test the factory interface
    const factory = new ethers.Contract(factoryAddress, SIMPLE_FACTORY_ABI, provider);
    
    // Test accountImplementation() call
    try {
      const impl = await factory.accountImplementation();
      console.log(`Implementation address: ${impl}`);
    } catch (err) {
      return {
        valid: false,
        error: `accountImplementation() failed: ${err.message}`,
        address: factoryAddress
      };
    }
    
    // Test address calculation
    const testOwner = "0x1234567890123456789012345678901234567890";
    const testSalt = 12345;
    
    try {
      const predictedAddr = await factory.getAddress(testOwner, testSalt);
      console.log(`Predicted address: ${predictedAddr}`);
      
      // Verify it's not returning the factory address itself
      if (predictedAddr.toLowerCase() === factoryAddress.toLowerCase()) {
        return {
          valid: false,
          error: "Factory returns its own address",
          address: factoryAddress
        };
      }
      
      // Test with different salt produces different address
      const predictedAddr2 = await factory.getAddress(testOwner, 67890);
      if (predictedAddr === predictedAddr2) {
        return {
          valid: false,
          error: "Different salts produce same address",
          address: factoryAddress
        };
      }
      
      return {
        valid: true,
        address: factoryAddress,
        implementation: await factory.accountImplementation(),
        testAddress: predictedAddr
      };
      
    } catch (err) {
      return {
        valid: false,
        error: `getAddress() failed: ${err.message}`,
        address: factoryAddress
      };
    }
    
  } catch (err) {
    return {
      valid: false,
      error: `Validation failed: ${err.message}`,
      address: factoryAddress
    };
  }
}

/**
 * Test all known factory addresses
 */
export async function testAllKnownFactories(provider) {
  const results = [];
  
  for (const [key, factory] of Object.entries(KNOWN_FACTORIES)) {
    console.log(`\n=== Testing ${factory.name} ===`);
    const result = await validateFactory(factory.address, provider);
    results.push({
      key,
      name: factory.name,
      ...result
    });
  }
  
  return results;
}

/**
 * Find the first working factory
 */
export async function findWorkingFactory(provider) {
  const results = await testAllKnownFactories(provider);
  const working = results.find(r => r.valid);
  
  if (working) {
    console.log(`✅ Found working factory: ${working.name} at ${working.address}`);
    return working;
  } else {
    console.log('❌ No working factories found');
    return null;
  }
}
