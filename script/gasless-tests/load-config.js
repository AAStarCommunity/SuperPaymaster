/**
 * Shared config loader for gasless tests
 * Reads deployed contract addresses from deployments/config.sepolia.json
 */
const fs = require('fs');
const path = require('path');

const PROJECT_ROOT = path.join(__dirname, '../..');
// CONFIG_PATH override: this file's own default target is Sepolia, matching
// test-helpers.js's CHAIN_ID override for the same reason — testing against a local
// anvil deployment needs deployments/config.anvil.json instead.
const CONFIG_PATH = process.env.CONFIG_PATH
  ? path.resolve(process.env.CONFIG_PATH)
  : path.join(PROJECT_ROOT, 'deployments/config.sepolia.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    throw new Error(`Config not found: ${CONFIG_PATH}`);
  }
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

module.exports = { loadConfig, PROJECT_ROOT };
