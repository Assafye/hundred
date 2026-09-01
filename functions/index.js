const { initializeApp } = require('firebase-admin/app');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');

initializeApp();
const db = getFirestore();
const REGION = 'europe-west3';
const MAX_RESULTS = 360;
const POST_LIFETIME_MS = 24 * 60 * 60 * 1000;
const RATE_LIMIT_MS = 10 * 1000;
const GEOHASH_ALPHABET = '0123456789bcdefghjkmnpqrstuvwxyz';

function encodeGeoHash(latitude, longitude, precision) {
  let minLatitude = -90;
  let maxLatitude = 90;
  let minLongitude = -180;
  let maxLongitude = 180;
  let longitudeTurn = true;
  let bit = 0;
  let charIndex = 0;
  let hash = '';
  while (hash.length < precision) {
    if (longitudeTurn) {
      const midpoint = (minLongitude + maxLongitude) / 2;
      if (longitude >= midpoint) {
        charIndex = (charIndex << 1) | 1;
        minLongitude = midpoint;
      } else {
        charIndex <<= 1;
        maxLongitude = midpoint;
      }
    } else {
      const midpoint = (minLatitude + maxLatitude) / 2;
      if (latitude >= midpoint) {
        charIndex = (charIndex << 1) | 1;
        minLatitude = midpoint;
      } else {
        charIndex <<= 1;
        maxLatitude = midpoint;
      }
    }
    longitudeTurn = !longitudeTurn;
    bit += 1;
    if (bit === 5) {
      hash += GEOHASH_ALPHABET[charIndex];
      bit = 0;
      charIndex = 0;
    }
  }
  return hash;
}

function nearbyPrefixes(location, precision) {
  const totalBits = precision * 5;
  const latitudeStep = (180 / (2 ** Math.floor(totalBits / 2))) * 1.01;
  const longitudeStep = (360 / (2 ** Math.ceil(totalBits / 2))) * 1.01;
  const prefixes = new Set();
  for (let latitudeOffset = -1; latitudeOffset <= 1; latitudeOffset += 1) {
    for (let longitudeOffset = -1; longitudeOffset <= 1; longitudeOffset += 1) {
      prefixes.add(encodeGeoHash(
        Math.max(-89.999999, Math.min(89.999999, location.latitude + (latitudeStep * latitudeOffset))),
        Math.max(-180, Math.min(180, location.longitude + (longitudeStep * longitudeOffset))),
        precision,
      ));
    }
  }
  return [...prefixes];
}

