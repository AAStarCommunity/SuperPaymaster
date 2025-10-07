import { useState, useEffect, useCallback } from 'react';
import { ethers } from 'ethers';
import { config } from './config';
import './App.css';

// 使用正确的SimpleAccountFactory ABI
const SIMPLE_ACCOUNT_FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) returns (address ret)",
  "function getAddress(address owner, uint256 salt) view returns (address)",
  // 尝试不同的参数顺序和类型
  "function getAddress(uint256 salt, address owner) view returns (address)",
  "function accountImplementation() view returns (address)",
  "function entryPoint() view returns (address)"
];

// Alchemy Light Account Factory - 可能有不同的接口
const ALCHEMY_LIGHT_ACCOUNT_ABI = [
  "function createAccount(address owner, uint256 salt) returns (address)",
  "function getAddress(address owner, uint256 salt) view returns (address)",
  "function getAddress(uint256 salt, address owner) view returns (address)"
];

// 尝试Biconomy/Kernel等其他工厂的ABI
const KERNEL_FACTORY_ABI = [
  "function createAccount(address owner, uint256 index) returns (address)",
  "function getAccountAddress(address owner, uint256 index) view returns (address)",
  "function getAddress(address owner, uint256 index) view returns (address)"
];

// Safe 4337 Factory ABI
const SAFE_FACTORY_ABI = [
  "function createProxyWithNonce(address _singleton, bytes initializer, uint256 saltNonce) returns (address proxy)",
  "function proxyCreationCode() view returns (bytes)",
  "function calculateCreateProxyWithNonceAddress(address _singleton, bytes initializer, uint256 saltNonce, address target) view returns (address proxy)"
];

// 工厂合约配置 - 使用不同ABI匹配不同工厂类型
const FACTORIES = {
  simple_v06: {
    name: "Simple Account Factory v0.6",
    address: "0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985", // v0.6 (Sepolia)
    abi: SIMPLE_ACCOUNT_FACTORY_ABI,
    methods: ['getAddress'] // 优先尝试的方法
  },
  alchemy_light: {
    name: "Alchemy Light Account v1.1.0", 
    address: "0x0000000000400CdFef5E2714E63d8040b700BC24", // v1.1.0 (Sepolia)
    abi: ALCHEMY_LIGHT_ACCOUNT_ABI,
    methods: ['getAddress']
  },
  simple_alt1: {
    name: "Simple Account (Alternative 1)",
    address: "0x9406Cc6185a346906296840746125a0E44976454", // 另一个已知地址
    abi: SIMPLE_ACCOUNT_FACTORY_ABI,
    methods: ['getAddress']
  },
  simple_alt2: {
    name: "Simple Account (Alternative 2)", 
    address: "0x15Ba39aff9834029815652432bf5C1e9269C55C6", // Biconomy Simple Account Factory
    abi: SIMPLE_ACCOUNT_FACTORY_ABI,
    methods: ['getAddress']
  },
  zk_simple: {
    name: "ZK Simple Account Factory",
    address: "0x9aEA6E9504cCA01B267dAc45e0cC2883F8c0ae31", // niv-fundation部署的
    abi: SIMPLE_ACCOUNT_FACTORY_ABI,
    methods: ['getAddress']
  },
  kernel_v24: {
    name: "Kernel Account Factory v2.4",
    address: "0x5de4839a76cf55d0c90e2061ef4386d962E15ae3", // Kernel v2.4
    abi: KERNEL_FACTORY_ABI,
    methods: ['getAccountAddress', 'getAddress'] // Kernel可能用不同方法名
  },
  safe_4337: {
    name: "Safe 4337 Module Factory",
    address: "0xa581c4A4DB7175302464fF3C06380BC3270b4037", // Safe 4337
    abi: SAFE_FACTORY_ABI,
    methods: ['calculateCreateProxyWithNonceAddress'] // Safe用完全不同的接口
  },
  stackup: {
    name: "StackUp Simple Account Factory",
    address: "0x9406Cc6185a346906296840746125a0E44976454", // StackUp部署
    abi: SIMPLE_ACCOUNT_FACTORY_ABI,
    methods: ['getAddress']
  }
};

// PNTs合约ABI
const PNTS_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address, uint256) returns (bool)"
];

