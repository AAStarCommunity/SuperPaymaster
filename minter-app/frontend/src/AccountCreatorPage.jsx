import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";
import { config } from "./config";
import {
  AA_NETWORKS,
  getNetworkConfig,
  getFactoryConfig,
  getSupportedNetworks,
  validateNetworkConfig,
  ENTRYPOINT_INFO,
} from "./config/aa-config.js";

// Use appropriate backend URL based on environment (same as NFT minter)
const backendUrl =
  window.location.hostname === "localhost"
    ? "http://localhost:3001" // Development: use local Express backend
    : ""; // Production: use same domain (Vercel API routes)

// Local utility functions
function generateRandomSalt() {
  return Math.floor(Math.random() * 1000000);
}

function normalizeSalt(salt) {
  return Number(salt) || 0;
}

function formatAddress(address) {
  if (!address || typeof address !== "string") return "";
  return `${address.substring(0, 6)}...${address.substring(address.length - 4)}`;
}

function getExplorerUrl(address, chainId, type = "address") {
  const network = getNetworkConfig(chainId);
  if (!network) return "#";

  if (type === "tx") {
    return `${network.blockExplorer}/tx/${address}`;
  } else {
    return `${network.blockExplorer}/address/${address}`;
  }
}

function getAvailableFactories(chainId) {
  const network = getNetworkConfig(chainId);
  if (!network || !network.factories) return [];

  return Object.entries(network.factories).map(([key, factory]) => ({
    key,
    ...factory,
  }));
}
import "./App.css";

// PNTs合约ABI (保持不变)
const PNTS_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address, uint256) returns (bool)",
];

