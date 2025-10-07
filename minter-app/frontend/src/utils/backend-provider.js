/**
 * Backend Provider - 通过backend API进行网络调用，避免暴露RPC URL
 */

// Use appropriate backend URL based on environment
const getBackendUrl = () => {
  return window.location.hostname === 'localhost' 
    ? 'http://localhost:3001'  // Development - backend server port
    : '';  // Production: use same domain
};

/**
 * Backend Provider that proxies network calls through our API
 */
export class BackendProvider {
  constructor(chainId = 11155111) {
    this.chainId = chainId;
    this.backendUrl = getBackendUrl();
  }

  async _makeRequest(method, params = []) {
    const response = await fetch(`${this.backendUrl}/api/network/provider`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        method,
        params,
        chainId: this.chainId
      })
    });

    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(errorData.message || `HTTP ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    return data.result;
  }

  async getCode(address) {
    return await this._makeRequest('getCode', [address]);
  }

  async call(transaction) {
    return await this._makeRequest('call', [transaction]);
  }

  async getBalance(address) {
    return await this._makeRequest('getBalance', [address]);
  }

  // For contract calls, we need to support the Contract interface
  async staticCall(transaction) {
    return await this.call(transaction);
  }
}

/**
 * Create a backend provider for secure network access
 */
export function createBackendProvider(chainId = 11155111) {
  return new BackendProvider(chainId);
}

/**
 * Test backend provider connectivity
 */
export async function testBackendProvider(chainId = 11155111) {
  try {
    const provider = createBackendProvider(chainId);
    
    // Test with a known contract (our factory)
    const factoryAddress = '0x18F4c5CbBEca54A2Ca70B556630B69bA54f7cF55';
    const code = await provider.getCode(factoryAddress);
    
    return {
      success: true,
      codeLength: code.length,
      hasContract: code.length > 2
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  }
}