function distanceInMeters(first, second) {
  const radians = Math.PI / 180;
  const latitudeDelta = (second.latitude - first.latitude) * radians;
  const longitudeDelta = (second.longitude - first.longitude) * radians;
  const a = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(first.latitude * radians) * Math.cos(second.latitude * radians) *
    Math.sin(longitudeDelta / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function displayDistanceMeters(distance) {
  if (distance < 1000) return 500;
  if (distance < 3000) return 2000;
  if (distance < 5000) return 4000;
  if (distance < 10000) return 7500;
  if (distance < 20000) return 15000;
  if (distance < 30000) return 25000;
  if (distance < 40000) return 35000;
  if (distance < 50000) return 45000;
  if (distance < 60000) return 55000;
  if (distance < 70000) return 65000;
  if (distance < 80000) return 75000;
  if (distance < 90000) return 85000;
  return 100000;
}

function normalizeUidSet(raw) {
  if (!Array.isArray(raw)) return new Set();
  return new Set(
    raw.map((v) => String(v ?? '').trim()).filter((v) => v.length > 0),
  );
}

// Real-time counterpart to scripts/process-secure-actions.js for the
// follow/unfollow/remove-follower/cancel-request action types: the client
// cannot write another user's doc directly under strict Firestore rules, so
// it enqueues an intent here and this trigger applies the target-side update
// (followers/following arrays on both `users` and `users_public`, plus the
// +50 follow score) the moment the intent is created.
const FOLLOW_ACTION_TYPES = new Set([
  'follow_user',
  'unfollow_user',
  'remove_follower',
  'cancel_follow_request',
]);

async function processFollowUserAction(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!targetUid || targetUid === actorUid) return;

  const myUserRef = db.collection('users').doc(actorUid);
  const targetUserRef = db.collection('users').doc(targetUid);
  const myPublicRef = db.collection('users_public').doc(actorUid);
  const targetPublicRef = db.collection('users_public').doc(targetUid);

  await db.runTransaction(async (tx) => {
    const [mySnap, targetSnap] = await Promise.all([
      tx.get(myUserRef),
      tx.get(targetUserRef),
    ]);
    if (!mySnap.exists || !targetSnap.exists) return;

    const myData = mySnap.data() || {};
    const targetData = targetSnap.data() || {};

    const myFollowing = normalizeUidSet(myData.following);
    const targetFollowers = normalizeUidSet(targetData.followers);
    const targetRequests = normalizeUidSet(targetData.followRequests);
    const targetFollowing = normalizeUidSet(targetData.following);
    const currentTargetScore = Number(targetData.score ?? 0) || 0;

    const isPrivate = Boolean(targetData.isPrivate ?? false);
    if (isPrivate) {
      const mySentRequests = normalizeUidSet(myData.sentFollowRequests);
      mySentRequests.add(targetUid);
      targetRequests.add(actorUid);
      tx.set(myUserRef, { sentFollowRequests: Array.from(mySentRequests) }, { merge: true });
      tx.set(targetUserRef, { followRequests: Array.from(targetRequests) }, { merge: true });
      return;
    }

    myFollowing.add(targetUid);
    targetFollowers.add(actorUid);

    tx.set(myUserRef, {
      following: Array.from(myFollowing),
      followingCount: myFollowing.size,
      sentFollowRequests: FieldValue.arrayRemove(targetUid),
    }, { merge: true });

    tx.set(targetUserRef, {
      followers: Array.from(targetFollowers),
      followersCount: targetFollowers.size,
      followRequests: FieldValue.arrayRemove(actorUid),
      score: currentTargetScore + 50,
    }, { merge: true });

    tx.set(myPublicRef, {
      following: Array.from(myFollowing).sort(),
      followingCount: myFollowing.size,
      followers: Array.from(normalizeUidSet(myData.followers)).sort(),
      followersCount: normalizeUidSet(myData.followers).size,
    }, { merge: true });

    tx.set(targetPublicRef, {
      followers: Array.from(targetFollowers).sort(),
      followersCount: targetFollowers.size,
      following: Array.from(targetFollowing).sort(),
      followingCount: targetFollowing.size,
      score: currentTargetScore + 50,
    }, { merge: true });
  });
}

async function processUnfollowUserAction(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!targetUid || targetUid === actorUid) return;

  const myUserRef = db.collection('users').doc(actorUid);
  const targetUserRef = db.collection('users').doc(targetUid);
  const myPublicRef = db.collection('users_public').doc(actorUid);
  const targetPublicRef = db.collection('users_public').doc(targetUid);

  await db.runTransaction(async (tx) => {
    const [mySnap, targetSnap] = await Promise.all([
      tx.get(myUserRef),
      tx.get(targetUserRef),
    ]);
    if (!mySnap.exists || !targetSnap.exists) return;

    const myData = mySnap.data() || {};
    const targetData = targetSnap.data() || {};

    const myFollowing = normalizeUidSet(myData.following);
    const mySentRequests = normalizeUidSet(myData.sentFollowRequests);
    const targetFollowers = normalizeUidSet(targetData.followers);
    const targetRequests = normalizeUidSet(targetData.followRequests);
    const targetFollowing = normalizeUidSet(targetData.following);
    const currentTargetScore = Number(targetData.score ?? 0) || 0;

    myFollowing.delete(targetUid);
    mySentRequests.delete(targetUid);
    const wasFollowing = targetFollowers.delete(actorUid);
    targetRequests.delete(actorUid);

    // Mirror the +50 awarded on follow so repeated follow/unfollow cycles
    // don't leave the target's score permanently inflated.
    const nextTargetScore = wasFollowing
      ? Math.max(0, currentTargetScore - 50)
      : currentTargetScore;

    tx.set(myUserRef, {
      following: Array.from(myFollowing),
      followingCount: myFollowing.size,
      sentFollowRequests: Array.from(mySentRequests),
    }, { merge: true });

    tx.set(targetUserRef, {
      followers: Array.from(targetFollowers),
      followersCount: targetFollowers.size,
      followRequests: Array.from(targetRequests),
      score: nextTargetScore,
    }, { merge: true });

    tx.set(myPublicRef, {
      following: Array.from(myFollowing).sort(),
      followingCount: myFollowing.size,
      followers: Array.from(normalizeUidSet(myData.followers)).sort(),
      followersCount: normalizeUidSet(myData.followers).size,
    }, { merge: true });

    tx.set(targetPublicRef, {
      followers: Array.from(targetFollowers).sort(),
      followersCount: targetFollowers.size,
      following: Array.from(targetFollowing).sort(),
      followingCount: targetFollowing.size,
      score: nextTargetScore,
    }, { merge: true });
  });
}

