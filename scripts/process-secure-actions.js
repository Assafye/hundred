/*
  Secure actions worker CLI.

  Usage:
    node scripts/process-secure-actions.js

  Env:
    DRY_RUN=true|false (default: true)
    LIMIT=200 (max actions to process in one run)
*/

const {
  processPendingSecureActions,
} = require('../functions/secure_actions_processor');

const dryRun = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const limit = Number(process.env.LIMIT ?? 200);

processPendingSecureActions({ limit, dryRun }).catch((error) => {
  console.error('[secure-actions] fatal', error);
  process.exitCode = 1;
});