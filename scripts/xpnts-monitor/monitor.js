#!/usr/bin/env node
/**
 * xPNTsToken Security Monitor
 * 
 * Monitors critical events on Optimism Mainnet and Ethereum Mainnet
 * Sends email alerts for suspicious activities
 * 
 * Setup:
 * 1. npm install viem nodemailer dotenv
 * 2. Configure .env.monitor (see below)
 * 3. Run: node monitor-xpnts.js
 */

import { createPublicClient, http, parseAbiItem, formatEther } from 'viem';
import { optimism, mainnet } from 'viem/chains';
import nodemailer from 'nodemailer';
import * as dotenv from 'dotenv';

dotenv.config({ path: '.env.monitor' });

// ====================================
// Configuration
// ====================================

const CONFIG = {
  // Network configs
  networks: {
    optimism: {
      chain: optimism,
      rpcUrl: process.env.OP_RPC_URL || 'https://mainnet.optimism.io',
      xpntsAddress: process.env.OP_XPNTS_ADDRESS, // Deploy后填入
    },
    mainnet: {
      chain: mainnet,
      rpcUrl: process.env.ETH_RPC_URL || 'https://eth.llamarpc.com',
      xpntsAddress: process.env.ETH_XPNTS_ADDRESS, // Deploy后填入
    },
  },

  // Email config (using Gmail as example)
  email: {
    from: process.env.EMAIL_FROM,
    to: process.env.EMAIL_TO, // 逗号分隔多个邮箱
    smtp: {
      host: process.env.SMTP_HOST || 'smtp.gmail.com',
      port: parseInt(process.env.SMTP_PORT || '587'),
      secure: false,
      auth: {
        user: process.env.SMTP_USER,
        pass: process.env.SMTP_PASS, // Gmail需要App Password
      },
    },
  },

  // Polling interval (milliseconds)
  pollInterval: parseInt(process.env.POLL_INTERVAL || '60000'), // 1分钟

  // Alert thresholds
  thresholds: {
    debtRecordPerHour: 20, // 单用户每小时记录债务超过20次告警
    singleTxNearLimit: 4500, // 单笔接近5000限额（4500+）时记录
  },
};

// ====================================
// Email Transport
// ====================================

const transporter = nodemailer.createTransport(CONFIG.email.smtp);

async function sendEmailAlert(subject, body) {
  try {
    const recipients = CONFIG.email.to.split(',').map(e => e.trim());
    
    await transporter.sendMail({
      from: CONFIG.email.from,
      to: recipients,
      subject: `🚨 xPNTs Alert: ${subject}`,
      html: `
        <html>
          <body style="font-family: Arial, sans-serif;">
            <h2 style="color: #e74c3c;">🚨 xPNTsToken Security Alert</h2>
            <div style="background: #f8f9fa; padding: 15px; border-left: 4px solid #e74c3c;">
              ${body}
            </div>
            <p style="color: #7f8c8d; font-size: 12px;">
              Time: ${new Date().toISOString()}<br>
              Monitor: xPNTs Security Monitor v1.0
            </p>
          </body>
        </html>
      `,
    });
    
    console.log(`✅ Email sent: ${subject}`);
  } catch (error) {
    console.error('❌ Failed to send email:', error.message);
  }
}

// ====================================
// Event Monitoring
// ====================================

const EVENTS = {
  SuperPaymasterAddressUpdated: parseAbiItem(
    'event SuperPaymasterAddressUpdated(address indexed newSuperPaymaster)'
  ),
  AutoApprovedSpenderRemoved: parseAbiItem(
    'event AutoApprovedSpenderRemoved(address indexed spender)'
  ),
  DebtRecorded: parseAbiItem(
    'event DebtRecorded(address indexed user, uint256 amount)'
  ),
};

// State tracking
const state = {
  lastBlock: {},
  debtRecordCount: {}, // user -> array of timestamps
};

async function monitorNetwork(networkName) {
  const config = CONFIG.networks[networkName];
  
  if (!config.xpntsAddress) {
    console.log(`⚠️  Skipping ${networkName}: xPNTs address not configured`);
    return;
  }

  const client = createPublicClient({
    chain: config.chain,
    transport: http(config.rpcUrl),
  });

  console.log(`✅ Monitoring ${networkName} at ${config.xpntsAddress}`);

  // Get current block
  const currentBlock = await client.getBlockNumber();
  const fromBlock = state.lastBlock[networkName] || currentBlock - 100n;

  // Fetch logs
  const logs = await client.getLogs({
    address: config.xpntsAddress,
    events: Object.values(EVENTS),
    fromBlock,
    toBlock: currentBlock,
  });

  // Process logs
  for (const log of logs) {
    await processEvent(log, networkName);
  }

  state.lastBlock[networkName] = currentBlock;
}