async function processRemoveFollowerAction(actorUid, payload) {
  const followerUid = String(payload.followerUid ?? '').trim();
  if (!followerUid || followerUid === actorUid) return;

  const myUserRef = db.collection('users').doc(actorUid);
  const followerUserRef = db.collection('users').doc(followerUid);
  const myPublicRef = db.collection('users_public').doc(actorUid);
  const followerPublicRef = db.collection('users_public').doc(followerUid);

  await db.runTransaction(async (tx) => {
    const [mySnap, followerSnap] = await Promise.all([
      tx.get(myUserRef),
      tx.get(followerUserRef),
    ]);
    if (!mySnap.exists || !followerSnap.exists) return;

    const myData = mySnap.data() || {};
    const followerData = followerSnap.data() || {};

    const myFollowers = normalizeUidSet(myData.followers);
    const myFollowing = normalizeUidSet(myData.following);
    const followerFollowing = normalizeUidSet(followerData.following);
    const followerFollowers = normalizeUidSet(followerData.followers);

    myFollowers.delete(followerUid);
    followerFollowing.delete(actorUid);

    tx.set(myUserRef, {
      followers: Array.from(myFollowers),
      followersCount: myFollowers.size,
    }, { merge: true });

    tx.set(followerUserRef, {
      following: Array.from(followerFollowing),
      followingCount: followerFollowing.size,
    }, { merge: true });

    tx.set(myPublicRef, {
      followers: Array.from(myFollowers).sort(),
      followersCount: myFollowers.size,
      following: Array.from(myFollowing).sort(),
      followingCount: myFollowing.size,
    }, { merge: true });

    tx.set(followerPublicRef, {
      followers: Array.from(followerFollowers).sort(),
      followersCount: followerFollowers.size,
      following: Array.from(followerFollowing).sort(),
      followingCount: followerFollowing.size,
    }, { merge: true });
  });
}

async function processCancelFollowRequestAction(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!targetUid || targetUid === actorUid) return;

  const myRef = db.collection('users').doc(actorUid);
  const targetRef = db.collection('users').doc(targetUid);

  await Promise.all([
    myRef.set({ sentFollowRequests: FieldValue.arrayRemove(targetUid) }, { merge: true }),
    targetRef.set({ followRequests: FieldValue.arrayRemove(actorUid) }, { merge: true }),
  ]);
}

