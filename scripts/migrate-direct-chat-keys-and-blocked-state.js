/*
  One-time migration for deterministic direct chats and denormalized block state.

  What it does:
  - Scans `chats` and normalizes direct chats to deterministic IDs: `${uidA}__${uidB}` (sorted).
  - Ensures each direct chat has `directChatKey`, `participants` sorted and `blockedBy` map.
  - Optionally copies `messages` + `readReceipts` subcollections from legacy chat IDs.
  - Scans `users/{uid}/blocked_users/{blockedUid}` and denormalizes active blocks to
    `chats/{directKey}.blockedBy.{ownerUid} = true`.

  Safety defaults:
  - DRY_RUN=true (no writes)
  - DELETE_OLD=false (legacy chat docs are kept unless explicitly enabled)

  Usage:
  1) Authenticate Admin SDK (service account or GOOGLE_APPLICATION_CREDENTIALS)
  2) npm install
  3) Dry run:
     node scripts/migrate-direct-chat-keys-and-blocked-state.js
  4) Real run (keep legacy docs):
     DRY_RUN=false node scripts/migrate-direct-chat-keys-and-blocked-state.js
  5) Optional cleanup of old direct chat docs after validation:
     DRY_RUN=false DELETE_OLD=true node scripts/migrate-direct-chat-keys-and-blocked-state.js
*/

const admin = require('firebase-admin');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const DRY_RUN = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const DELETE_OLD = (process.env.DELETE_OLD ?? 'false').toLowerCase() === 'true';
const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 300);

admin.initializeApp();
const db = getFirestore();

function directChatKey(uidA, uidB) {
  const a = String(uidA ?? '').trim();
  const b = String(uidB ?? '').trim();
  if (!a || !b || a === b) return '';
  return [a, b].sort().join('__');
}

function normalizeParticipants(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((v) => String(v ?? '').trim())
    .filter(Boolean)
    .filter((v, i, arr) => arr.indexOf(v) === i)
    .sort();
}

function isDirectChat(data) {
  const participants = normalizeParticipants(data?.participants ?? []);
  const isPublic = data?.isPublic === true;
  const explicitDirect = data?.isDirect === true;
  return explicitDirect || (!isPublic && participants.length === 2);
}

function blockedByMap(data, participants) {
  const out = {};
  for (const uid of participants) out[uid] = false;

  const raw = data?.blockedBy;
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const uid of participants) {
      if (raw[uid] === true) out[uid] = true;
    }
  }

  return out;
}

async function listSubcollectionDocs(parentRef, name) {
  const snap = await parentRef.collection(name).get();
  return snap.docs;
}

async function copySubcollection(sourceRef, targetRef, name, stats) {
  const docs = await listSubcollectionDocs(sourceRef, name);
  if (docs.length === 0) return;

  let batch = db.batch();
  let writes = 0;

  for (const doc of docs) {
    const targetDocRef = targetRef.collection(name).doc(doc.id);
    if (!DRY_RUN) {
      batch.set(targetDocRef, doc.data(), { merge: true });
      writes += 1;
      if (writes >= BATCH_SIZE) {
        await batch.commit();
        stats.subcollectionWrites += writes;
        batch = db.batch();
        writes = 0;
      }
    } else {
      stats.subcollectionWrites += 1;
    }
  }

  if (!DRY_RUN && writes > 0) {
    await batch.commit();
    stats.subcollectionWrites += writes;
  }
}

