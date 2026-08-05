/*
  One-time migration for chats/*/messages documents.

  What it does:
  - Reads each message senderId
  - Loads canonical sender profile from users/{senderId}
  - Updates senderName + senderAvatarUrl (+ senderImageUrl alias)

  Safety defaults:
  - DRY_RUN=true by default (no writes)
  - Batched writes
  - Updates only when values actually changed

  Usage:
  1) Authenticate Admin SDK (service account or GOOGLE_APPLICATION_CREDENTIALS)
  2) npm install
  3) Dry run:
     node scripts/migrate-chat-message-sender-profile.js
  4) Real run:
     DRY_RUN=false node scripts/migrate-chat-message-sender-profile.js
*/

const admin = require('firebase-admin');

const DRY_RUN = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 300);

admin.initializeApp();
const db = admin.firestore();

function normalizeDisplayName(userDoc, fallback) {
  const firstName = String(userDoc.firstName ?? '').trim();
  const lastName = String(userDoc.lastName ?? '').trim();
  const fullName = [firstName, lastName].filter(Boolean).join(' ').trim();
  if (fullName) return fullName;

  const username = String(userDoc.username ?? '').trim();
  if (username) return username;

  return fallback;
}

function normalizeAvatar(userDoc) {
  return String(
    userDoc.profilePictureUrl ?? userDoc.profileImageUrl ?? userDoc.avatarUrl ?? ''
  ).trim();
}

async function run() {
  console.log(`[migration] starting. dryRun=${DRY_RUN} batchSize=${BATCH_SIZE}`);

  const snapshot = await db.collectionGroup('messages').get();
  console.log(`[migration] scanned messages=${snapshot.size}`);

  let batch = db.batch();
  let writesInBatch = 0;
  let updatesPlanned = 0;
  let updated = 0;
  let skipped = 0;
  let missingSender = 0;
  let missingUserDoc = 0;

  const userCache = new Map();

  for (const msgDoc of snapshot.docs) {
    const msg = msgDoc.data() || {};
    const senderId = String(msg.senderId ?? '').trim();

    if (!senderId) {
      skipped += 1;
      missingSender += 1;
      continue;
    }

    let userDoc = userCache.get(senderId);
    if (userDoc === undefined) {
      const userSnap = await db.collection('users').doc(senderId).get();
      userDoc = userSnap.exists ? (userSnap.data() || {}) : null;
      userCache.set(senderId, userDoc);
    }

    if (!userDoc) {
      skipped += 1;
      missingUserDoc += 1;
      continue;
    }

    const nextSenderName = normalizeDisplayName(userDoc, 'משתמש');
    const nextAvatar = normalizeAvatar(userDoc);

    const currentSenderName = String(msg.senderName ?? '').trim();
    const currentAvatar = String(msg.senderAvatarUrl ?? '').trim();
    const currentImageAlias = String(msg.senderImageUrl ?? '').trim();

    const needsUpdate =
      currentSenderName !== nextSenderName ||
      currentAvatar !== nextAvatar ||
      currentImageAlias !== nextAvatar;

    if (!needsUpdate) {
      skipped += 1;
      continue;
    }

    updatesPlanned += 1;

    if (!DRY_RUN) {
      batch.update(msgDoc.ref, {
        senderName: nextSenderName,
        senderAvatarUrl: nextAvatar,
        senderImageUrl: nextAvatar,
        migratedSenderProfileAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      writesInBatch += 1;

      if (writesInBatch >= BATCH_SIZE) {
        await batch.commit();
        updated += writesInBatch;
        console.log(`[migration] committed batch. totalUpdated=${updated}`);
        batch = db.batch();
        writesInBatch = 0;
      }
    }
  }

  if (!DRY_RUN && writesInBatch > 0) {
    await batch.commit();
    updated += writesInBatch;
    console.log(`[migration] committed final batch. totalUpdated=${updated}`);
  }

  console.log('[migration] done.');
  console.log(
    JSON.stringify(
      {
        dryRun: DRY_RUN,
        scannedMessages: snapshot.size,
        updatesPlanned,
        updated,
        skipped,
        missingSender,
        missingUserDoc,
      },
      null,
      2
    )
  );
}

run().catch((err) => {
  console.error('[migration] failed', err);
  process.exitCode = 1;
});