async function processEvent(log, network) {
  const { eventName, args } = log;
  const txHash = log.transactionHash;
  const explorerUrl = network === 'optimism' 
    ? `https://optimistic.etherscan.io/tx/${txHash}`
    : `https://etherscan.io/tx/${txHash}`;

  switch (eventName) {
    case 'SuperPaymasterAddressUpdated':
      await sendEmailAlert(
        'SuperPaymaster Address Changed',
        `
          <h3>⚠️ SuperPaymaster 地址已更换</h3>
          <p><strong>Network:</strong> ${network}</p>
          <p><strong>New Address:</strong> <code>${args.newSuperPaymaster}</code></p>
          <p><strong>Transaction:</strong> <a href="${explorerUrl}">${txHash}</a></p>
          <p style="color: #e74c3c;">🔴 <strong>Action Required:</strong> 请立即验证此变更是否授权！</p>
        `
      );
      break;

    case 'AutoApprovedSpenderRemoved':
      await sendEmailAlert(
        'Auto-Approved Spender Removed',
        `
          <h3>⚠️ 权限已撤销</h3>
          <p><strong>Network:</strong> ${network}</p>
          <p><strong>Removed Spender:</strong> <code>${args.spender}</code></p>
          <p><strong>Transaction:</strong> <a href="${explorerUrl}">${txHash}</a></p>
          <p>这可能是 emergencyRevokePaymaster() 调用或正常的权限管理。</p>
        `
      );
      break;

    case 'DebtRecorded':
      // Track debt recording frequency
      const user = args.user;
      const now = Date.now();
      
      if (!state.debtRecordCount[user]) {
        state.debtRecordCount[user] = [];
      }
      
      state.debtRecordCount[user].push(now);
      
      // Clean old records (older than 1 hour)
      state.debtRecordCount[user] = state.debtRecordCount[user].filter(
        t => now - t < 3600000
      );
      
      // Alert if too frequent
      if (state.debtRecordCount[user].length > CONFIG.thresholds.debtRecordPerHour) {
        await sendEmailAlert(
          'Abnormal Debt Recording Frequency',
          `
            <h3>⚠️ 异常高频债务记录</h3>
            <p><strong>Network:</strong> ${network}</p>
            <p><strong>User:</strong> <code>${user}</code></p>
            <p><strong>Count (1hr):</strong> ${state.debtRecordCount[user].length}</p>
            <p><strong>Amount:</strong> ${formatEther(args.amount)} xPNTs</p>
            <p><strong>Transaction:</strong> <a href="${explorerUrl}">${txHash}</a></p>
            <p style="color: #e67e22;">🟡 可能是正常高频用户，或代码Bug导致重复扣款。</p>
          `
        );
      }
      break;
  }
}

// ====================================
// Main Loop
// ====================================

async function main() {
  console.log('🚀 xPNTsToken Security Monitor Started');
  console.log(`📧 Email alerts will be sent to: ${CONFIG.email.to}`);
  console.log(`⏱️  Poll interval: ${CONFIG.pollInterval / 1000}s\n`);

  // Test email
  try {
    await sendEmailAlert(
      'Monitor Started',
      `
        <h3>✅ 监控系统已启动</h3>
        <p><strong>Networks:</strong> ${Object.keys(CONFIG.networks).join(', ')}</p>
        <p><strong>Poll Interval:</strong> ${CONFIG.pollInterval / 1000}s</p>
        <p>如果收到此邮件，说明邮件配置正确。</p>
      `
    );
  } catch (error) {
    console.error('❌ Email test failed:', error.message);
    console.error('Please check your .env.monitor configuration');
    process.exit(1);
  }

  // Monitor loop
  while (true) {
    try {
      for (const network of Object.keys(CONFIG.networks)) {
        await monitorNetwork(network);
      }
    } catch (error) {
      console.error(`❌ Monitor error:`, error.message);
      // 不退出，继续监控
    }

    await new Promise(resolve => setTimeout(resolve, CONFIG.pollInterval));
  }
}

// ====================================
// Graceful Shutdown
// ====================================

process.on('SIGINT', async () => {
  console.log('\n⏹️  Shutting down monitor...');
  await sendEmailAlert(
    'Monitor Stopped',
    '<p>监控系统已停止。</p>'
  );
  process.exit(0);
});

// ====================================
// Start
// ====================================

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