async function run() {
  const stats = {
    scannedChats: 0,
    scannedDirectChats: 0,
    normalizedDirectDocs: 0,
    movedDirectDocs: 0,
    skippedInvalidDirect: 0,
    copiedMessages: 0,
    copiedReadReceipts: 0,
    subcollectionWrites: 0,
    blockedDocsScanned: 0,
    blockedDenormUpdates: 0,
    oldDirectDocsDeleted: 0,
  };

  console.log(
    `[direct-migration] start dryRun=${DRY_RUN} deleteOld=${DELETE_OLD} batchSize=${BATCH_SIZE}`
  );

  const chatsSnapshot = await db.collection('chats').get();
  stats.scannedChats = chatsSnapshot.size;

  let batch = db.batch();
  let writesInBatch = 0;

  async function flushBatch() {
    if (DRY_RUN || writesInBatch === 0) return;
    await batch.commit();
    batch = db.batch();
    writesInBatch = 0;
  }

  for (const chatDoc of chatsSnapshot.docs) {
    const data = chatDoc.data() || {};
    if (!isDirectChat(data)) continue;

    stats.scannedDirectChats += 1;

    const participants = normalizeParticipants(data.participants ?? []);
    if (participants.length !== 2) {
      stats.skippedInvalidDirect += 1;
      continue;
    }

    const key = directChatKey(participants[0], participants[1]);
    if (!key) {
      stats.skippedInvalidDirect += 1;
      continue;
    }

    const targetRef = db.collection('chats').doc(key);
    const targetPayload = {
      id: key,
      directChatKey: key,
      isDirect: true,
      isPublic: false,
      participants,
      blockedBy: blockedByMap(data, participants),
      name: String(data.name ?? '').trim() || participants[1],
      groupImageUrl: String(data.groupImageUrl ?? '').trim(),
      lastMessage: String(data.lastMessage ?? ''),
      lastMessageSenderName: String(data.lastMessageSenderName ?? ''),
      lastMessageSenderId: String(data.lastMessageSenderId ?? ''),
      lastMessageAt: data.lastMessageAt ?? null,
      lastMessageType: String(data.lastMessageType ?? ''),
      createdAt: data.createdAt ?? FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (!DRY_RUN) {
      batch.set(targetRef, targetPayload, { merge: true });
      writesInBatch += 1;
      if (writesInBatch >= BATCH_SIZE) {
        await flushBatch();
      }
    }

    stats.normalizedDirectDocs += 1;

    if (chatDoc.id !== key) {
      stats.movedDirectDocs += 1;
      await copySubcollection(chatDoc.ref, targetRef, 'messages', stats);
      stats.copiedMessages += 1;
      await copySubcollection(chatDoc.ref, targetRef, 'readReceipts', stats);
      stats.copiedReadReceipts += 1;

      if (!DRY_RUN && DELETE_OLD) {
        batch.delete(chatDoc.ref);
        writesInBatch += 1;
        if (writesInBatch >= BATCH_SIZE) {
          await flushBatch();
        }
        stats.oldDirectDocsDeleted += 1;
      }
    }
  }

  await flushBatch();

  // Denormalize existing blocks into chats/{directKey}.blockedBy.{ownerUid} = true
  const blockedSnapshot = await db.collectionGroup('blocked_users').get();
  stats.blockedDocsScanned = blockedSnapshot.size;

  batch = db.batch();
  writesInBatch = 0;

  for (const doc of blockedSnapshot.docs) {
    const data = doc.data() || {};
    const ownerUid = String(data.blockedByUid ?? doc.ref.parent.parent?.id ?? '').trim();
    const blockedUid = String(data.blockedUid ?? doc.id ?? '').trim();

    if (!ownerUid || !blockedUid || ownerUid === blockedUid) continue;

    const key = directChatKey(ownerUid, blockedUid);
    if (!key) continue;

    const participants = normalizeParticipants([ownerUid, blockedUid]);
    const chatRef = db.collection('chats').doc(key);

    const payload = {
      id: key,
      directChatKey: key,
      isDirect: true,
      isPublic: false,
      participants,
      [`blockedBy.${ownerUid}`]: true,
      [`blockedBy.${blockedUid}`]: false,
      updatedAt: FieldValue.serverTimestamp(),
      createdAt: FieldValue.serverTimestamp(),
    };

    if (!DRY_RUN) {
      batch.set(chatRef, payload, { merge: true });
      writesInBatch += 1;
      if (writesInBatch >= BATCH_SIZE) {
        await batch.commit();
        batch = db.batch();
        writesInBatch = 0;
      }
    }

    stats.blockedDenormUpdates += 1;
  }

  if (!DRY_RUN && writesInBatch > 0) {
    await batch.commit();
  }

  console.log('[direct-migration] done');
  console.log(JSON.stringify(stats, null, 2));
}

run().catch((err) => {
  console.error('[direct-migration] failed', err);
  process.exitCode = 1;
});
