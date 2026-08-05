/*
  One-time sync script: recalculate users score from posts.

  What it does:
  - Scans all posts (default: published only)
  - Calculates points per post (uses scoreAwarded when present, otherwise derives from category/subCategory)
  - Aggregates total score per authorId
  - Updates every users/{uid}.score to computed total (0 when user has no matching posts)
  - Mirrors score into users_public/{uid}.score

  Safety defaults:
  - DRY_RUN=true by default (no writes)
  - Batched writes
  - Writes only when score changed

  Usage:
  1) Authenticate Admin SDK (service account or GOOGLE_APPLICATION_CREDENTIALS)
  2) npm install
  3) Dry run:
     node scripts/sync-user-scores-from-posts.js
  4) Real run:
     DRY_RUN=false node scripts/sync-user-scores-from-posts.js

  Optional env vars:
  - BATCH_SIZE=300
  - INCLUDE_DRAFTS=false
*/

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldPath, FieldValue } = require('firebase-admin/firestore');
const fs = require('fs');
const path = require('path');

const DRY_RUN = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 300);
const INCLUDE_DRAFTS =
  (process.env.INCLUDE_DRAFTS ?? 'false').toLowerCase() === 'true';
const PAGE_SIZE = Number(process.env.PAGE_SIZE ?? 1000);

function resolveProjectId() {
  const fromEnv =
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCLOUD_PROJECT ||
    process.env.FIREBASE_PROJECT_ID ||
    '';
  if (String(fromEnv).trim()) {
    return String(fromEnv).trim();
  }

  try {
    const firebasercPath = path.join(process.cwd(), '.firebaserc');
    if (!fs.existsSync(firebasercPath)) {
      return '';
    }

    const parsed = JSON.parse(fs.readFileSync(firebasercPath, 'utf8'));
    const fromRc = parsed?.projects?.default;
    return String(fromRc ?? '').trim();
  } catch (_) {
    return '';
  }
}

const projectId = resolveProjectId();
initializeApp(projectId ? { projectId } : undefined);
const db = getFirestore();

const CATEGORY_SUBCATEGORY_POINTS = {
  'כללי': {
    _default: 5,
  },
  'אקסטרים': {
    "בנג'י": 20,
    'צניחה חופשית': 30,
    'צלילה': 20,
    'ספורט ימי': 15,
    'פארק שעשועים': 10,
    'פארק חבלים': 12,
    'טיפוס': 16,
    'רכיבת שטח': 14,
    'אחר': 10,
  },
  'טיולים': {
    'מסלול רגלי': 10,
    נחל: 10,
    אגם: 10,
    קמפינג: 14,
    קומזיץ: 8,
    'מבשלים בטבע': 10,
    אחר: 8,
  },
  'משפחה': {
    'ארוחה משפחתית': 8,
    'מתנה למשפחה': 10,
    'יום הולדת': 12,
    'טיול משפחתי': 10,
    'רגע יפה': 8,
    'סבא וסבתא': 12,
    אחר: 8,
  },
  'חברים': {
    ישיבה: 6,
    טיול: 10,
    'חו"ל': 14,
    מתנה: 10,
    מתיחה: 6,
    מסעדה: 8,
    ריכולים: 5,
    אחר: 6,
  },
  'אומנות': {
    ציור: 12,
    שירה: 12,
    הופעה: 14,
    ניגון: 12,
    עיצוב: 10,
    תפירה: 10,
    אחר: 8,
  },
  'אוכל': {
    מסעדה: 8,
    'ארוחה ביתית': 10,
    מתכון: 12,
    'ארוחה קלה': 6,
    חלבון: 7,
    "ג'אנק": 4,
    אחר: 6,
  },
  'מעשים טובים': {
    'עזרה לאדם זר': 20,
    'תרומה כספית': 25,
    'תרומת חפצים': 18,
    'פרגון לאנשים': 12,
    'פיזור אהבת חינם': 12,
    'אירוע חברתי': 16,
    התנדבות: 20,
    אחר: 10,
  },
  'חו"ל': {
    טיסה: 12,
    מלון: 8,
    אוכל: 8,
    אטרקציות: 14,
    אווירה: 8,
    המלצות: 10,
    נופים: 12,
    סטייל: 9,
    אחר: 8,
  },
  'נופים': {
    ים: 10,
    ירוק: 10,
    הר: 12,
    נחל: 10,
    אגם: 10,
    תצפית: 12,
    'פלא תבל': 18,
    אחר: 8,
  },
  אחר: {
    אחר: 5,
    _default: 5,
  },
};

function pointsForCategory(category, subCategory) {
  const normalizedCategory = String(category ?? '').trim();
  const normalizedSubCategory = String(subCategory ?? '').trim();

  const categoryPoints = CATEGORY_SUBCATEGORY_POINTS[normalizedCategory];
  if (!categoryPoints) return 0;

  if (
    normalizedSubCategory &&
    Object.prototype.hasOwnProperty.call(categoryPoints, normalizedSubCategory)
  ) {
    return Number(categoryPoints[normalizedSubCategory] ?? 0) || 0;
  }

  if (Object.prototype.hasOwnProperty.call(categoryPoints, 'אחר')) {
    return Number(categoryPoints['אחר'] ?? 0) || 0;
  }

  if (Object.prototype.hasOwnProperty.call(categoryPoints, '_default')) {
    return Number(categoryPoints._default ?? 0) || 0;
  }

  return 0;
}

function shouldCountPost(post) {
  if (INCLUDE_DRAFTS) {
    return true;
  }

  const status = String(post.status ?? 'published').trim().toLowerCase();
  return status === 'published';
}

