/**
 * Shared config loader for gasless tests
 * Reads deployed contract addresses from deployments/config.sepolia.json
 */
const fs = require('fs');
const path = require('path');

const PROJECT_ROOT = path.join(__dirname, '../..');
const CONFIG_PATH = path.join(PROJECT_ROOT, 'deployments/config.sepolia.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    throw new Error(`Config not found: ${CONFIG_PATH}`);
  }
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

module.exports = { loadConfig, PROJECT_ROOT };
