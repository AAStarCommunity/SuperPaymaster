require('dotenv').config({ path: __dirname + '/.env' });
const express = require('express');
const { ethers } = require('ethers');
const cors = require('cors');

const app = express();
const port = 3001;

// --- CONFIGURATION ---
const alchemyRpcUrl = process.env.ALCHEMY_RPC_URL;
const serverPrivateKey = process.env.SEPOLIA_PRIVATE_KEY;

const nftContractAddress = process.env.NFT_CONTRACT_ADDRESS;
const sbtContractAddress = process.env.SBT_CONTRACT_ADDRESS;
const pntsContractAddress = process.env.PNTS_CONTRACT_ADDRESS;

const nftABI = [ "function safeMint(address to)" ];
const sbtABI = [ "function safeMint(address to)" ];
const pntsABI = [ "function mint(address to, uint256 amount)" ];

if (!alchemyRpcUrl || !serverPrivateKey || !nftContractAddress || !sbtContractAddress || !pntsContractAddress) {
    throw new Error("Missing one or more environment variables.");
}

// --- PROVIDER & SIGNER ---
const provider = new ethers.JsonRpcProvider(alchemyRpcUrl);
const wallet = new ethers.Wallet(serverPrivateKey, provider);
console.log(`Server wallet address: ${wallet.address}`);

// --- CONTRACT INSTANCES ---
const nftContract = new ethers.Contract(nftContractAddress, nftABI, wallet);
const sbtContract = new ethers.Contract(sbtContractAddress, sbtABI, wallet);
const pntsContract = new ethers.Contract(pntsContractAddress, pntsABI, wallet);

// --- MIDDLEWARE ---
app.use(cors());
app.use(express.json());

// --- GENERIC MINT FUNCTION ---
const handleMint = async (contract, mintFunction, args, res) => {
    try {
        console.log(`Minting request received for ${contract.target} with function ${mintFunction}`);
        const txResponse = await contract[mintFunction](...args, { gasLimit: 300000 });
        console.log(`Transaction sent! Hash: ${txResponse.hash}`);
        res.status(200).json({ txHash: txResponse.hash });
    } catch (error) {
        console.error('--- Minting Error ---');
        console.error(`Contract: ${contract.target}`);
        console.error(`Function: ${mintFunction}`);
        console.error(`Arguments: ${JSON.stringify(args)}`);
        console.error(error);
        console.error('--- End Minting Error ---');
        res.status(500).json({ 
            error: 'Failed to send minting transaction.', 
            details: error.reason || error.message 
        });
    }
};

// --- ROUTES ---
app.post('/mintNFT', (req, res) => {
    const { userAddress } = req.body;
    if (!ethers.isAddress(userAddress)) return res.status(400).json({ error: 'Invalid user address.' });
    handleMint(nftContract, 'safeMint', [userAddress], res);
});

app.post('/mintSBT', (req, res) => {
    const { userAddress } = req.body;
    if (!ethers.isAddress(userAddress)) return res.status(400).json({ error: 'Invalid user address.' });
    handleMint(sbtContract, 'safeMint', [userAddress], res);
});

app.post('/mintPNTs', (req, res) => {
    const { userAddress, amount } = req.body;
    if (!ethers.isAddress(userAddress)) return res.status(400).json({ error: 'Invalid user address.' });
    try {
        const amountWei = ethers.parseUnits(amount.toString(), 18);
        handleMint(pntsContract, 'mint', [userAddress, amountWei], res);
    } catch (e) {
        res.status(400).json({ error: 'Invalid amount.' });
    }
});

// --- CALCULATE ACCOUNT ADDRESS ---
app.post('/calculateAccountAddress', async (req, res) => {
    const { owner, salt, factoryAddress, factoryType = 'simple' } = req.body;
    
    try {
        console.log(`Calculate account address request: owner=${owner}, salt=${salt}, factory=${factoryAddress}, type=${factoryType}`);
        
        let predictedAddress;

        if (factoryType === 'simple') {
            // Use getCalculatedAddress for our working factory (avoids ethers.js bug)
            const factoryAbi = [
                "function getCalculatedAddress(address owner, uint256 salt) view returns (address)",
                "function accountImplementation() view returns (address)"
            ];

            const factoryContract = new ethers.Contract(factoryAddress, factoryAbi, provider);
            predictedAddress = await factoryContract.getCalculatedAddress(owner, salt);
        } else {
            // For official/alchemy factories, use raw call to avoid ethers.js Contract bug
            console.log('Using raw Interface call for official factory');
            
            const factoryInterface = new ethers.Interface([
                "function getAddress(address owner, uint256 salt) view returns (address)"
            ]);

            // Encode the function call
            const callData = factoryInterface.encodeFunctionData('getAddress', [owner, salt]);
            console.log('Encoded call data:', callData);

            // Make raw call
            const rawResult = await provider.call({
                to: factoryAddress,
                data: callData
            });
            console.log('Raw result:', rawResult);

            // Decode the result
            const decodedResult = factoryInterface.decodeFunctionResult('getAddress', rawResult);
            predictedAddress = decodedResult[0];
        }
        
        console.log(`Address calculated: ${predictedAddress}`);
        res.status(200).json({ predictedAddress });
        
    } catch (error) {
        console.error('Calculate address error:', error);
        res.status(500).json({ 
            error: 'Failed to calculate address',
            details: error.reason || error.message 
        });
    }
});

app.listen(port, () => {
    console.log(`Backend server listening at http://localhost:${port}`);
});