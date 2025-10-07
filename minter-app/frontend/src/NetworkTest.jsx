import React, { useState } from 'react';
import { getNetworkConfig, validateNetworkConfig } from './config/aa-config.js';

// Use appropriate backend URL based on environment (same as NFT minter)
const backendUrl = window.location.hostname === 'localhost' 
    ? 'http://localhost:3001'  // Development: use local Express backend
    : '';  // Production: use same domain (Vercel API routes)

export default function NetworkTest() {
  const [results, setResults] = useState('');
  const [loading, setLoading] = useState(false);

  const runTest = async () => {
    setLoading(true);
    setResults('🧪 Testing Backend API Integration...\n\n');
    
    try {
      const chainId = 11155111; // Sepolia
      const testOwner = '0x742d35cC6634c0532925A3b8d39E9C4b73e86E7D';
      const testSalt = 0;
      
      // Test 1: Validate network configuration
      setResults(prev => prev + '1️⃣ Testing network configuration...\n');
      const validation = validateNetworkConfig(chainId, 'simple');
      if (!validation.isValid) {
        throw new Error(`Network validation failed: ${validation.error}`);
      }
      setResults(prev => prev + `✅ Network: ${validation.network.name}\n`);
      setResults(prev => prev + `✅ Factory: ${validation.factory.name}\n`);
      setResults(prev => prev + `✅ Address: ${validation.factory.address}\n\n`);
      
      // Test 2: Backend API connectivity
      setResults(prev => prev + '2️⃣ Testing backend API...\n');
      const response = await fetch(`${backendUrl}/calculateAccountAddress`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          owner: testOwner,
          salt: testSalt,
          factoryAddress: validation.factory.address
        }),
      });
      
      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(`Backend API error: ${errorData.details || errorData.error || response.statusText}`);
      }
      
      const data = await response.json();
      const { predictedAddress } = data;
      
      setResults(prev => prev + `✅ Backend API connected successfully\n`);
      setResults(prev => prev + `✅ Response received: ${JSON.stringify(data)}\n\n`);
      
      // Test 3: Address validation
      setResults(prev => prev + '3️⃣ Validating predicted address...\n');
      setResults(prev => prev + `📍 Predicted Address: ${predictedAddress}\n`);
      setResults(prev => prev + `🏭 Factory Address: ${validation.factory.address}\n`);
      
      const isSameAsFactory = predictedAddress.toLowerCase() === validation.factory.address.toLowerCase();
      if (isSameAsFactory) {
        setResults(prev => prev + `❌ ERROR: Predicted address is same as factory address!\n`);
        setResults(prev => prev + `   This indicates the contract has a bug.\n\n`);
      } else {
        setResults(prev => prev + `✅ SUCCESS: Predicted address is different from factory\n\n`);
      }
      
      // Test 4: Multiple salt values
      setResults(prev => prev + '4️⃣ Testing different salt values...\n');
      const testSalts = [0, 1, 12345, 999999];
      for (const salt of testSalts) {
        const saltResponse = await fetch(`${backendUrl}/calculateAccountAddress`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            owner: testOwner,
            salt: salt,
            factoryAddress: validation.factory.address
          }),
        });
        
        if (saltResponse.ok) {
          const saltData = await saltResponse.json();
          setResults(prev => prev + `   Salt ${salt}: ${saltData.predictedAddress.substring(0,10)}...\n`);
        }
      }
      
      setResults(prev => prev + '\n🎉 All tests completed!\n');
      
    } catch (error) {
      setResults(prev => prev + `\n❌ Test failed: ${error.message}\n`);
      console.error('Network test error:', error);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="card" style={{ margin: '20px', padding: '20px', maxWidth: '800px' }}>
      <h3>🔧 Network & Backend API Test</h3>
      <p>This tool tests the complete backend integration for ERC-4337 address calculation.</p>
      
      <button 
        onClick={runTest} 
        disabled={loading}
        style={{ 
          padding: '12px 24px', 
          fontSize: '16px',
          backgroundColor: loading ? '#ccc' : '#4CAF50',
          color: 'white',
          border: 'none',
          borderRadius: '6px',
          cursor: loading ? 'not-allowed' : 'pointer',
          marginBottom: '20px'
        }}
      >
        {loading ? '🔄 Running Tests...' : '▶️ Run Network Tests'}
      </button>

      {results && (
        <div style={{ 
          backgroundColor: '#f8f9fa',
          border: '1px solid #dee2e6',
          borderRadius: '6px',
          padding: '16px',
          fontFamily: 'Monaco, Consolas, monospace',
          fontSize: '14px',
          whiteSpace: 'pre-line',
          maxHeight: '500px',
          overflowY: 'auto',
          lineHeight: '1.5'
        }}>
          {results}
        </div>
      )}
    </div>
  );
}