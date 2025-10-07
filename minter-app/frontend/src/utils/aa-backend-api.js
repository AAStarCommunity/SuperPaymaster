/**
 * Account Abstraction Backend API 调用工具
 * 使用后端API进行地址计算和工厂验证，避免前端RPC暴露
 */

// Use appropriate backend URL based on environment
const getBackendUrl = () => {
  return window.location.hostname === 'localhost' 
    ? 'http://localhost:3001'  // Development - backend server port
    : '';  // Production: use same domain
};

/**
 * Calculate account address using backend API
 * @param {string} owner - Owner address
 * @param {number|string} salt - Salt value
 * @param {string} factoryAddress - Factory contract address
 * @param {number} chainId - Chain ID (default: 11155111 for Sepolia)
 * @returns {Promise<object>} Address calculation result
 */
export async function calculateAccountAddressBackend(owner, salt, factoryAddress, chainId = 11155111) {
  const backendUrl = getBackendUrl();
  
  try {
    console.log('=== Backend API: Calculate Account Address ===');
    console.log('Owner:', owner);
    console.log('Salt:', salt);
    console.log('Factory:', factoryAddress);
    console.log('Backend URL:', `${backendUrl}/calculateAccountAddress`);

    const response = await fetch(`${backendUrl}/calculateAccountAddress`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        owner,
        salt,
        factoryAddress,
        chainId
      })
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(errorData.message || errorData.error || `HTTP ${response.status}: ${response.statusText}`);
    }

    const result = await response.json();
    console.log('=== Backend API Success ===');
    console.log('Predicted Address:', result.predictedAddress);
    console.log('Implementation:', result.implementationAddress);
    
    return result;

  } catch (error) {
    console.error('Backend API Error:', error);
    throw new Error(`Backend API failed: ${error.message}`);
  }
}

/**
 * Validate factory contract using backend API
 * @param {string} factoryAddress - Factory contract address
 * @param {number} chainId - Chain ID (default: 11155111 for Sepolia)
 * @returns {Promise<object>} Factory validation result
 */
export async function validateFactoryBackend(factoryAddress, chainId = 11155111) {
  const backendUrl = getBackendUrl();
  
  try {
    console.log('=== Backend API: Validate Factory ===');
    console.log('Factory:', factoryAddress);
    console.log('Backend URL:', `${backendUrl}/validateFactory`);

    const response = await fetch(`${backendUrl}/validateFactory`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        factoryAddress,
        chainId
      })
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(errorData.message || errorData.error || `HTTP ${response.status}: ${response.statusText}`);
    }

    const result = await response.json();
    console.log('=== Factory Validation Success ===');
    console.log('Has Contract:', result.hasContract);
    console.log('Implementation:', result.implementationAddress);
    console.log('EntryPoint:', result.entryPointAddress);
    
    return result;

  } catch (error) {
    console.error('Factory Validation Error:', error);
    throw new Error(`Factory validation failed: ${error.message}`);
  }
}

/**
 * Test multiple factory addresses using backend API
 * @param {string} owner - Owner address
 * @param {number|string} salt - Salt value
 * @param {Array} factories - Array of factory objects with {name, address}
 * @param {number} chainId - Chain ID
 * @returns {Promise<object>} Test results for all factories
 */
export async function testFactoriesBackend(owner, salt, factories, chainId = 11155111) {
  const results = {};
  
  for (const factory of factories) {
    try {
      const result = await calculateAccountAddressBackend(owner, salt, factory.address, chainId);
      results[factory.name] = {
        success: true,
        address: factory.address,
        predictedAddress: result.predictedAddress,
        implementationAddress: result.implementationAddress,
        isSameAsFactory: result.predictedAddress.toLowerCase() === factory.address.toLowerCase()
      };
    } catch (error) {
      results[factory.name] = {
        success: false,
        error: error.message
      };
    }
  }
  
  return results;
}

/**
 * Test backend connectivity
 * @returns {Promise<object>} Connection test result
 */
export async function testBackendConnection() {
  const backendUrl = getBackendUrl();
  
  try {
    // Test with our known factory
    const testResult = await validateFactoryBackend('0x18F4c5CbBEca54A2Ca70B556630B69bA54f7cF55');
    
    return {
      success: true,
      backendUrl,
      factoryValid: testResult.isValid
    };
  } catch (error) {
    return {
      success: false,
      backendUrl,
      error: error.message
    };
  }
}
