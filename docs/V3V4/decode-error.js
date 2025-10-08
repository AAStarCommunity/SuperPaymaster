const { ethers } = require('ethers');

async function main() {
  const RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N_YI5okBBDE";
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  
  const txHash = '0xeeb80fb9b836bd1a8b6d64da6bad18fa21e563e0e11c66c1fe4a9504f1e28e69';
  
  // 获取 receipt
  const receipt = await provider.getTransactionReceipt(txHash);
  console.log('Receipt status:', receipt.status);
  
  // 查找 UserOperationRevertReason 事件
  const revertReasonTopic = '0xf62676f440ff169a3a9afdbf812e89e7f95975ee8e5c31214ffdef631c5f4792';
  const revertLog = receipt.logs.find(log => log.topics[0] === revertReasonTopic);
  
  if (revertLog) {
    console.log('\nUserOperationRevertReason event found:');
    console.log('Data:', revertLog.data);
    
    // 解码事件数据
    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
      ['bytes32', 'bytes'],
      revertLog.data
    );
    
    console.log('\nUserOpHash:', decoded[0]);
    console.log('Revert reason (hex):', ethers.hexlify(decoded[1]));
    console.log('Revert reason (length):', decoded[1].length, 'bytes');
    
    // 解码错误选择器
    if (decoded[1].length >= 4) {
      const errorSelector = ethers.hexlify(decoded[1].slice(0, 4));
      console.log('\nError selector:', errorSelector);
      
      // 如果有额外数据
      if (decoded[1].length > 4) {
        const errorParams = ethers.hexlify(decoded[1].slice(4));
        console.log('Error parameters (hex):', errorParams);
      }
    }
  } else {
    console.log('UserOperationRevertReason event not found');
  }
}

main().catch(console.error);
