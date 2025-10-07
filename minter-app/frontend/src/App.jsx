import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";
import { config } from "./config";
import "./App.css";
import AccountCreatorPage from "./AccountCreatorPage";
import NetworkTest from "./NetworkTest";

// Use appropriate backend URL based on environment
const backendUrl =
  window.location.hostname === "localhost"
    ? "http://localhost:3001" // Development: use local Express backend
    : ""; // Production: use same domain (Vercel API routes)

function App() {
  const [currentPage, setCurrentPage] = useState("main"); // 'main', 'account-creator', or 'network-test'
  const [account, setAccount] = useState(null);
  const [provider, setProvider] = useState(null);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const [mintType, setMintType] = useState("nft");
  const [nfts, setNfts] = useState([]);
  const [sbts, setSbts] = useState([]);

  const [pntsBalance, setPntsBalance] = useState("0");
  const [pntsAmount, setPntsAmount] = useState("100");

  // Owner mode states
  const [isOwner, setIsOwner] = useState(false);
  const [mintMode, setMintMode] = useState("self"); // 'self' or 'distribute'
  const [recipientAddress, setRecipientAddress] = useState("");
  const [displayAddress, setDisplayAddress] = useState(null); // For showing balances

  // Debug: Print config on mount
  useEffect(() => {
    console.log("🔧 [DEBUG] App mounted with config:", {
      pnts_address: config.addresses.pnts,
      gasTokenFactory: config.addresses.gasTokenFactory,
      pnts_abi_length: config.abis.pnts?.length,
      owner: config.OWNER_ADDRESS,
    });
  }, []);

  // Debug: Check network when provider changes
  useEffect(() => {
    const checkNetwork = async () => {
      if (provider) {
        const network = await provider.getNetwork();
        console.log("🌐 [DEBUG] Connected Network:", {
          name: network.name,
          chainId: network.chainId.toString(),
          expectedChainId: "11155111 (Sepolia)",
        });
        if (network.chainId.toString() !== "11155111") {
          console.error(
            "❌ [DEBUG] Wrong network! Please switch to Sepolia testnet",
          );
          setError(
            "⚠️ Wrong network! Please switch MetaMask to Sepolia testnet",
          );
        } else {
          console.log("✅ [DEBUG] Correct network (Sepolia)");
        }
      }
    };
    checkNetwork();
  }, [provider]);

  const connectWallet = async () => {
    // Check if MetaMask is installed
    if (typeof window.ethereum === "undefined") {
      return setError(
        "MetaMask is not installed! Please install MetaMask extension.",
      );
    }

    // Check if MetaMask is accessible
    if (!window.ethereum.isMetaMask) {
      return setError(
        "MetaMask is not properly initialized. Please refresh the page.",
      );
    }

    try {
      setError(""); // Clear any previous errors

      // Request account access
      const accounts = await window.ethereum.request({
        method: "eth_requestAccounts",
      });

      if (accounts.length === 0) {
        return setError("No accounts found. Please unlock MetaMask.");
      }

      const web3Provider = new ethers.BrowserProvider(window.ethereum);
      setProvider(web3Provider);

      const network = await web3Provider.getNetwork();
      console.log(
        "Connected to network:",
        network.name,
        "Chain ID:",
        network.chainId,
      );

      const connectedAccount = accounts[0];
      setAccount(connectedAccount);

      // Check if connected account is owner
      const isOwnerAccount =
        connectedAccount.toLowerCase() === config.OWNER_ADDRESS.toLowerCase();
      setIsOwner(isOwnerAccount);

      // Set display address based on mode
      setDisplayAddress(connectedAccount);

      console.log("Wallet connected, account:", connectedAccount);
      console.log("Is owner:", isOwnerAccount);

      // Save to localStorage for auto-reconnect
      localStorage.setItem("walletConnected", "true");
    } catch (err) {
      console.error("Wallet connection error:", err);

      // Handle specific error cases
      if (err.code === 4001) {
        setError("Connection rejected by user.");
      } else if (err.code === -32002) {
        setError("Connection request already pending. Please check MetaMask.");
      } else {
        setError(`Failed to connect wallet: ${err.message}`);
      }
    }
  };

  const fetchNfts = useCallback(
    async (type, setter, retries = 3, forceRefresh = false) => {
      if (!displayAddress || !provider) return;
      const address = config.addresses[type];
      const abi = config.abis[type];
      console.log(
        `Fetching ${type}s from contract:`,
        address,
        forceRefresh ? "(force refresh)" : "",
      );
      if (!ethers.isAddress(address) || address.includes("YOUR")) return;

      try {
        const contract = new ethers.Contract(address, abi, provider);
        const balance = await contract.balanceOf(displayAddress);
        console.log(`${type} balance:`, balance.toString());

        // Retry if we're expecting a change (forceRefresh) but haven't seen it yet
        if (forceRefresh && retries > 0) {
          console.log(`Force refreshing ${type}s, ${retries} retries left...`);
          setTimeout(() => fetchNfts(type, setter, retries - 1, true), 2000);
        }

        // For basic ERC721 contracts without enumerable extension
        // We'll show the balance count but can't list individual tokens
        // since the contract doesn't have tokenOfOwnerByIndex
        const items = [];
        const balanceNum = parseInt(balance.toString());

        // Create placeholder items based on balance
        for (let i = 0; i < balanceNum; i++) {
          items.push({
            tokenId: `${i}`, // This is a placeholder, actual token IDs may be different
            placeholder: true,
          });
        }

        console.log(`Found ${items.length} ${type}s, updating state.`);
        setter(items);
      } catch (err) {
        console.error(`Failed to fetch ${type}s:`, err);
        setError(
          `Failed to fetch ${type.toUpperCase()}s. See console for details.`,
        );
      }
    },
    [displayAddress, provider],
  );

  const fetchPntsBalance = useCallback(
    async (retries = 3, expectedBalance = null) => {
      if (!displayAddress || !provider) return;
      const address = config.addresses.pnts;
      const abi = config.abis.pnts;

      console.log("🔍 [DEBUG] Fetching PNTs balance...");
      console.log("  Display Address:", displayAddress);
      console.log("  PNT Contract:", address);
      console.log("  Provider:", provider);

      if (!ethers.isAddress(address) || address.includes("YOUR")) {
        console.error("❌ [DEBUG] Invalid contract address:", address);
        return;
      }

      try {
        const contract = new ethers.Contract(address, abi, provider);
        console.log("  Contract Target:", contract.target);

        const balance = await contract.balanceOf(displayAddress);
        console.log("  Raw Balance (wei):", balance.toString());

        const formattedBalance = ethers.formatUnits(balance, 18);
        console.log("  Formatted Balance:", formattedBalance, "PNT");

        // If we're expecting a specific balance and haven't reached it yet, keep retrying
        if (
          expectedBalance &&
          formattedBalance === pntsBalance &&
          retries > 0
        ) {
          console.log(
            `  Balance hasn't updated yet, retrying... ${retries} retries left`,
          );
          setTimeout(
            () => fetchPntsBalance(retries - 1, expectedBalance),
            2500,
          );
          return;
        }

        console.log("✅ [DEBUG] Setting PNT balance to:", formattedBalance);
        setPntsBalance(formattedBalance);
      } catch (err) {
        console.error("❌ [DEBUG] Failed to fetch PNTs balance:", err);
        console.error("  Error details:", {
          message: err.message,
          code: err.code,
          data: err.data,
        });
        setError("Failed to fetch PNTs balance. See console for details.");
      }
    },
    [displayAddress, provider, pntsBalance],
  );

  const handleMint = async (isPNTs = false) => {
    if (!account || !provider)
      return setError("Please connect your wallet first.");

    // Determine target address
    let targetAddress = account;
    if (isOwner && mintMode === "distribute") {
      if (!recipientAddress || !ethers.isAddress(recipientAddress)) {
        return setError("Please enter a valid recipient address.");
      }
      targetAddress = recipientAddress;
    }

    let endpoint = "";
    let body = {};
    let successMessage = "";
    let fetchFunction = null;

    // Use appropriate endpoints based on environment
    const isLocalDev = window.location.hostname === "localhost";

    if (isPNTs) {
      if (!pntsAmount || parseFloat(pntsAmount) <= 0) {
        return setError("Please enter a valid amount.");
      }
      endpoint = isLocalDev ? "/mintPNTs" : "/api/mint/pnts";
      body = { userAddress: targetAddress, amount: pntsAmount };
      successMessage = `${pntsAmount} PNTs minted to ${targetAddress === account ? "you" : targetAddress.substring(0, 6) + "..."}`;
      fetchFunction = fetchPntsBalance;
    } else {
      endpoint = isLocalDev
        ? mintType === "nft"
          ? "/mintNFT"
          : "/mintSBT"
        : mintType === "nft"
          ? "/api/mint/nft"
          : "/api/mint/sbt";
      body = { userAddress: targetAddress };
      successMessage = `${mintType.toUpperCase()} minted to ${targetAddress === account ? "you" : targetAddress.substring(0, 6) + "..."}`;
      fetchFunction = () =>
        fetchNfts(mintType, mintType === "nft" ? setNfts : setSbts);
    }

    setLoading(true);
    setMessage("");
    setError("");

    try {
      const response = await fetch(`${backendUrl}${endpoint}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.details || "Minting failed.");

      const { txHash } = data;
      const explorerUrl = `https://sepolia.etherscan.io/tx/${txHash}`;
      setMessage(
        <span>
          Transaction sent! Waiting for confirmation... <br />
          <a
            href={explorerUrl}
            target="_blank"
            rel="noopener noreferrer"
            style={{ color: "#007bff", textDecoration: "underline" }}
          >
            {txHash.substring(0, 10)}...{txHash.substring(txHash.length - 8)}
          </a>
        </span>,
      );

      const receipt = await provider.waitForTransaction(txHash, 1);

      if (receipt.status === 0) {
        throw new Error(`Transaction failed. Tx: ${txHash}`);
      }

      setMessage(
        <span>
          Success! {successMessage} <br />
          <a
            href={explorerUrl}
            target="_blank"
            rel="noopener noreferrer"
            style={{ color: "#007bff", textDecoration: "underline" }}
          >
            View on Etherscan: {txHash.substring(0, 10)}...
            {txHash.substring(txHash.length - 8)}
          </a>
        </span>,
      );
      console.log("Transaction successful, preparing to refresh data...");

      // Force multiple refresh attempts to catch slow RPC updates
      const refreshData = async () => {
        console.log("Starting aggressive data refresh...");

        // Immediate refresh
        fetchFunction();

        // Additional refreshes with delays to catch slow RPC updates
        setTimeout(() => {
          console.log("Refresh attempt 2...");
          if (isPNTs) {
            fetchPntsBalance(5, true);
          } else {
            fetchNfts(
              mintType,
              mintType === "nft" ? setNfts : setSbts,
              5,
              true,
            );
          }
        }, 2000);

        setTimeout(() => {
          console.log("Refresh attempt 3...");
          fetchFunction();
        }, 5000);

        setTimeout(() => {
          console.log("Final refresh attempt...");
          fetchFunction();
        }, 10000);
      };

      refreshData();
    } catch (err) {
      setError(err.message);
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleAddressCheck = async () => {
    if (!recipientAddress || !ethers.isAddress(recipientAddress)) {
      setError("Please enter a valid Ethereum address.");
      return;
    }
    setDisplayAddress(recipientAddress);
    setMessage(
      `Now viewing balances for: ${recipientAddress.substring(0, 6)}...`,
    );
  };

  const switchToSelfView = () => {
    setDisplayAddress(account);
    setRecipientAddress("");
    setMessage("Switched back to your own balances.");
  };

  // Auto-reconnect wallet on page load
  useEffect(() => {
    const autoConnect = async () => {
      if (
        localStorage.getItem("walletConnected") === "true" &&
        typeof window.ethereum !== "undefined" &&
        window.ethereum.isMetaMask
      ) {
        try {
          // Check if already connected
          const accounts = await window.ethereum.request({
            method: "eth_accounts",
          });

          if (accounts.length > 0) {
            const web3Provider = new ethers.BrowserProvider(window.ethereum);
            setProvider(web3Provider);
            const connectedAccount = accounts[0];
            setAccount(connectedAccount);
            setDisplayAddress(connectedAccount);
            const isOwnerAccount =
              connectedAccount.toLowerCase() ===
              config.OWNER_ADDRESS.toLowerCase();
            setIsOwner(isOwnerAccount);
            console.log("Auto-reconnected wallet:", connectedAccount);
          } else {
            // Clear stored connection if no accounts
            localStorage.removeItem("walletConnected");
          }
        } catch (err) {
          console.error("Auto-connect failed:", err);
          localStorage.removeItem("walletConnected");
        }
      }
    };

    // Wait for MetaMask to be ready
    if (typeof window.ethereum !== "undefined") {
      autoConnect();
    } else {
      // Wait for MetaMask to load
      const checkMetaMask = setInterval(() => {
        if (typeof window.ethereum !== "undefined") {
          clearInterval(checkMetaMask);
          autoConnect();
        }
      }, 100);

      // Stop checking after 5 seconds
      setTimeout(() => clearInterval(checkMetaMask), 5000);
    }

    // Listen for account changes
    if (window.ethereum) {
      window.ethereum.on("accountsChanged", (accounts) => {
        if (accounts.length === 0) {
          // User disconnected wallet
          setAccount(null);
          setDisplayAddress(null);
          setProvider(null);
          localStorage.removeItem("walletConnected");
        } else {
          // User switched accounts
          const newAccount = accounts[0];
          setAccount(newAccount);
          setDisplayAddress(newAccount);
          const isOwnerAccount =
            newAccount.toLowerCase() === config.OWNER_ADDRESS.toLowerCase();
          setIsOwner(isOwnerAccount);
          console.log("Account changed to:", newAccount);
        }
      });
    }
  }, []);

  useEffect(() => {
    if (displayAddress && provider) {
      console.log(
        "useEffect triggered, fetching data for address:",
        displayAddress,
      );
      fetchNfts("nft", setNfts, 3, false);
      fetchNfts("sbt", setSbts, 3, false);
      fetchPntsBalance(3, null);
    }
  }, [displayAddress, provider, fetchNfts, fetchPntsBalance]);

  // 如果是账户创建页面，显示AccountCreatorPage
  if (currentPage === "account-creator") {
    return (
      <AccountCreatorPage
        account={account}
        provider={provider}
        onBack={() => setCurrentPage("main")}
      />
    );
  }

  // 如果是网络测试页面，显示NetworkTest
  if (currentPage === "network-test") {
    return (
      <div>
        <button
          type="button"
          onClick={() => setCurrentPage("main")}
          style={{ margin: "10px" }}
        >
          ← Back to Main
        </button>
        <NetworkTest />
      </div>
    );
  }

  // 主页面
  return (
    <div className="App">
      <header className="App-header">
        <div>
          <h1>🚀 Gemini Minter DApp</h1>
          <div className="header-right">
            <nav className="page-nav">
              <button
                type="button"
                className={
                  currentPage === "main" ? "nav-btn active" : "nav-btn"
                }
                onClick={() => setCurrentPage("main")}
              >
                Main
              </button>
              <button
                type="button"
                className={
                  currentPage === "account-creator"
                    ? "nav-btn active"
                    : "nav-btn"
                }
                onClick={() => setCurrentPage("account-creator")}
              >
                Account Creator
              </button>
            </nav>
            {account ? (
              <div className="account-info">
                <p>
                  Connected:{" "}
                  <span className="address">{`${account.substring(0, 6)}...${account.substring(account.length - 4)}`}</span>
                </p>
                {isOwner && <span className="owner-badge">👑 Owner</span>}
              </div>
            ) : (
              <button
                type="button"
                onClick={connectWallet}
                className="connect-btn"
              >
                Connect Wallet
              </button>
            )}
          </div>
        </div>
      </header>

      <div className="container">
        <div className="minting-column">
          {message && <div className="message-banner">{message}</div>}
          {error && <div className="error-banner">{error}</div>}

          {/* Owner Mode Selector */}
          {isOwner && (
            <div className="card owner-card">
              <h3>🎯 Minting Mode</h3>
              <div className="mode-selector">
                <label className={mintMode === "self" ? "active" : ""}>
                  <input
                    type="radio"
                    value="self"
                    checked={mintMode === "self"}
                    onChange={() => {
                      setMintMode("self");
                      setDisplayAddress(account);
                      setRecipientAddress("");
                    }}
                  />
                  <span>Mint to Myself</span>
                </label>
                <label className={mintMode === "distribute" ? "active" : ""}>
                  <input
                    type="radio"
                    value="distribute"
                    checked={mintMode === "distribute"}
                    onChange={() => setMintMode("distribute")}
                  />
                  <span>Distribute to Others</span>
                </label>
              </div>

              {mintMode === "distribute" && (
                <div className="recipient-input">
                  <input
                    type="text"
                    value={recipientAddress}
                    onChange={(e) => setRecipientAddress(e.target.value)}
                    placeholder="Enter recipient address (0x...)"
                    className="address-input"
                  />
                  <div className="button-group">
                    <button
                      type="button"
                      onClick={handleAddressCheck}
                      className="check-btn"
                    >
                      Check Balance
                    </button>
                    {displayAddress !== account && (
                      <button
                        type="button"
                        onClick={switchToSelfView}
                        className="switch-btn"
                      >
                        Back to My View
                      </button>
                    )}
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="card">
            <h3>💰 Mint ERC20 Tokens (PNTs)</h3>
            <p className="balance-display">
              {displayAddress === account
                ? "Your"
                : `${displayAddress?.substring(0, 6)}...'s`}{" "}
              Balance:
              <strong className="balance-value">{pntsBalance} PNTs</strong>
              <br />
              <small style={{ color: "#666", fontSize: "0.8em" }}>
                Contract: {config.addresses.pnts?.substring(0, 10)}...
                {config.addresses.pnts?.substring(
                  config.addresses.pnts.length - 6,
                )}
              </small>
            </p>
            <div className="mint-form">
              <input
                type="number"
                value={pntsAmount}
                onChange={(e) => setPntsAmount(e.target.value)}
                placeholder="Amount of PNTs"
              />
              <button
                type="button"
                onClick={() => handleMint(true)}
                disabled={loading || !account}
              >
                {loading
                  ? "Minting..."
                  : isOwner && mintMode === "distribute"
                    ? `Send PNTs`
                    : "Get Free PNTs"}
              </button>
            </div>
          </div>

          <div className="card">
            <h3>🎨 Mint NFT / SBT</h3>
            <p className="subtitle">Choose the type of token to mint</p>
            <div className="mint-options">
              <label
                className={
                  mintType === "nft" ? "token-option active" : "token-option"
                }
              >
                <input
                  type="radio"
                  value="nft"
                  checked={mintType === "nft"}
                  onChange={() => setMintType("nft")}
                />
                <div className="option-content">
                  <span className="option-title">🖼️ Regular NFT</span>
                  <span className="option-desc">Transferable</span>
                </div>
              </label>
              <label
                className={
                  mintType === "sbt" ? "token-option active" : "token-option"
                }
              >
                <input
                  type="radio"
                  value="sbt"
                  checked={mintType === "sbt"}
                  onChange={() => setMintType("sbt")}
                />
                <div className="option-content">
                  <span className="option-title">🔒 Soul-Bound Token</span>
                  <span className="option-desc">Non-Transferable</span>
                </div>
              </label>
            </div>
            <button
              type="button"
              onClick={() => handleMint(false)}
              disabled={loading || !account}
              className="mint-btn"
            >
              {loading
                ? "Minting..."
                : isOwner && mintMode === "distribute"
                  ? `Send ${mintType.toUpperCase()}`
                  : `Mint ${mintType.toUpperCase()}`}
            </button>
          </div>
        </div>

        <div className="collection-column">
          <h2 className="collection-header">
            {displayAddress === account
              ? "📦 My Collection"
              : `📦 Collection of ${displayAddress?.substring(0, 6)}...${displayAddress?.substring(displayAddress.length - 4)}`}
            <button
              type="button"
              onClick={() => {
                console.log("Manual refresh triggered for:", displayAddress);
                fetchNfts("nft", setNfts, 3, false);
                fetchNfts("sbt", setSbts, 3, false);
                fetchPntsBalance(3, null);
              }}
              style={{ marginLeft: "10px", fontSize: "0.6em" }}
            >
              🔄 Refresh
            </button>
          </h2>

          <div className="card collection-card">
            <h3>🖼️ NFTs ({nfts.length})</h3>
            <div className="nft-gallery">
              {nfts.length > 0 ? (
                nfts.map((nft, index) => (
                  <div key={`nft-${nft.tokenId}-${index}`} className="nft-item">
                    <div className="nft-image-placeholder">
                      <span className="token-id">NFT</span>
                    </div>
                    <p className="nft-label">NFT Token</p>
                  </div>
                ))
              ) : (
                <p className="empty-text">No NFTs yet</p>
              )}
            </div>
          </div>

          <div className="card collection-card">
            <h3>🔒 Soul-Bound Tokens ({sbts.length})</h3>
            <div className="nft-gallery">
              {sbts.length > 0 ? (
                sbts.map((sbt, index) => (
                  <div
                    key={`sbt-${sbt.tokenId}-${index}`}
                    className="nft-item sbt-item"
                  >
                    <div className="nft-image-placeholder sbt-placeholder">
                      <span className="token-id">SBT</span>
                    </div>
                    <p className="nft-label">SBT Token</p>
                  </div>
                ))
              ) : (
                <p className="empty-text">No SBTs yet</p>
              )}
            </div>
          </div>
        </div>
      </div>

      <footer className="footer">
        <div className="footer-content">
          <div className="footer-section">
            <h4>📜 Smart Contracts</h4>
            <p>
              NFT:{" "}
              <a
                href={`https://sepolia.etherscan.io/address/${config.addresses.nft}`}
                target="_blank"
                rel="noopener noreferrer"
              >
                <code>{config.addresses.nft.substring(0, 10)}...</code>
              </a>
            </p>
            <p>
              SBT:{" "}
              <a
                href={`https://sepolia.etherscan.io/address/${config.addresses.sbt}`}
                target="_blank"
                rel="noopener noreferrer"
              >
                <code>{config.addresses.sbt.substring(0, 10)}...</code>
              </a>
            </p>
            <p>
              PNTs:{" "}
              <a
                href={`https://sepolia.etherscan.io/address/${config.addresses.pnts}`}
                target="_blank"
                rel="noopener noreferrer"
              >
                <code>{config.addresses.pnts.substring(0, 10)}...</code>
              </a>
            </p>
          </div>
          <div className="footer-section">
            <h4>🔗 Network</h4>
            <p>Ethereum Sepolia Testnet</p>
            <p>Gas Sponsored ✅</p>
          </div>
          <div className="footer-section">
            <h4>ℹ️ Info</h4>
            <p>
              Owner:{" "}
              <a
                href={`https://sepolia.etherscan.io/address/${config.OWNER_ADDRESS}`}
                target="_blank"
                rel="noopener noreferrer"
              >
                <code>{config.OWNER_ADDRESS.substring(0, 10)}...</code>
              </a>
            </p>
            <p>Version: 2.3</p>
          </div>
        </div>
      </footer>
    </div>
  );
}

export default App;
