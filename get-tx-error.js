require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  
  const txHash = "0x80ad02154d0b27690c11c66f8d6547abef9cae6e9951ad2d0b21a937bfcaa1cc";
  
  console.log("=== Getting Transaction Error Details ===\n");
  
  // Get transaction receipt
  const receipt = await provider.getTransactionReceipt(txHash);
  console.log("Transaction Status:", receipt.status === 1 ? "Success" : "Failed");
  console.log("Gas Used:", receipt.gasUsed.toString());
  console.log("Block Number:", receipt.blockNumber);
  
  // Get transaction
  const tx = await provider.getTransaction(txHash);
  
  // Try to replay the transaction to get revert reason
  try {
    console.log("\nReplaying transaction to get revert reason...");
    const result = await provider.call(tx, receipt.blockNumber);
    console.log("Call result:", result);
  } catch (error) {
    console.log("\n❌ Revert Reason:");
    if (error.data) {
      console.log("Error data:", error.data);
    }
    if (error.message) {
      console.log("Error message:", error.message);
    }
    if (error.reason) {
      console.log("Error reason:", error.reason);
    }
    
    // Try to decode custom error
    if (error.data && error.data.startsWith('0x')) {
      console.log("\nRaw error data:", error.data);
      
      // FailedOp error signature: FailedOp(uint256 opIndex, string reason)
      const failedOpSig = "0x220266b6"; // keccak256("FailedOp(uint256,string)")
      
      if (error.data.startsWith(failedOpSig)) {
        console.log("\n✅ Decoded as FailedOp error");
        const errorData = "0x" + error.data.slice(10);
        try {
          const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
            ["uint256", "string"],
            errorData
          );
          console.log("  opIndex:", decoded[0].toString());
          console.log("  reason:", decoded[1]);
        } catch (e) {
          console.log("Failed to decode:", e.message);
        }
      }
    }
  }
}

main().catch(console.error);