export default function AccountCreatorPage({ account, provider, onBack }) {
  // 网络相关状态
  const [currentNetwork, setCurrentNetwork] = useState(null);
  const [selectedNetwork, setSelectedNetwork] = useState(11155111); // 默认Sepolia
  const [selectedFactory, setSelectedFactory] = useState("simple");

  // 地址和账户状态
  const [predictedAddress, setPredictedAddress] = useState("");
  const [accountInfo, setAccountInfo] = useState(null);
  const [entryPointDeposit, setEntryPointDeposit] = useState("0");

  // UI状态
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [txHash, setTxHash] = useState("");

  // Salt 相关状态 - 借鉴老版本完整功能
  const [customSalt, setCustomSalt] = useState("0");
  const [useRandomSalt, setUseRandomSalt] = useState(false);

  // 转账相关状态 - 借鉴老版本
  const [pntsAmount, setPntsAmount] = useState("100");
  const [ethAmount, setEthAmount] = useState("0.01");
  const [pntsBalance, setPntsBalance] = useState("0");
  const [ethBalance, setEthBalance] = useState("0");

  // 已创建账户列表 - 借鉴老版本
  const [createdAccounts, setCreatedAccounts] = useState([]);

  // 工厂比较功能
  const [showFactoryComparison, setShowFactoryComparison] = useState(false);
  const [factoryComparison, setFactoryComparison] = useState([]);

  // 工厂验证功能
  const [showFactoryValidation, setShowFactoryValidation] = useState(false);
  const [validationResults, setValidationResults] = useState([]);
  const [workingFactory, setWorkingFactory] = useState(null);

  // 获取当前网络信息
  useEffect(() => {
    async function detectNetwork() {
      if (!provider) return;

      try {
        const network = await provider.getNetwork();
        const chainId = Number(network.chainId);
        const networkConfig = getNetworkConfig(chainId);

        if (networkConfig) {
          setCurrentNetwork(networkConfig);
          setSelectedNetwork(chainId);
        } else {
          setError(
            `Unsupported network: ${chainId}. Please switch to Sepolia, OP Sepolia, Optimism, or Ethereum Mainnet.`,
          );
        }
      } catch (err) {
        console.error("Failed to detect network:", err);
        setError("Failed to detect network");
      }
    }

    detectNetwork();
  }, [provider]);

  // 余额获取功能 - 借鉴老版本
  const fetchBalances = useCallback(async () => {
    if (!account || !provider) return;

    try {
      console.log("🔍 [DEBUG] Fetching balances...");
      console.log("  Account:", account);
      console.log("  PNT Contract Address:", config.addresses.pnts);
      console.log("  Provider:", provider);

      // 获取PNTs余额
      const pntsContract = new ethers.Contract(
        config.addresses.pnts,
        PNTS_ABI,
        provider,
      );
      console.log("  PNT Contract created:", pntsContract.target);

      const pntsBal = await pntsContract.balanceOf(account);
      console.log("  Raw PNT Balance (wei):", pntsBal.toString());

      const formattedBalance = ethers.formatUnits(pntsBal, 18);
      console.log("  Formatted PNT Balance:", formattedBalance);
      setPntsBalance(formattedBalance);

      // 获取ETH余额
      const ethBal = await provider.getBalance(account);
      console.log("  ETH Balance:", ethers.formatEther(ethBal));
      setEthBalance(ethers.formatEther(ethBal));

      console.log("✅ [DEBUG] Balances fetched successfully");
    } catch (err) {
      console.error("❌ [DEBUG] Failed to fetch balances:", err);
      console.error("  Error details:", {
        message: err.message,
        code: err.code,
        data: err.data,
      });
    }
  }, [account, provider]);

  // 加载已创建账户 - 借鉴老版本
  const loadCreatedAccounts = useCallback(() => {
    try {
      const saved = localStorage.getItem("createdAccounts");
      if (saved) {
        setCreatedAccounts(JSON.parse(saved));
      }
    } catch (err) {
      console.error("Failed to load created accounts:", err);
    }
  }, []);

  useEffect(() => {
    if (account && provider) {
      fetchBalances();
      loadCreatedAccounts();
    }
  }, [account, provider, fetchBalances, loadCreatedAccounts]);

  // 保存创建的账户 - 借鉴老版本
  const saveCreatedAccount = (accountData) => {
    const updated = [...createdAccounts, accountData];
    setCreatedAccounts(updated);
    localStorage.setItem("createdAccounts", JSON.stringify(updated));
  };

  // Salt管理功能 - 借鉴老版本完整实现
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

  // 地址计算功能 - 整合新版本多工厂支持
  const calculateAddress = async () => {
    if (!account || !provider || !currentNetwork) {
      setError("Please connect wallet and ensure network is supported");
      return;
    }

    try {
      setLoading(true);
      setError("");

      // 验证网络和工厂配置
      const validation = validateNetworkConfig(
        currentNetwork.chainId,
        selectedFactory,
      );
      if (!validation.isValid) {
        setError(validation.error);
        return;
      }

      const salt = getCurrentSalt();
      console.log("=== Address Calculation ===");
      console.log("Network:", currentNetwork.name);
      console.log("Factory:", validation.factory.name);
      console.log("Owner:", account);
      console.log("Salt:", salt);

      // 使用backend API计算地址 (完全按照NFT minter模式)
      const response = await fetch(`${backendUrl}/calculateAccountAddress`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          owner: account,
          salt: salt,
          factoryAddress: validation.factory.address,
          factoryType: validation.factory.type || "simple",
        }),
      });

      // 检查响应状态和内容类型
      if (!response.ok) {
        const errorText = await response.text();
        console.error("API Error Response:", errorText);
        throw new Error(`API Error (${response.status}): ${errorText}`);
      }

      // 检查是否为JSON响应
      const contentType = response.headers.get("content-type");
      if (!contentType || !contentType.includes("application/json")) {
        const responseText = await response.text();
        console.error("Non-JSON Response:", responseText);
        throw new Error("Server returned non-JSON response");
      }

      const data = await response.json();

      const { predictedAddress } = data;
      setPredictedAddress(predictedAddress);
      setMessage(
        `✅ Address calculated successfully: ${predictedAddress.substring(0, 10)}...`,
      );

      console.log("=== Backend Calculation Result ===");
      console.log("Predicted Address:", predictedAddress);
    } catch (err) {
      setError("Address calculation failed: " + err.message);
      console.error("Address calculation error:", err);
    } finally {
      setLoading(false);
    }
  };

  // 测试所有工厂地址
  const testAllFactories = async () => {
    if (!account || !provider || !currentNetwork) {
      setError("Please connect wallet and ensure network is supported");
      return;
    }

    try {
      setLoading(true);
      setError("");
      setMessage("Testing all factory addresses...");

      const salt = getCurrentSalt();
      const results = await testFactoryAddresses(
        account,
        salt,
        currentNetwork.chainId,
        provider,
      );

      console.log("=== Factory Test Results ===");
      console.log(results);

      // Display results
      let resultMessage = "Factory Test Results:\n\n";
      for (const [name, result] of Object.entries(results)) {
        if (result.success) {
          resultMessage += `✅ ${name}:\n`;
          resultMessage += `  Address: ${result.address}\n`;
          resultMessage += `  Predicted: ${result.predictedAddress}\n`;
          resultMessage += `  Same as factory: ${result.isSameAsFactory ? "❌ YES (Problem!)" : "✅ NO (Good)"}\n\n`;
        } else {
          resultMessage += `❌ ${name}: ${result.error}\n\n`;
        }
      }

      setMessage(resultMessage);
    } catch (err) {
      setError("Factory testing failed: " + err.message);
      console.error("Factory testing error:", err);
    } finally {
      setLoading(false);
    }
  };

  // 比较不同工厂的地址
  const compareFactories = async () => {
    if (!account || !provider || !currentNetwork) {
      setError("Please connect wallet and ensure network is supported");
      return;
    }

    try {
      setLoading(true);
      setError("");

      const salt = getCurrentSalt();
      console.log("=== Factory Comparison ===");
      console.log("Owner:", account);
      console.log("Salt:", salt);

      const comparison = await compareFactoryAddresses(
        account,
        salt,
        currentNetwork.chainId,
        provider,
      );

      setFactoryComparison(comparison);
      setShowFactoryComparison(true);

      console.log("Factory Comparison Results:", comparison);
    } catch (err) {
      setError("Factory comparison failed: " + err.message);
      console.error("Factory comparison error:", err);
    } finally {
      setLoading(false);
    }
  };

  // 创建账户功能 - 借鉴老版本但增强错误处理
  const createAccount = async () => {
    if (!predictedAddress || !currentNetwork) {
      setError("Please calculate address first");
      return;
    }

    try {
      setLoading(true);
      setError("");
      setMessage("Creating account...");

      const factoryConfig = getFactoryConfig(
        currentNetwork.chainId,
        selectedFactory,
      );
      if (!factoryConfig) {
        setError(
          `Factory ${selectedFactory} not configured for ${currentNetwork.name}`,
        );
        return;
      }

      const signer = await provider.getSigner();
      const factoryContract = new ethers.Contract(
        factoryConfig.address,
        factoryConfig.abi,
        signer,
      );

      // 检查账户是否已存在
      const code = await provider.getCode(predictedAddress);
      if (code !== "0x") {
        setMessage("Account already exists!");
        return;
      }

      // 创建账户 - 使用当前salt
      const salt = getCurrentSalt();
      const saltBigInt = ethers.getBigInt(salt);

      console.log("Creating account with:", {
        owner: account,
        salt: salt,
        factory: factoryConfig.address,
      });

      const tx = await factoryContract.createAccount(account, saltBigInt, {
        gasLimit: 1000000,
      });

      setTxHash(tx.hash);
      setMessage(`Transaction submitted: ${tx.hash.substring(0, 10)}...`);

      // 等待交易确认
      const receipt = await tx.wait();
      if (receipt.status === 0) {
        throw new Error("Transaction failed");
      }

      setMessage(
        `✅ Account created successfully! Address: ${predictedAddress}`,
      );

      // 保存创建的账户
      const accountData = {
        address: predictedAddress,
        factory: selectedFactory,
        factoryName: factoryConfig.name,
        salt: salt,
        createdAt: new Date().toISOString(),
        txHash: tx.hash,
        owner: account,
        network: currentNetwork.shortName || currentNetwork.name.toLowerCase(),
      };
      saveCreatedAccount(accountData);
    } catch (err) {
      setError("Account creation failed: " + err.message);
      console.error("Account creation error:", err);
    } finally {
      setLoading(false);
    }
  };

  // 转账功能 - 借鉴老版本完整实现
  const transferToAccount = async (isPNTs = true) => {
    if (!account || !predictedAddress || !provider) {
      setError("Please create account first");
      return;
    }

    try {
      setLoading(true);
      setError("");
      setMessage(isPNTs ? "Transferring PNTs..." : "Transferring ETH...");

      const signer = await provider.getSigner();

      if (isPNTs) {
        // 转账PNTs
        const pntsContract = new ethers.Contract(
          config.addresses.pnts,
          PNTS_ABI,
          signer,
        );
        const amount = ethers.parseUnits(pntsAmount, 18);
        const tx = await pntsContract.transfer(predictedAddress, amount);
        await tx.wait();
        setMessage(`✅ Transferred ${pntsAmount} PNTs to account`);
      } else {
        // 转账ETH
        const amount = ethers.parseEther(ethAmount);
        const tx = await signer.sendTransaction({
          to: predictedAddress,
          value: amount,
        });
        await tx.wait();
        setMessage(`✅ Transferred ${ethAmount} ETH to account`);
      }

      // 刷新余额
      await fetchBalances();
    } catch (err) {
      setError(`Transfer failed: ${err.message}`);
    } finally {
      setLoading(false);
    }
  };

  // 获取当前网络支持的工厂
  const availableFactories = currentNetwork
    ? getAvailableFactories(currentNetwork.chainId)
    : [];

  return (
    <div className="App">
      <header className="App-header">
        <div>
          <h1>🚀 ERC-4337 Account Creator</h1>
          <div className="header-right">
            <button type="button" onClick={onBack} className="back-btn">
              ← Back to Main
            </button>
            {account && (
              <div className="account-info">
                <p>
                  Connected:{" "}
                  <span className="address">{formatAddress(account)}</span>
                </p>
              </div>
            )}
          </div>
        </div>
      </header>

      <div className="container">
        <div className="minting-column">
          {/* 网络信息 */}
          {currentNetwork && (
            <div className="card">
              <h3>🌐 Network Information</h3>
              <div className="network-info">
                <p>
                  <strong>Network:</strong> {currentNetwork.name}
                </p>
                <p>
                  <strong>Chain ID:</strong> {currentNetwork.chainId}
                </p>
                <p>
                  <strong>EntryPoint:</strong>{" "}
                  <code>{formatAddress(currentNetwork.entryPoint)}</code>
                </p>
                <p>
                  <strong>Supported Factories:</strong>{" "}
                  {availableFactories.length}
                </p>
              </div>
            </div>
          )}

          {/* 余额显示 - 借鉴老版本 */}
          <div className="card">
            <h3>💰 Your Balances</h3>
            <div className="balance-info">
              <p>
                PNTs: <strong>{pntsBalance}</strong>
              </p>
              <p>
                ETH: <strong>{ethBalance}</strong>
              </p>
            </div>
          </div>

          {/* 工厂选择 - 动态加载 */}
          {availableFactories.length > 0 && (
            <div className="card">
              <h3>🏭 Choose Factory</h3>
              <div className="factory-options">
                {availableFactories.map((factory) => (
                  <label
                    key={factory.key}
                    className={
                      selectedFactory === factory.key
                        ? "factory-option active"
                        : "factory-option"
                    }
                  >
                    <input
                      type="radio"
                      value={factory.key}
                      checked={selectedFactory === factory.key}
                      onChange={(e) => setSelectedFactory(e.target.value)}
                    />
                    <div className="option-content">
                      <span className="option-title">{factory.name}</span>
                      <span className="option-desc">
                        {formatAddress(factory.address)} • {factory.version}
                      </span>
                      <span className="option-desc-small">
                        {factory.description}
                      </span>
                    </div>
                  </label>
                ))}
              </div>

              {/* Salt 配置 - 借鉴老版本完整功能 */}
              <div className="salt-config">
                <h4>🔑 Salt Configuration</h4>
                <div className="salt-options">
                  <label className="salt-option">
                    <input
                      type="radio"
                      checked={!useRandomSalt}
                      onChange={() => {
                        setUseRandomSalt(false);
                        setCustomSalt("0");
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
                        setMessage(
                          `Random salt generated: ${randomSalt.toString().substring(0, 10)}...`,
                        );
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
                    {useRandomSalt
                      ? "随机生成 (每次计算时生成新值)"
                      : normalizeSalt(customSalt)}
                  </code>
                </div>
              </div>

              <div className="action-buttons">
                <button
                  type="button"
                  onClick={calculateAddress}
                  disabled={loading || !account}
                  className="calc-btn"
                >
                  🔍 Calculate Address
                </button>
              </div>
            </div>
          )}

          {/* 地址显示 - 始终显示 */}
          <div className="card">
            <h3>🎯 Predicted Smart Account Address</h3>
            {predictedAddress ? (
              <div className="address-info">
                <p className="address-label">🔑 Your ERC-4337 Account:</p>
                <p className="predicted-address">{predictedAddress}</p>

                {/* 账户信息显示 */}
                {accountInfo && (
                  <div className="account-details">
                    <p className="deployment-status">
                      Status:{" "}
                      <span
                        className={
                          accountInfo.isDeployed ? "deployed" : "not-deployed"
                        }
                      >
                        {accountInfo.isDeployed
                          ? "✅ Deployed"
                          : "⏳ Not Deployed"}
                      </span>
                    </p>
                    <p>
                      ETH Balance: <strong>{accountInfo.balance} ETH</strong>
                    </p>
                    <p>
                      EntryPoint Deposit:{" "}
                      <strong>{entryPointDeposit} ETH</strong>
                    </p>
                  </div>
                )}

                <div className="calculation-details">
                  <p className="salt-used">
                    🧂 Salt Used: <code>{getCurrentSalt()}</code>
                  </p>
                  <p className="factory-used">
                    🏭 Factory: {selectedFactory} (
                    {formatAddress(
                      availableFactories.find((f) => f.key === selectedFactory)
                        ?.address || "",
                    )}
                    )
                  </p>
                </div>

                <p className="address-note">
                  ⚠️ This is NOT the factory contract address!
                </p>
                <a
                  href={getExplorerUrl(
                    predictedAddress,
                    currentNetwork?.chainId,
                  )}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="etherscan-link"
                >
                  📊 View Smart Account on Explorer
                </a>
                <button
                  type="button"
                  onClick={createAccount}
                  disabled={loading}
                  className="create-account-btn"
                >
                  {loading ? "⏳ Creating..." : "🚀 Create Account"}
                </button>
              </div>
            ) : (
              <div className="address-placeholder">
                <p className="placeholder-text">
                  👆 Click "🔍 Calculate Address" to generate your smart account
                  address
                </p>
                <div className="placeholder-address">
                  <span className="placeholder-label">
                    Address will appear here...
                  </span>
                </div>
              </div>
            )}
          </div>

          {/* 工厂验证结果 */}
          {showFactoryValidation && validationResults.length > 0 && (
            <div className="card">
              <h3>🔧 Factory Address Validation Results</h3>
              <p>Testing known factory addresses on {currentNetwork?.name}:</p>

              <div className="validation-results">
                {validationResults.map((result, index) => (
                  <div
                    key={index}
                    className={`validation-item ${result.valid ? "success" : "error"}`}
                  >
                    <div className="factory-info">
                      <h4>{result.name}</h4>
                      <p className="address">{result.address}</p>
                    </div>

                    {result.valid ? (
                      <div className="validation-success">
                        <p className="status">✅ Valid Factory</p>
                        <p className="details">
                          Implementation: {formatAddress(result.implementation)}
                        </p>
                        <p className="details">
                          Test Address: {formatAddress(result.testAddress)}
                        </p>
                        <button
                          type="button"
                          onClick={() => {
                            // 使用这个有效的工厂地址更新配置
                            console.log(
                              `Using factory: ${result.name} at ${result.address}`,
                            );
                            setMessage(`Using factory: ${result.name}`);
                          }}
                          className="use-factory-btn"
                        >
                          Use This Factory
                        </button>
                      </div>
                    ) : (
                      <div className="validation-error">
                        <p className="status">❌ Invalid</p>
                        <p className="error-details">{result.error}</p>
                      </div>
                    )}
                  </div>
                ))}
              </div>

              {workingFactory && (
                <div className="recommended-factory">
                  <h4>🎯 Recommended Factory</h4>
                  <p>
                    <strong>{workingFactory.name}</strong>
                  </p>
                  <p>
                    <code>{workingFactory.address}</code>
                  </p>
                </div>
              )}

              <button
                type="button"
                onClick={() => setShowFactoryValidation(false)}
                className="close-validation-btn"
              >
                Close Validation
              </button>
            </div>
          )}

          {/* 工厂比较结果 */}
          {showFactoryComparison && factoryComparison.length > 0 && (
            <div className="card">
              <h3>🔄 Factory Address Comparison</h3>
              <p>
                Different factories will generate different account addresses
                for the same owner and salt:
              </p>

              <div className="factory-comparison">
                {factoryComparison.map((result, index) => (
                  <div
                    key={index}
                    className={`comparison-item ${result.success ? "success" : "error"}`}
                  >
                    <div className="factory-info">
                      <h4>{result.factoryName}</h4>
                      <span className="factory-type">
                        ({result.factoryType})
                      </span>
                    </div>

                    {result.success ? (
                      <div className="address-result">
                        <p className="address">{result.address}</p>
                        <div className="address-actions">
                          <a
                            href={getExplorerUrl(
                              result.address,
                              currentNetwork?.chainId,
                            )}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="explorer-link"
                          >
                            📊 Explorer
                          </a>
                          <button
                            type="button"
                            onClick={() =>
                              setSelectedFactory(result.factoryType)
                            }
                            className={`select-factory-btn ${selectedFactory === result.factoryType ? "selected" : ""}`}
                          >
                            {selectedFactory === result.factoryType
                              ? "✅ Selected"
                              : "Select"}
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

          {/* 转账功能 - 借鉴老版本 */}
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
                href={getExplorerUrl(txHash, currentNetwork?.chainId, "tx")}
                target="_blank"
                rel="noopener noreferrer"
                className="tx-link"
              >
                🔗 View Transaction on Explorer
              </a>
            </div>
          )}

          {/* 状态消息 */}
          {message && <div className="message success">{message}</div>}
          {error && <div className="message error">{error}</div>}
        </div>

        {/* 右侧列 - 已创建账户列表 */}
        <div className="collection-column">
          <h2 className="collection-header">📋 Created Accounts</h2>

          <div className="card collection-card">
            <h3>🏦 Your ERC-4337 Accounts ({createdAccounts.length})</h3>
            <div className="accounts-list">
              {createdAccounts.length > 0 ? (
                createdAccounts.map((acc, index) => (
                  <div
                    key={`account-${acc.address}-${index}`}
                    className="account-item"
                  >
                    <div className="account-info">
                      <p className="account-address">{acc.address}</p>
                      <p className="account-details">
                        {acc.factoryName} • Salt: {acc.salt} •{" "}
                        {new Date(acc.createdAt).toLocaleDateString()}
                      </p>
                    </div>
                    <div className="account-actions">
                      <a
                        href={getExplorerUrl(
                          acc.address,
                          currentNetwork?.chainId,
                        )}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="action-link"
                        title="View Account"
                      >
                        📊
                      </a>
                      <a
                        href={getExplorerUrl(
                          acc.txHash,
                          currentNetwork?.chainId,
                          "tx",
                        )}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="action-link"
                        title="View Creation Transaction"
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

      <footer className="footer">
        <div className="footer-content">
          <div className="footer-section">
            <h4>🏭 Factory Contracts (For Reference)</h4>
            {availableFactories.slice(0, 2).map((factory) => (
              <p key={factory.key}>
                {factory.name}: <code>{formatAddress(factory.address)}</code>
              </p>
            ))}
            <p className="factory-note">
              💡 These are factory contracts, not your smart accounts!
            </p>
          </div>
          <div className="footer-section">
            <h4>🔗 Network</h4>
            <p>{currentNetwork?.name || "Unknown Network"}</p>
            <p>ERC-4337 Compatible</p>
          </div>
          <div className="footer-section">
            <h4>ℹ️ Info</h4>
            <p>Account Creation Tool</p>
            <p>Version: 2.0 (Multi-Factory)</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
