const { initializeApp } = require('firebase-admin/app');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const { HttpsError, onCall } = require('firebase-functions/v2/https');

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