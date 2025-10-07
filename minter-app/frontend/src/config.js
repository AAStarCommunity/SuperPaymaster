import MyNFT_ABI from "./abis/MyNFT.json";
import MySBT_ABI from "./abis/MySBT.json";
import GasToken_ABI from "./abis/GasToken.json";

// --- CONFIGURATION ---
// Sync with backend/.env
const OWNER_ADDRESS = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

// --- DEPLOYED CONTRACT ADDRESSES ---
const addresses = {
  nft: "0xC9fB3Fe98442A23a0CA5884dC114989FF7b3d97a",
  sbt: "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
  // Old PNTS (simple ERC20): 0x3e7B771d4541eC85c8137e950598Ac97553a337a
  // Old PNTS V2 (wrong Settlement): 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9
  // New PNTv2 (correct Settlement 0x6bbf...): 0x090e34709a592210158aa49a969e4a04e3a29ebd
  pnts: "0x090e34709a592210158aa49a969e4a04e3a29ebd",
  gasTokenFactory: "0x62556E7f516a6E3F723800C52aFa02e10c147583",
};

// --- ABIs ---
const abis = {
  nft: MyNFT_ABI.abi,
  sbt: MySBT_ABI.abi,
  pnts: GasToken_ABI.abi, // Use GasToken ABI (ERC20 + pre-approval)
};

export const config = {
  OWNER_ADDRESS,
  addresses,
  abis,
};