export default function AccountCreatorPage({ account, provider, onBack }) {
  const [selectedFactory, setSelectedFactory] = useState('simple_v06');
  const [predictedAddress, setPredictedAddress] = useState('');
  const [txHash, setTxHash] = useState('');
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  // 转账相关状态
  const [pntsAmount, setPntsAmount] = useState('100');
  const [ethAmount, setEthAmount] = useState('0.01');
  const [pntsBalance, setPntsBalance] = useState('0');
  const [ethBalance, setEthBalance] = useState('0');

  // Salt 相关状态
  const [customSalt, setCustomSalt] = useState('0');
  const [useRandomSalt, setUseRandomSalt] = useState(false);

  // 已创建账户列表
  const [createdAccounts, setCreatedAccounts] = useState([]);

  const fetchBalances = useCallback(async () => {
    if (!account || !provider) return;

    try {
      // 获取PNTs余额
      const pntsContract = new ethers.Contract(config.addresses.pnts, PNTS_ABI, provider);
      const pntsBal = await pntsContract.balanceOf(account);
      setPntsBalance(ethers.formatUnits(pntsBal, 18));

      // 获取ETH余额
      const ethBal = await provider.getBalance(account);
      setEthBalance(ethers.formatEther(ethBal));
    } catch (err) {
      console.error('Failed to fetch balances:', err);
    }
  }, [account, provider]);

  const loadCreatedAccounts = useCallback(() => {
    try {
      const saved = localStorage.getItem('createdAccounts');
      if (saved) {
        setCreatedAccounts(JSON.parse(saved));
      }
    } catch (err) {
      console.error('Failed to load created accounts:', err);
    }
  }, []);

  useEffect(() => {
    if (account && provider) {
      fetchBalances();
      loadCreatedAccounts();
    }
  }, [account, provider, fetchBalances, loadCreatedAccounts]);

  const saveCreatedAccount = (accountData) => {
    const updated = [...createdAccounts, accountData];
    setCreatedAccounts(updated);
    localStorage.setItem('createdAccounts', JSON.stringify(updated));
  };

  const generateRandomSalt = () => {
    // 生成一个32字节的随机数作为salt
    const randomBytes = ethers.randomBytes(32);
    return ethers.hexlify(randomBytes);
  };

  const normalizeSalt = (salt) => {
    if (!salt || salt === '') return '0';

    // 如果是十六进制格式，直接返回
    if (salt.startsWith('0x')) {
      return salt;
    }

    // 如果是纯数字，转换为十六进制
    if (/^\d+$/.test(salt)) {
      try {
        const num = BigInt(salt);
        return '0x' + num.toString(16).padStart(64, '0');
      } catch (err) {
        console.warn('Invalid salt number:', salt);
        return '0';
      }
    }

    // 其他情况尝试直接使用
    return salt;
  };

  const getCurrentSalt = () => {
    let salt;
    if (useRandomSalt) {
      // 每次都生成新的随机salt
      salt = generateRandomSalt();
      // 更新状态以便显示
      setCustomSalt(salt);
    } else {
      // 如果custom salt为空，生成一个默认的随机salt
      salt = customSalt || generateRandomSalt();
    }

    // 规范化salt格式
    return normalizeSalt(salt);
  };

  const calculateAddress = async () => {
    if (!account || !provider) {
      setError('Please connect wallet first');
      return;
    }

    try {
      setLoading(true);
      setError('');
      setMessage('Calculating address...');

      const factory = FACTORIES[selectedFactory];
      console.log('=== Address Calculation Debug ===');
      console.log('Selected factory:', selectedFactory);
      console.log('Factory config:', factory);
      console.log('Owner account:', account);
      
      const factoryContract = new ethers.Contract(factory.address, factory.abi, provider);
      console.log('Factory contract created:', factoryContract.target);

      // 使用当前salt（自定义或随机生成）
      const salt = getCurrentSalt();
      console.log('Using salt for address calculation:', salt);

      const saltBigInt = ethers.getBigInt(salt);
      console.log('Salt as BigInt:', saltBigInt.toString());

      // 使用工厂特定的方法来获取地址
      let predictedAddr = null;
      const methods = factory.methods || ['getAddress'];
      
      for (const methodName of methods) {
        try {
          console.log(`Trying method: ${methodName}`);
          if (factoryContract[methodName]) {
            
            // 根据不同工厂类型使用不同的参数
            let result;
            if (methodName === 'calculateCreateProxyWithNonceAddress') {
              // Safe 4337 需要特殊参数
              console.log(`Safe factory not yet implemented`);
              continue;
            } else if (methodName === 'getAccountAddress') {
              // Kernel factory 可能使用 index 而不是 salt
              console.log(`Calling factoryContract.${methodName} with:`, { owner: account, index: saltBigInt.toString() });
              result = await factoryContract[methodName](account, saltBigInt);
            } else {
              // 标准的 getAddress 方法，尝试两种参数顺序
              try {
                console.log(`Calling factoryContract.${methodName} with:`, { owner: account, salt: saltBigInt.toString() });
                result = await factoryContract[methodName](account, saltBigInt);
              } catch (err1) {
                console.log(`First parameter order failed, trying reversed...`);
                result = await factoryContract[methodName](saltBigInt, account);
              }
            }
            
            console.log(`Raw result from ${methodName}:`, result);
            
            // 检查返回地址是否与工厂地址相同
            if (result && result.toLowerCase() !== factory.address.toLowerCase()) {
              console.log(`✅ Success with method: ${methodName}`);
              predictedAddr = result;
              break; // 找到有效方法，退出循环
            } else {
              console.log(`❌ Method ${methodName} returned factory address or null`);
            }
          } else {
            console.log(`❌ Method ${methodName} not found in contract`);
          }
        } catch (err) {
          console.log(`❌ Method ${methodName} failed:`, err.message);
        }
      }
      
      if (!predictedAddr || predictedAddr.toLowerCase() === factory.address.toLowerCase()) {
        console.error('⚠️ WARNING: All methods returned factory address or failed!');
        setError(`Factory contract issue: All address calculation methods failed. This might be a wrong contract address or ABI mismatch.`);
        return;
      }
      
      console.log('Factory address (should be different):', factory.address);

      setPredictedAddress(predictedAddr);
      setMessage(''); // 清除顶部消息，地址显示在固定区域
      console.log('=== Address Calculation Success ===');

    } catch (err) {
      setError('Address calculation failed: ' + err.message);
      console.error('Address calculation error:', err);
    } finally {
      setLoading(false);
    }
  };

  const createAccount = async () => {
    if (!account || !predictedAddress || !provider) {
      setError('Please connect wallet and calculate address first');
      return;
    }

    try {
      setLoading(true);
      setError('');
      setMessage('Creating account...');

      const factory = FACTORIES[selectedFactory];
      const signer = await provider.getSigner();
      const factoryContract = new ethers.Contract(factory.address, factory.abi, signer);

      // 检查账户是否已存在
      const code = await provider.getCode(predictedAddress);
      if (code !== '0x') {
        setMessage('Account already exists!');
        return;
      }

      // 创建账户 - 使用当前salt
      const salt = getCurrentSalt();
      const saltBigInt = ethers.getBigInt(salt);

      const tx = await factoryContract.createAccount(account, saltBigInt, {
        gasLimit: 1000000
      });

      setTxHash(tx.hash);
      setMessage(`Transaction submitted: ${tx.hash.substring(0, 10)}...`);

      // 等待交易确认
      const receipt = await tx.wait();
      if (receipt.status === 0) {
        throw new Error('Transaction failed');
      }

      setMessage(`✅ Account created successfully! Address: ${predictedAddress}`);

      // 保存创建的账户
      const accountData = {
        address: predictedAddress,
        factory: selectedFactory,
        factoryName: factory.name,
        salt: salt,
        createdAt: new Date().toISOString(),
        txHash: tx.hash,
        owner: account,
        network: 'sepolia'
      };
      saveCreatedAccount(accountData);

    } catch (err) {
      setError('Account creation failed: ' + err.message);
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const transferToAccount = async (isPNTs = true) => {
    if (!account || !predictedAddress || !provider) {
      setError('Please create account first');
      return;
    }

    try {
      setLoading(true);
      setError('');
      setMessage(isPNTs ? 'Transferring PNTs...' : 'Transferring ETH...');

      const signer = await provider.getSigner();

      if (isPNTs) {
        // 转账PNTs
        const pntsContract = new ethers.Contract(config.addresses.pnts, PNTS_ABI, signer);
        const amount = ethers.parseUnits(pntsAmount, 18);
        const tx = await pntsContract.transfer(predictedAddress, amount);

        await tx.wait();
        setMessage(`✅ PNTs transferred successfully!`);

      } else {
        // 转账ETH
        const amount = ethers.parseEther(ethAmount);
        const tx = await signer.sendTransaction({
          to: predictedAddress,
          value: amount
        });

        await tx.wait();
        setMessage(`✅ ETH transferred successfully!`);
      }

      // 重新获取余额
      await fetchBalances();

    } catch (err) {
      setError(`Transfer failed: ${err.message}`);
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="App">
      <header className="App-header">
        <div>
          <h1>🚀 ERC-4337 Account Creator</h1>
          <div className="header-right">
            <button type="button" onClick={onBack} className="back-btn">← Back to Main</button>
            {account && (
              <div className="account-info">
                <p>Connected: <span className="address">{`${account.substring(0, 6)}...${account.substring(account.length - 4)}`}</span></p>
              </div>
            )}
          </div>
        </div>
      </header>

      <div className="container">
        <div className="minting-column">
          {message && <div className="message-banner">{message}</div>}
          {error && <div className="error-banner">{error}</div>}

          {/* 余额显示 */}
          <div className="card">
            <h3>💰 Your Balances</h3>
            <div className="balance-info">
              <p>PNTs: <strong>{pntsBalance}</strong></p>
              <p>ETH: <strong>{ethBalance}</strong></p>
            </div>
          </div>

          {/* 工厂选择 */}
          <div className="card">
            <h3>🏭 Choose Factory</h3>
            <div className="factory-options">
              {Object.entries(FACTORIES).map(([key, factory]) => (
                <label key={key} className={selectedFactory === key ? 'factory-option active' : 'factory-option'}>
                  <input
                    type="radio"
                    value={key}
                    checked={selectedFactory === key}
                    onChange={(e) => setSelectedFactory(e.target.value)}
                  />
                  <div className="option-content">
                    <span className="option-title">{factory.name}</span>
                    <span className="option-desc">{factory.address.substring(0, 10)}...{factory.address.substring(38)}</span>
                  </div>
                </label>
              ))}
            </div>

            {/* Salt 配置 */}
            <div className="salt-config">
              <h4>🔑 Salt Configuration</h4>
              <div className="salt-options">
                <label className="salt-option">
                  <input
                    type="radio"
                    checked={!useRandomSalt}
                    onChange={() => {
                      setUseRandomSalt(false);
                      setCustomSalt('0');
                    }}
                  />
                  <span>Custom Salt</span>
                </label>
                <label className="salt-option">
                  <input
                    type="radio"
                    checked={useRandomSalt}
                    onChange={() => setUseRandomSalt(true)}
                  />
                  <span>Random Salt (每次生成新地址)</span>
                </label>
              </div>

              {!useRandomSalt && (
                <div className="salt-input">
                  <input
                    type="text"
                    value={customSalt}
                    onChange={(e) => setCustomSalt(e.target.value)}
                    placeholder="输入salt值 (十六进制或十进制)"
                    className="salt-text-input"
                  />
                  <button
                    type="button"
                    onClick={() => {
                      const randomSalt = generateRandomSalt();
                      setCustomSalt(randomSalt);
                      setMessage(`Random salt generated: ${randomSalt.substring(0, 10)}...`);
                    }}
                    className="random-salt-btn"
                  >
                    🎲 随机生成
                  </button>
                </div>
              )}

              {/* 显示当前salt值 */}
              <div className="current-salt-display">
                <span className="salt-label">当前Salt:</span>
                <code className="salt-value">
                  {useRandomSalt ? '随机生成 (每次计算时生成新值)' : normalizeSalt(customSalt)}
                </code>
              </div>
            </div>

            <button type="button" onClick={calculateAddress} disabled={loading || !account} className="calc-btn">
              🔍 Calculate Address
            </button>
          </div>

          {/* 地址预览 - 始终显示 */}
          <div className="card">
            <h3>🎯 Predicted Smart Account Address</h3>
            {predictedAddress ? (
              <div className="address-info">
                <p className="address-label">🔑 Your ERC-4337 Account:</p>
                <p className="predicted-address">{predictedAddress}</p>
                <div className="calculation-details">
                  <p className="salt-used">🧂 Salt Used: <code>{getCurrentSalt()}</code></p>
                  <p className="factory-used">🏭 Factory: {selectedFactory} ({FACTORIES[selectedFactory].address.substring(0, 10)}...)</p>
                </div>
                <p className="address-note">⚠️ This is NOT the factory contract address!</p>
                <a
                  href={`https://sepolia.etherscan.io/address/${predictedAddress}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="etherscan-link"
                >
                  📊 View Smart Account on Etherscan
                </a>
                <button
                  type="button"
                  onClick={createAccount}
                  disabled={loading}
                  className="create-account-btn"
                >
                  {loading ? '⏳ Creating...' : '🚀 Create Account'}
                </button>
              </div>
            ) : (
              <div className="address-placeholder">
                <p className="placeholder-text">
                  👆 Click "🔍 Calculate Address" to generate your smart account address
                </p>
                <div className="placeholder-address">
                  <span className="placeholder-label">Address will appear here...</span>
                </div>
              </div>
            )}
          </div>

          {/* 转账功能 */}
          {predictedAddress && txHash && (
            <div className="card">
              <h3>💸 Fund New Account</h3>

              {/* PNTs转账 */}
              <div className="transfer-section">
                <h4>Transfer PNTs</h4>
                <div className="transfer-form">
                  <input
                    type="number"
                    value={pntsAmount}
                    onChange={(e) => setPntsAmount(e.target.value)}
                    placeholder="Amount of PNTs"
                    step="0.1"
                  />
                  <button
                    type="button"
                    onClick={() => transferToAccount(true)}
                    disabled={loading}
                    className="transfer-btn"
                  >
                    Transfer PNTs
                  </button>
                </div>
              </div>

              {/* ETH转账 */}
              <div className="transfer-section">
                <h4>Transfer ETH</h4>
                <div className="transfer-form">
                  <input
                    type="number"
                    value={ethAmount}
                    onChange={(e) => setEthAmount(e.target.value)}
                    placeholder="Amount of ETH"
                    step="0.001"
                  />
                  <button
                    type="button"
                    onClick={() => transferToAccount(false)}
                    disabled={loading}
                    className="transfer-btn"
                  >
                    Transfer ETH
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* 交易结果 */}
          {txHash && (
            <div className="card">
              <h3>✅ Transaction Result</h3>
              <a
                href={`https://sepolia.etherscan.io/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="tx-link"
              >
                🔗 View Transaction on Etherscan
              </a>
            </div>
          )}
        </div>

        <div className="collection-column">
          <h2 className="collection-header">📋 Created Accounts</h2>

          <div className="card collection-card">
            <h3>🏦 Your ERC-4337 Accounts ({createdAccounts.length})</h3>
            <div className="accounts-list">
              {createdAccounts.length > 0 ? (
                createdAccounts.map((acc, index) => (
                  <div key={`account-${acc.address}-${index}`} className="account-item">
                    <div className="account-info">
                      <p className="account-address">
                        {acc.address}
                      </p>
                      <p className="account-details">
                        {acc.factoryName} • Salt: {acc.salt?.substring(0, 10)}... • {new Date(acc.createdAt).toLocaleDateString()}
                      </p>
                    </div>
                    <div className="account-actions">
                      <a
                        href={`https://sepolia.etherscan.io/address/${acc.address}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="action-link"
                      >
                        📊
                      </a>
                      <a
                        href={`https://sepolia.etherscan.io/tx/${acc.txHash}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="action-link"
                      >
                        🔗
                      </a>
                    </div>
                  </div>
                ))
              ) : (
                <p className="empty-text">No accounts created yet</p>
              )}
            </div>
          </div>
        </div>
      </div>

      <footer className='footer'>
        <div className="footer-content">
          <div className="footer-section">
            <h4>🏭 Factory Contracts (For Reference)</h4>
            <p>Simple Factory: <code>{FACTORIES.simple_v06.address.substring(0, 10)}...</code></p>
            <p>Alchemy Factory: <code>{FACTORIES.alchemy_light.address.substring(0, 10)}...</code></p>
            <p className="factory-note">💡 These are factory contracts, not your smart accounts!</p>
          </div>
          <div className="footer-section">
            <h4>🔗 Network</h4>
            <p>Ethereum Sepolia Testnet</p>
            <p>ERC-4337 Compatible</p>
          </div>
          <div className="footer-section">
            <h4>ℹ️ Info</h4>
            <p>Account Creation Tool</p>
            <p>Version: 1.0</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