exports.processFollowSecureAction = onDocumentCreated(
  { document: 'users/{uid}/secure_actions/{actionId}', region: REGION },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data() || {};
    const type = String(data.type ?? '').trim();
    if (!FOLLOW_ACTION_TYPES.has(type)) return;

    const actorUid = String(data.actorUid ?? '').trim();
    const payload = data.payload && typeof data.payload === 'object' ? data.payload : {};
    if (!actorUid) return;

    try {
      switch (type) {
        case 'follow_user':
          await processFollowUserAction(actorUid, payload);
          break;
        case 'unfollow_user':
          await processUnfollowUserAction(actorUid, payload);
          break;
        case 'remove_follower':
          await processRemoveFollowerAction(actorUid, payload);
          break;
        case 'cancel_follow_request':
          await processCancelFollowRequestAction(actorUid, payload);
          break;
        default:
          return;
      }

      await snapshot.ref.set({
        status: 'done',
        processedAt: FieldValue.serverTimestamp(),
        attempts: FieldValue.increment(1),
        lastError: '',
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    } catch (error) {
      await snapshot.ref.set({
        status: 'failed',
        attempts: FieldValue.increment(1),
        lastError: String(error?.message ?? error ?? 'unknown-error'),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      throw error;
    }
  },
);

exports.rankMeetNowPosts = onCall({ region: REGION, enforceAppCheck: true }, async (request) => {
  const viewerUid = request.auth?.uid;
  if (!viewerUid) throw new HttpsError('unauthenticated', 'Authentication is required.');
  if (!request.app) throw new HttpsError('failed-precondition', 'App Check is required.');

  const rateLimitRef = db.doc(`users/${viewerUid}/private/rank_meet_now_rate_limit`);
  await db.runTransaction(async (transaction) => {
    const now = Date.now();
    const previousCall = await transaction.get(rateLimitRef);
    const lastCalledAt = previousCall.get('lastCalledAt')?.toDate?.().getTime() ?? 0;
    if (now - lastCalledAt < RATE_LIMIT_MS) {
      throw new HttpsError('resource-exhausted', 'Please wait before refreshing again.');
    }
    transaction.set(rateLimitRef, {
      lastCalledAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  const requestedLimit = Number(request.data?.limit);
  const limit = Number.isFinite(requestedLimit)
    ? Math.max(60, Math.min(MAX_RESULTS, Math.floor(requestedLimit)))
    : 60;
  const viewerLocationSnapshot = await db.doc(`users/${viewerUid}/private/location`).get();
  const viewerLocation = viewerLocationSnapshot.get('geo');
  if (!viewerLocation) return { posts: [] };

  const postById = new Map();
  for (const precision of [5, 4, 3]) {
    const snapshots = await Promise.all(nearbyPrefixes(viewerLocation, precision).map((prefix) =>
      db.collection('meet_now_posts').where('status', '==', 'active').orderBy('geohash')
        .startAt(prefix).endAt(`${prefix}\uf8ff`).get()));
    for (const snapshot of snapshots) {
      for (const post of snapshot.docs) postById.set(post.id, post);
    }
    if (postById.size >= limit) break;
  }

  const now = Date.now();
  const candidates = [...postById.values()].filter((post) => {
    const createdAt = post.get('createdAt')?.toDate?.();
    return createdAt && now - createdAt.getTime() < POST_LIFETIME_MS && post.get('authorUid') !== viewerUid;
  });
  const authorUids = [...new Set(candidates.map((post) => String(post.get('authorUid') || '').trim()).filter(Boolean))];
  const locations = await db.getAll(...authorUids.map((uid) => db.doc(`users/${uid}/private/location`)));
  const reverseBlocks = await db.getAll(...authorUids.map((uid) => db.doc(`users/${uid}/blocked_users/${viewerUid}`)));
  const viewerBlocks = await db.getAll(...authorUids.map((uid) => db.doc(`users/${viewerUid}/blocked_users/${uid}`)));
  const locationByUid = new Map(locations.filter((doc) => doc.exists).map((doc) => [doc.ref.parent.parent.id, doc.get('geo')]));
  const blockedUids = new Set();
  authorUids.forEach((uid, index) => {
    if (reverseBlocks[index]?.exists || viewerBlocks[index]?.exists) blockedUids.add(uid);
  });
  const posts = candidates
    .filter((post) => !blockedUids.has(String(post.get('authorUid') || '').trim()))
    .map((post) => {
      const location = locationByUid.get(String(post.get('authorUid') || '').trim());
      return location ? { id: post.id, exactDistance: distanceInMeters(viewerLocation, location) } : null;
    })
    .filter(Boolean)
    .sort((first, second) => first.exactDistance - second.exactDistance)
    .slice(0, limit)
    .map((post, index) => ({
      id: post.id,
      distanceMeters: displayDistanceMeters(post.exactDistance),
      sortOrder: index,
    }));
  return { posts };
});