/*
  One-time sync script: users -> users_public

  What it does:
  - Scans all users documents
  - Builds a normalized public profile payload
  - Upserts into users_public/{uid}

  Safety defaults:
  - DRY_RUN=true by default (no writes)
  - Batched writes
  - Writes only when at least one synced field is different

  Usage:
  1) Authenticate Admin SDK (service account or GOOGLE_APPLICATION_CREDENTIALS)
  2) npm install
  3) Dry run:
     node scripts/sync-users-public-from-users.js
  4) Real run:
     DRY_RUN=false node scripts/sync-users-public-from-users.js
*/

const admin = require('firebase-admin');

const DRY_RUN = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 300);

admin.initializeApp();
const db = admin.firestore();

function normalizeUsername(raw) {
  const username = String(raw ?? '').trim();
  if (!username) return '';
  return username.startsWith('@') ? username.toLowerCase() : `@${username.toLowerCase()}`;
}

function normalizeAvatar(userDoc) {
  return String(
    userDoc.profilePictureUrl ?? userDoc.profileImageUrl ?? userDoc.avatarUrl ?? ''
  ).trim();
}

function buildPublicPayload(uid, userDoc) {
  const firstName = String(userDoc.firstName ?? '').trim();
  const lastName = String(userDoc.lastName ?? '').trim();
  const username = normalizeUsername(userDoc.username);
  const bio = String(userDoc.bio ?? '').trim();
  const profilePictureUrl = normalizeAvatar(userDoc);
  const followersCount = Number(userDoc.followersCount ?? 0) || 0;
  const followingCount = Number(userDoc.followingCount ?? 0) || 0;

  return {
    uid,
    username,
    firstName,
    lastName,
    bio,
    profilePictureUrl,
    profileImageUrl: profilePictureUrl,
    avatarUrl: profilePictureUrl,
    followersCount,
    followingCount,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

function differs(existing = {}, next = {}) {
  const keys = [
    'uid',
    'username',
    'firstName',
    'lastName',
    'bio',
    'profilePictureUrl',
    'profileImageUrl',
    'avatarUrl',
    'followersCount',
    'followingCount',
  ];

  return keys.some((key) => {
    const currentValue = existing[key];
    const nextValue = next[key];
    return String(currentValue ?? '') !== String(nextValue ?? '');
  });
}

async function run() {
  console.log(`[sync-users-public] starting. dryRun=${DRY_RUN} batchSize=${BATCH_SIZE}`);

  const usersSnapshot = await db.collection('users').get();
  console.log(`[sync-users-public] scanned users=${usersSnapshot.size}`);

  let batch = db.batch();
  let writesInBatch = 0;
  let updatesPlanned = 0;
  let updated = 0;
  let skipped = 0;

  for (const userDoc of usersSnapshot.docs) {
    const uid = userDoc.id;
    const userData = userDoc.data() || {};
    const nextPayload = buildPublicPayload(uid, userData);

    const publicRef = db.collection('users_public').doc(uid);
    const publicSnap = await publicRef.get();
    const currentPublic = publicSnap.exists ? (publicSnap.data() || {}) : {};

    if (!differs(currentPublic, nextPayload)) {
      skipped += 1;
      continue;
    }

    updatesPlanned += 1;

    if (!DRY_RUN) {
      const payloadWithCreatedAt = {
        ...nextPayload,
      };

      if (!publicSnap.exists) {
        payloadWithCreatedAt.createdAt = admin.firestore.FieldValue.serverTimestamp();
      }

      batch.set(publicRef, payloadWithCreatedAt, { merge: true });
      writesInBatch += 1;

      if (writesInBatch >= BATCH_SIZE) {
        await batch.commit();
        updated += writesInBatch;
        console.log(`[sync-users-public] committed batch. totalUpdated=${updated}`);
        batch = db.batch();
        writesInBatch = 0;
      }
    }
  }

  if (!DRY_RUN && writesInBatch > 0) {
    await batch.commit();
    updated += writesInBatch;
    console.log(`[sync-users-public] committed final batch. totalUpdated=${updated}`);
  }

  console.log('[sync-users-public] done.');
  console.log(
    JSON.stringify(
      {
        dryRun: DRY_RUN,
        scannedUsers: usersSnapshot.size,
        updatesPlanned,
        updated,
        skipped,
      },
      null,
      2
    )
  );
}

run().catch((err) => {
  console.error('[sync-users-public] failed', err);
  process.exitCode = 1;
});
