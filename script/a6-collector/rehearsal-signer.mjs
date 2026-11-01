import { ANVIL_KEYS } from '../b-layer/lib.mjs';
import { privateKeyToAccount } from 'viem/accounts';
export const rehearsalSigner = (_,role) => privateKeyToAccount(ANVIL_KEYS[['owner','bundler','verifyingSigner'].indexOf(role)]);
