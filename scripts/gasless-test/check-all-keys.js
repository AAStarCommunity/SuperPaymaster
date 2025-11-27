const { privateKeyToAccount } = require('viem/accounts');
require('dotenv').config({ path: require('path').join(__dirname, '../env/.env') });

const TARGET_OWNER = '0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA';

const keys = {
  'OWNER_PRIVATE_KEY': process.env.OWNER_PRIVATE_KEY,
  'DEPLOYER_PRIVATE_KEY': process.env.DEPLOYER_PRIVATE_KEY,
  'OWNER2_PRIVATE_KEY': process.env.OWNER2_PRIVATE_KEY,
  'PRIVATE_KEY': process.env.PRIVATE_KEY,
  'COMMUNITY_AOA_PRIVATE_KEY': process.env.COMMUNITY_AOA_PRIVATE_KEY,
  'COMMUNITY_SUPER_PRIVATE_KEY': process.env.COMMUNITY_SUPER_PRIVATE_KEY
};

console.log(`Looking for owner: ${TARGET_OWNER}\n`);

for (const [name, key] of Object.entries(keys)) {
  if (!key) {
    console.log(`${name}: (not set)`);
    continue;
  }

  try {
    const privateKey = key.startsWith('0x') ? key : `0x${key}`;
    const account = privateKeyToAccount(privateKey);
    const match = account.address.toLowerCase() === TARGET_OWNER.toLowerCase();

    console.log(`${name}:`);
    console.log(`  Address: ${account.address}`);
    console.log(`  Match: ${match ? '✅ YES - USE THIS KEY!' : '❌ NO'}`);
    console.log('');
  } catch (e) {
    console.log(`${name}: ERROR - ${e.message}`);
    console.log('');
  }
}
