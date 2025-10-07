import { useState, useEffect, useCallback } from 'react';
import { ethers } from 'ethers';
import { config } from './config';
import { 
  AA_NETWORKS, 
  getNetworkConfig, 
  getFactoryConfig, 
  getSupportedNetworks,
  ENTRYPOINT_INFO 
} from './config/aa-config.js';
import { 
  calculateAccountAddress,
  isAccountDeployed,
  getAccountInfo,
  getEntryPointDeposit,
  validateNetworkConfig,
  generateRandomSalt,
  normalizeSalt,
  formatAddress,
  getExplorerUrl,
  getAvailableFactories,
  compareFactoryAddresses
} from './utils/aa-utils.js';
import './App.css';

// PNTs合约ABI (保持不变)
const PNTS_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address, uint256) returns (bool)"
];

export default function AccountCreatorPageV2({ account, provider, onBack }) {
  // 网络和工厂选择
  const [currentNetwork, setCurrentNetwork] = useState(null);
  const [selectedFactory, setSelectedFactory] = useState('simple');
  
  // 账户相关状态
  const [predictedAddress, setPredictedAddress] = useState('');
  const [accountInfo, setAccountInfo] = useState(null);
  const [entryPointDeposit, setEntryPointDeposit] = useState('0');
  
  // 交易状态
  const [txHash, setTxHash] = useState('');
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  // Salt 配置
  const [customSalt, setCustomSalt] = useState('0');
  const [useRandomSalt, setUseRandomSalt] = useState(false);

  // 转账相关
  const [pntsAmount, setPntsAmount] = useState('100');
  const [ethAmount, setEthAmount] = useState('0.01');
  const [pntsBalance, setPntsBalance] = useState('0');
  const [ethBalance, setEthBalance] = useState('0');

  // 已创建账户列表
  const [createdAccounts, setCreatedAccounts] = useState([]);
  
  // 工厂比较
  const [showFactoryComparison, setShowFactoryComparison] = useState(false);
  const [factoryComparison, setFactoryComparison] = useState([]);

  // 获取当前网络信息
  useEffect(() => {
    async function detectNetwork() {
      if (!provider) return;
      
      try {
        const network = await provider.getNetwork();
        const networkConfig = getNetworkConfig(network.chainId);
        
        if (networkConfig) {
          setCurrentNetwork(networkConfig);
          console.log('Detected network:', networkConfig.name, 'Chain ID:', network.chainId);
        } else {
          setError(`Unsupported network. Chain ID: ${network.chainId}`);
        }
      } catch (err) {
        setError('Failed to detect network: ' + err.message);
      }
    }

    detectNetwork();
  }, [provider]);

  // 获取余额信息
  const fetchBalances = useCallback(async () => {
    if (!account || !provider) return;

    try {
      // 获取ETH余额
      const ethBal = await provider.getBalance(account);
      setEthBalance(ethers.formatEther(ethBal));

      // 获取PNTs余额
      if (config.contracts.PNTs.address) {
        const pntsContract = new ethers.Contract(config.contracts.PNTs.address, PNTS_ABI, provider);
        const pntsBal = await pntsContract.balanceOf(account);
        setPntsBalance(ethers.formatUnits(pntsBal, 18));
      }
    } catch (err) {
      console.error('Failed to fetch balances:', err);
    }
  }, [account, provider]);

  // 加载已创建的账户
  const loadCreatedAccounts = useCallback(() => {
    try {
      const saved = localStorage.getItem('createdAccountsV2');
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

  // 保存创建的账户
  const saveCreatedAccount = (accountData) => {
    const updated = [...createdAccounts, accountData];
    setCreatedAccounts(updated);
    localStorage.setItem('createdAccountsV2', JSON.stringify(updated));
  };

  // 获取当前使用的salt
  const getCurrentSalt = () => {
    let salt;
    if (useRandomSalt) {
      salt = generateRandomSalt();
      setCustomSalt(salt);
    } else {
      salt = customSalt || generateRandomSalt();
    }
    return normalizeSalt(salt);
  };

  // 计算账户地址
  const calculateAddress = async () => {
    if (!account || !provider || !currentNetwork) {
      setError('Please connect wallet and ensure network is supported');
      return;
    }

    try {
      setLoading(true);
      setError('');
      setMessage('Calculating address...');

      // 验证网络配置
      const validation = validateNetworkConfig(currentNetwork.chainId, selectedFactory);
      if (!validation.isValid) {
        setError(validation.error);
        return;
      }

      const salt = getCurrentSalt();
      console.log('=== Address Calculation ===');
      console.log('Network:', currentNetwork.name);
      console.log('Factory:', validation.factory.name);
      console.log('Owner:', account);
      console.log('Salt:', salt);

      // 计算地址
      const predictedAddr = await calculateAccountAddress(
        account,
        salt,
        currentNetwork.chainId,
        provider,
        selectedFactory
      );

      // 获取账户详细信息
      const info = await getAccountInfo(account, salt, currentNetwork.chainId, provider, selectedFactory);
      
      // 获取EntryPoint存款
      const deposit = await getEntryPointDeposit(predictedAddr, currentNetwork.chainId, provider);

      setPredictedAddress(predictedAddr);
      setAccountInfo(info);
      setEntryPointDeposit(deposit);
      setMessage('');

      console.log('=== Calculation Result ===');
      console.log('Predicted Address:', predictedAddr);
      console.log('Is Deployed:', info.isDeployed);
      console.log('ETH Balance:', info.balance);
      console.log('EntryPoint Deposit:', deposit);

    } catch (err) {
      setError('Address calculation failed: ' + err.message);
      console.error('Address calculation error:', err);
    } finally {
      setLoading(false);
    }
  };

  // 比较不同工厂的地址
  const compareFactories = async () => {
    if (!account || !provider || !currentNetwork) {
      setError('Please connect wallet and ensure network is supported');
      return;
    }

    try {
      setLoading(true);
      setError('');
      
      const salt = getCurrentSalt();
      console.log('=== Factory Comparison ===');
      console.log('Owner:', account);
      console.log('Salt:', salt);
      
      const comparison = await compareFactoryAddresses(
        account,
        salt,
        currentNetwork.chainId,
        provider
      );
      
      setFactoryComparison(comparison);
      setShowFactoryComparison(true);
      
      console.log('Factory Comparison Results:', comparison);
      
    } catch (err) {
      setError('Factory comparison failed: ' + err.message);
      console.error('Factory comparison error:', err);
    } finally {
      setLoading(false);
    }
  };

  // 创建账户 (目前只是占位，实际需要UserOperation)
  const createAccount = async () => {
    if (!predictedAddress || !currentNetwork) {
      setError('Please calculate address first');
      return;
    }

    try {
      setLoading(true);
      setError('');
      setMessage('Creating account...');

      // TODO: 实现真正的UserOperation创建流程
      // 这里先显示提示信息
      setMessage('⚠️ Account creation via UserOperation will be implemented in next phase');
      
      // 模拟创建成功，保存记录
      const accountData = {
        address: predictedAddress,
        owner: account,
        salt: getCurrentSalt(),
        factory: selectedFactory,
        network: currentNetwork.name,
        chainId: currentNetwork.chainId,
        createdAt: new Date().toISOString(),
        txHash: 'pending_userop_implementation' // 占位
      };

      saveCreatedAccount(accountData);
      setTxHash('pending_userop_implementation');

    } catch (err) {
      setError('Account creation failed: ' + err.message);
    } finally {
      setLoading(false);
    }
  };

  // 转账功能 (保持原有逻辑)
  const transferToAccount = async (type) => {
    if (!predictedAddress || !provider) {
      setError('No account address available');
      return;
    }

    try {
      setLoading(true);
      const signer = await provider.getSigner();

      if (type === 'pnts') {
        const pntsContract = new ethers.Contract(config.contracts.PNTs.address, PNTS_ABI, signer);
        const amount = ethers.parseUnits(pntsAmount, 18);
        const tx = await pntsContract.transfer(predictedAddress, amount);
        await tx.wait();
        setMessage(`✅ Transferred ${pntsAmount} PNTs to account`);
      } else if (type === 'eth') {
        const tx = await signer.sendTransaction({
          to: predictedAddress,
          value: ethers.parseEther(ethAmount)
        });
        await tx.wait();
        setMessage(`✅ Transferred ${ethAmount} ETH to account`);
      }

      // 刷新余额和账户信息
      await fetchBalances();
      if (predictedAddress) {
        const info = await getAccountInfo(account, getCurrentSalt(), currentNetwork.chainId, provider, selectedFactory);
        setAccountInfo(info);
      }

    } catch (err) {
      setError(`Transfer failed: ${err.message}`);
    } finally {
      setLoading(false);
    }
  };

  // 如果网络不支持，显示提示
  if (currentNetwork && !currentNetwork.isSupported) {
    return (
      <div className="account-creator">
        <div className="header">
          <button type="button" onClick={onBack} className="back-btn">← Back</button>
          <h2>🏗️ ERC-4337 Account Creator</h2>
        </div>

        <div className="card">
          <h3>⚠️ Network Not Supported</h3>
          <p>Current network: <strong>{currentNetwork.name}</strong></p>
          <p>Please switch to one of the supported networks:</p>
          <ul>
            {getSupportedNetworks().map(network => (
              <li key={network.chainId}>
                <strong>{network.name}</strong> (Chain ID: {network.chainId})
              </li>
            ))}
          </ul>
        </div>
      </div>
    );
  }

  return (
    <div className="account-creator">
      <div className="header">
        <button type="button" onClick={onBack} className="back-btn">← Back</button>
        <h2>🏗️ ERC-4337 Account Creator v2</h2>
      </div>

      {/* 网络信息 */}
      {currentNetwork && (
        <div className="card">
          <h3>🌐 Network Information</h3>
          <div className="network-info">
            <p><strong>Network:</strong> {currentNetwork.name}</p>
            <p><strong>Chain ID:</strong> {currentNetwork.chainId}</p>
            <p><strong>EntryPoint:</strong> {formatAddress(currentNetwork.entryPoint)}</p>
            <p><strong>Version:</strong> {ENTRYPOINT_INFO.version}</p>
          </div>
        </div>
      )}

      {/* 工厂选择 */}
      {currentNetwork && (
        <div className="card">
          <h3>🏭 Choose Account Factory</h3>
          <div className="factory-options">
            {Object.entries(currentNetwork.factories || {}).map(([key, factory]) => (
              <label key={key} className={selectedFactory === key ? 'factory-option active' : 'factory-option'}>
                <input
                  type="radio"
                  value={key}
                  checked={selectedFactory === key}
                  onChange={(e) => setSelectedFactory(e.target.value)}
                />
                <div className="option-content">
                  <span className="option-title">{factory.name}</span>
                  <span className="option-desc">{formatAddress(factory.address)} ({factory.version})</span>
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
                  placeholder="Enter salt value (number or hex)"
                  className="salt-text-input"
                />
                <button
                  type="button"
                  onClick={() => setCustomSalt(generateRandomSalt())}
                  className="random-salt-btn"
                >
                  🎲 随机生成
                </button>
              </div>
            )}

            <div className="current-salt-display">
              <span className="salt-label">当前Salt:</span>
              <code className="salt-value">
                {useRandomSalt ? '随机生成 (每次计算时生成新值)' : normalizeSalt(customSalt)}
              </code>
            </div>
          </div>

          <div className="action-buttons">
            <button type="button" onClick={calculateAddress} disabled={loading || !account} className="calc-btn">
              🔍 Calculate Address
            </button>
            <button type="button" onClick={compareFactories} disabled={loading || !account} className="compare-btn">
              🔄 Compare All Factories
            </button>
          </div>
        </div>
      )}

      {/* 地址显示 - 始终显示 */}
      <div className="card">
        <h3>🎯 Predicted Smart Account Address</h3>
        {predictedAddress && accountInfo ? (
          <div className="address-info">
            <p className="address-label">🔑 Your ERC-4337 Account:</p>
            <p className="predicted-address">{predictedAddress}</p>
            <div className="calculation-details">
              <p className="salt-used">🧂 Salt Used: <code>{getCurrentSalt()}</code></p>
              <p className="factory-used">🏭 Factory: {selectedFactory} ({currentNetwork?.factories?.[selectedFactory]?.address})</p>
              <p className="deployment-status">
                📦 Status: <span className={accountInfo.isDeployed ? 'deployed' : 'not-deployed'}>
                  {accountInfo.isDeployed ? '✅ Deployed' : '⏳ Not Deployed'}
                </span>
              </p>
              <p className="balance-info">💰 Balance: {accountInfo.balance} ETH</p>
              <p className="deposit-info">🏦 EntryPoint Deposit: {entryPointDeposit} ETH</p>
            </div>
            <p className="address-note">⚠️ This is your smart contract account address!</p>
            <a
              href={getExplorerUrl(predictedAddress, currentNetwork?.chainId)}
              target="_blank"
              rel="noopener noreferrer"
              className="etherscan-link"
            >
              📊 View Account on Explorer
            </a>
            {!accountInfo.isDeployed && (
              <button
                type="button"
                onClick={createAccount}
                disabled={loading}
                className="create-account-btn"
              >
                {loading ? '⏳ Creating...' : '🚀 Create Account'}
              </button>
            )}
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
      {predictedAddress && (
        <div className="card">
          <h3>💸 Fund Account</h3>
          <p>Transfer funds to your smart account address:</p>

          {/* PNTs转账 */}
          <div className="transfer-section">
            <h4>🪙 Transfer PNTs</h4>
            <p>Your PNTs Balance: <strong>{pntsBalance}</strong></p>
            <div className="transfer-form">
              <input
                type="number"
                value={pntsAmount}
                onChange={(e) => setPntsAmount(e.target.value)}
                placeholder="Amount"
                step="0.01"
              />
              <button
                type="button"
                onClick={() => transferToAccount('pnts')}
                disabled={loading || !pntsAmount}
              >
                Transfer PNTs
              </button>
            </div>
          </div>

          {/* ETH转账 */}
          <div className="transfer-section">
            <h4>💎 Transfer ETH</h4>
            <p>Your ETH Balance: <strong>{ethBalance}</strong></p>
            <div className="transfer-form">
              <input
                type="number"
                value={ethAmount}
                onChange={(e) => setEthAmount(e.target.value)}
                placeholder="Amount"
                step="0.001"
              />
              <button
                type="button"
                onClick={() => transferToAccount('eth')}
                disabled={loading || !ethAmount}
              >
                Transfer ETH
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 工厂比较结果 */}
      {showFactoryComparison && factoryComparison.length > 0 && (
        <div className="card">
          <h3>🔄 Factory Address Comparison</h3>
          <p>Different factories will generate different account addresses for the same owner and salt:</p>
          
          <div className="factory-comparison">
            {factoryComparison.map((result, index) => (
              <div key={index} className={`comparison-item ${result.success ? 'success' : 'error'}`}>
                <div className="factory-info">
                  <h4>{result.factoryName}</h4>
                  <span className="factory-type">({result.factoryType})</span>
                </div>
                
                {result.success ? (
                  <div className="address-result">
                    <p className="address">{result.address}</p>
                    <div className="address-actions">
                      <a
                        href={getExplorerUrl(result.address, currentNetwork?.chainId)}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="explorer-link"
                      >
                        📊 Explorer
                      </a>
                      <button
                        type="button"
                        onClick={() => setSelectedFactory(result.factoryType)}
                        className={`select-factory-btn ${selectedFactory === result.factoryType ? 'selected' : ''}`}
                      >
                        {selectedFactory === result.factoryType ? '✅ Selected' : 'Select'}
                      </button>
                    </div>
                  </div>
                ) : (
                  <div className="error-result">
                    <p className="error-message">❌ {result.error}</p>
                  </div>
                )}
              </div>
            ))}
          </div>
          
          <button 
            type="button" 
            onClick={() => setShowFactoryComparison(false)}
            className="close-comparison-btn"
          >
            Close Comparison
          </button>
        </div>
      )}

      {/* 状态消息 */}
      {message && <div className="message success">{message}</div>}
      {error && <div className="message error">{error}</div>}

      {/* 已创建账户列表 */}
      {createdAccounts.length > 0 && (
        <div className="card">
          <h3>📋 Created Accounts</h3>
          <div className="created-accounts">
            {createdAccounts.map((acc, index) => (
              <div key={index} className="account-item">
                <div className="account-info">
                  <p><strong>Address:</strong> {formatAddress(acc.address)}</p>
                  <p><strong>Network:</strong> {acc.network}</p>
                  <p><strong>Factory:</strong> {acc.factory}</p>
                  <p><strong>Created:</strong> {new Date(acc.createdAt).toLocaleDateString()}</p>
                </div>
                <div className="account-actions">
                  <a
                    href={getExplorerUrl(acc.address, acc.chainId)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="etherscan-link small"
                  >
                    📊 Explorer
                  </a>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* 页脚信息 */}
      <footer className='footer'>
        <div className="footer-content">
          <div className="footer-section">
            <h4>🔗 ERC-4337 Information</h4>
            <p>EntryPoint: {ENTRYPOINT_INFO.version}</p>
            <p>Address: {formatAddress(ENTRYPOINT_INFO.address)}</p>
            <p>💡 Using official Account Abstraction standard!</p>
          </div>
          <div className="footer-section">
            <h4>🌐 Supported Networks</h4>
            {getSupportedNetworks().map(network => (
              <p key={network.chainId}>{network.name}</p>
            ))}
          </div>
        </div>
      </footer>
    </div>
  );
}
