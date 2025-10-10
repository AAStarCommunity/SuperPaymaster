#!/usr/bin/env node
/**
 * Generate Test Accounts Pool
 * Creates 20 test accounts with private keys for demo purposes
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const NUM_ACCOUNTS = 20;

function generateAccounts(count) {
  const accounts = [];

  for (let i = 0; i < count; i++) {
    const wallet = ethers.Wallet.createRandom();
    accounts.push({
      index: i,
      address: wallet.address,
      privateKey: wallet.privateKey,
      mnemonic: wallet.mnemonic.phrase,
    });
  }

  return accounts;
}

function saveAccounts(accounts, format = "json") {
  const outputDir = path.join(__dirname, "../test-accounts");

  // Create output directory if it doesn't exist
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  if (format === "json") {
    // Save as JSON
    const jsonPath = path.join(outputDir, "accounts.json");
    fs.writeFileSync(
      jsonPath,
      JSON.stringify(accounts, null, 2),
      "utf-8"
    );
    console.log(`✅ Saved ${accounts.length} accounts to ${jsonPath}`);
  }

  if (format === "csv") {
    // Save as CSV
    const csvPath = path.join(outputDir, "accounts.csv");
    const csvHeader = "Index,Address,PrivateKey,Mnemonic\n";
    const csvRows = accounts.map(
      (acc) =>
        `${acc.index},"${acc.address}","${acc.privateKey}","${acc.mnemonic}"`
    );
    fs.writeFileSync(csvPath, csvHeader + csvRows.join("\n"), "utf-8");
    console.log(`✅ Saved ${accounts.length} accounts to ${csvPath}`);
  }

  if (format === "env") {
    // Save as .env format
    const envPath = path.join(outputDir, "accounts.env");
    const envLines = accounts.map(
      (acc, i) =>
        `TEST_ACCOUNT_${i}_ADDRESS=${acc.address}\nTEST_ACCOUNT_${i}_PRIVATE_KEY=${acc.privateKey}`
    );
    fs.writeFileSync(envPath, envLines.join("\n"), "utf-8");
    console.log(`✅ Saved ${accounts.length} accounts to ${envPath}`);
  }

  // Save TypeScript/JavaScript module
  const tsPath = path.join(outputDir, "accounts.ts");
  const tsContent = `/**
 * Test Accounts Pool
 * WARNING: These are test accounts only. DO NOT use in production!
 */

export interface TestAccount {
  index: number;
  address: string;
  privateKey: string;
  mnemonic: string;
}

export const TEST_ACCOUNTS: TestAccount[] = ${JSON.stringify(accounts, null, 2)};

export function getTestAccount(index: number): TestAccount {
  if (index < 0 || index >= TEST_ACCOUNTS.length) {
    throw new Error(\`Account index \${index} out of range [0, \${TEST_ACCOUNTS.length - 1}]\`);
  }
  return TEST_ACCOUNTS[index];
}

export function getRandomTestAccount(): TestAccount {
  const index = Math.floor(Math.random() * TEST_ACCOUNTS.length);
  return TEST_ACCOUNTS[index];
}

export function getAllTestAccounts(): TestAccount[] {
  return TEST_ACCOUNTS;
}

export const TEST_ACCOUNTS_BY_ADDRESS = TEST_ACCOUNTS.reduce((acc, account) => {
  acc[account.address] = account;
  return acc;
}, {} as Record<string, TestAccount>);
`;

  fs.writeFileSync(tsPath, tsContent, "utf-8");
  console.log(`✅ Saved TypeScript module to ${tsPath}`);

  // Save JavaScript module (CJS)
  const jsPath = path.join(outputDir, "accounts.js");
  const jsContent = tsContent.replace(/export /g, "module.exports.").replace(/: TestAccount/g, "").replace(/: TestAccount\[\]/g, "").replace(/: Record<string, TestAccount>/g, "");
  fs.writeFileSync(jsPath, jsContent, "utf-8");
  console.log(`✅ Saved JavaScript module to ${jsPath}`);

  // Create .gitignore to prevent accidental commit of private keys
  const gitignorePath = path.join(outputDir, ".gitignore");
  fs.writeFileSync(
    gitignorePath,
    "# Test accounts contain private keys - DO NOT COMMIT\n*\n!.gitignore\n!README.md",
    "utf-8"
  );
  console.log(`✅ Created .gitignore in ${outputDir}`);

  // Create README
  const readmePath = path.join(outputDir, "README.md");
  const readmeContent = `# Test Accounts Pool

This directory contains ${NUM_ACCOUNTS} generated test accounts for demo and testing purposes.

## ⚠️ WARNING

**These accounts contain private keys and should NEVER be used in production or with real funds.**

All files in this directory (except README.md and .gitignore) are gitignored to prevent accidental commits.

## Files

- \`accounts.json\`: All accounts in JSON format
- \`accounts.csv\`: All accounts in CSV format (for spreadsheets)
- \`accounts.env\`: All accounts in .env format
- \`accounts.ts\`: TypeScript module with helper functions
- \`accounts.js\`: JavaScript (CJS) module with helper functions

## Usage

### TypeScript/JavaScript

\`\`\`typescript
import { TEST_ACCOUNTS, getTestAccount, getRandomTestAccount } from './test-accounts/accounts';

// Get specific account
const account = getTestAccount(0);
console.log(account.address); // 0x...

// Get random account
const randomAccount = getRandomTestAccount();

// Get all accounts
const allAccounts = TEST_ACCOUNTS;
\`\`\`

### Node.js (CJS)

\`\`\`javascript
const { TEST_ACCOUNTS, getTestAccount } = require('./test-accounts/accounts');

const account = getTestAccount(5);
console.log(account.address);
\`\`\`

## Funding Accounts

To use these accounts in tests, you'll need to fund them with test ETH and tokens:

\`\`\`bash
# Using the faucet API
for i in {0..19}; do
  curl -X POST http://localhost:3000/api/mint-usdt \\
    -H "Content-Type: application/json" \\
    -d "{\\"address\\":\\"$(node -e "console.log(require('./accounts').getTestAccount($i).address)")\\"}"
done
\`\`\`

## Security

- **DO NOT** commit these files to version control
- **DO NOT** use these accounts with real funds
- **DO NOT** share these private keys publicly
- These accounts are for testing only

## Regeneration

To regenerate accounts, run:

\`\`\`bash
node scripts/generate-test-accounts.js
\`\`\`
`;

  fs.writeFileSync(readmePath, readmeContent, "utf-8");
  console.log(`✅ Created README.md in ${outputDir}`);
}

// Main execution
console.log(`🔑 Generating ${NUM_ACCOUNTS} test accounts...\n`);

const accounts = generateAccounts(NUM_ACCOUNTS);

// Save in multiple formats
saveAccounts(accounts, "json");
saveAccounts(accounts, "csv");
saveAccounts(accounts, "env");

console.log("\n" + "=".repeat(60));
console.log("📊 Summary");
console.log("=".repeat(60));
console.log(`Total accounts generated: ${accounts.length}`);
console.log(`Output directory: test-accounts/`);
console.log("\n🎯 Sample accounts:");
accounts.slice(0, 3).forEach((acc) => {
  console.log(`  [${acc.index}] ${acc.address}`);
});
console.log(`  ... and ${accounts.length - 3} more`);
console.log("\n⚠️  WARNING: Keep these private keys secure!");
console.log("=".repeat(60));