function postScore(post) {
  const direct = post.scoreAwarded;
  const scoreAwarded =
    typeof direct === 'number' && Number.isFinite(direct)
      ? Math.max(0, Math.trunc(direct))
      : pointsForCategory(post.category, post.subCategory);

  const likesCount = Number.isFinite(Number(post.likesCount))
    ? Number(post.likesCount)
    : Array.isArray(post.likes)
      ? post.likes.length
      : 0;
  const commentsCount = Number.isFinite(Number(post.commentsCount))
    ? Number(post.commentsCount)
    : Array.isArray(post.comments)
      ? post.comments.length
      : 0;
  const sharesCount = Number.isFinite(Number(post.sharesCount))
    ? Number(post.sharesCount)
    : 0;

  return scoreAwarded + likesCount + commentsCount * 2 + sharesCount * 3;
}

function taggedBonusForPost(post) {
  const score = postScore(post);
  if (score <= 0) {
    return 0;
  }
  return Math.floor(score / 5);
}

function taggedUidsForPost(post) {
  const authorId = String(post.authorId ?? '').trim();
  const rawMembers = Array.isArray(post.members)
    ? post.members
    : Array.isArray(post.participants)
      ? post.participants
      : [];

  return new Set(
    rawMembers
      .map((item) => String(item ?? '').trim())
      .filter((uid) => uid && uid !== authorId)
  );
}

async function collectScoresByUser() {
  const scoreByUid = new Map();
  let scannedPosts = 0;
  let countedPosts = 0;
  let skippedWithoutAuthor = 0;

  let lastDoc = null;

  while (true) {
    let query = db.collection('posts').orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (lastDoc) {
      query = query.startAfter(lastDoc.id);
    }

    const snap = await query.get();
    if (snap.empty) {
      break;
    }

    for (const doc of snap.docs) {
      scannedPosts += 1;
      const post = doc.data() || {};

      if (!shouldCountPost(post)) {
        continue;
      }

      const uid = String(post.authorId ?? '').trim();
      if (!uid) {
        skippedWithoutAuthor += 1;
        continue;
      }

      const score = postScore(post);
      scoreByUid.set(uid, (scoreByUid.get(uid) ?? 0) + score);

      const taggedBonus = taggedBonusForPost(post);
      if (taggedBonus > 0) {
        for (const taggedUid of taggedUidsForPost(post)) {
          scoreByUid.set(
            taggedUid,
            (scoreByUid.get(taggedUid) ?? 0) + taggedBonus
          );
        }
      }

      countedPosts += 1;
    }

    lastDoc = snap.docs[snap.docs.length - 1];
  }

  return {
    scoreByUid,
    scannedPosts,
    countedPosts,
    skippedWithoutAuthor,
  };
}

async function run() {
  console.log(
    `[sync-user-scores] starting. dryRun=${DRY_RUN} includeDrafts=${INCLUDE_DRAFTS} batchSize=${BATCH_SIZE} pageSize=${PAGE_SIZE} projectId=${projectId || 'unknown'}`
  );

  const usersSnapshot = await db.collection('users').get();
  console.log(`[sync-user-scores] scanned users=${usersSnapshot.size}`);

  const { scoreByUid, scannedPosts, countedPosts, skippedWithoutAuthor } =
    await collectScoresByUser();
  console.log(
    `[sync-user-scores] scanned posts=${scannedPosts} countedPosts=${countedPosts}`
  );

  let batch = db.batch();
  let writesInBatch = 0;
  let updatesPlanned = 0;
  let updated = 0;
  let skipped = 0;

  for (const userDoc of usersSnapshot.docs) {
    const uid = userDoc.id;
    const userData = userDoc.data() || {};

    const nextScore = Number(scoreByUid.get(uid) ?? 0) || 0;
    const currentScore = Number(userData.score ?? 0) || 0;

    if (currentScore === nextScore) {
      skipped += 1;
      continue;
    }

    updatesPlanned += 1;

    if (!DRY_RUN) {
      const usersRef = db.collection('users').doc(uid);
      const usersPublicRef = db.collection('users_public').doc(uid);

      const scorePayload = {
        score: nextScore,
        updatedAt: FieldValue.serverTimestamp(),
      };

      batch.set(usersRef, scorePayload, { merge: true });
      batch.set(usersPublicRef, scorePayload, { merge: true });
      writesInBatch += 2;

      if (writesInBatch >= BATCH_SIZE) {
        await batch.commit();
        updated += writesInBatch;
        console.log(`[sync-user-scores] committed batch. totalWrites=${updated}`);
        batch = db.batch();
        writesInBatch = 0;
      }
    }
  }

  if (!DRY_RUN && writesInBatch > 0) {
    await batch.commit();
    updated += writesInBatch;
    console.log(`[sync-user-scores] committed final batch. totalWrites=${updated}`);
  }

  const usersWithPosts = scoreByUid.size;

  console.log('[sync-user-scores] done.');
  console.log(
    JSON.stringify(
      {
        dryRun: DRY_RUN,
        includeDrafts: INCLUDE_DRAFTS,
        scannedUsers: usersSnapshot.size,
        scannedPosts,
        countedPosts,
        skippedWithoutAuthor,
        usersWithPosts,
        updatesPlanned,
        updatedWrites: updated,
        skipped,
      },
      null,
      2
    )
  );
}

run().catch((err) => {
  console.error('[sync-user-scores] failed', err);
  process.exitCode = 1;
});
