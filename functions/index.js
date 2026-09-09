const { initializeApp } = require('firebase-admin/app');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const {
  processPendingSecureActions: runPendingSecureActions,
  processSingleAction,
} = require('./secure_actions_processor');

initializeApp();
const db = getFirestore();
const messaging = getMessaging();
const REGION = 'europe-west3';
const MAX_RESULTS = 360;
const POST_LIFETIME_MS = 24 * 60 * 60 * 1000;
const RATE_LIMIT_MS = 10 * 1000;
const GEOHASH_ALPHABET = '0123456789bcdefghjkmnpqrstuvwxyz';

function collectFcmTokens(data) {
  const tokens = new Set();
  const tokenList = Array.isArray(data.fcmTokenList) ? data.fcmTokenList : [];
  for (const token of tokenList) {
    const normalized = String(token ?? '').trim();
    if (normalized) tokens.add(normalized);
  }

  function collectFromMap(value, prefix = '') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return;
    for (const [key, child] of Object.entries(value)) {
      const path = prefix ? `${prefix}.${key}` : key;
      if (child === true) {
        const normalized = path.trim();
        if (normalized) tokens.add(normalized);
      } else {
        collectFromMap(child, path);
      }
    }
  }

  collectFromMap(data.fcmTokens || {});
  return [...tokens];
}

function notificationImageUrlFromData(data = {}) {
  const type = String(data.type ?? '').trim();
  const postImageUrl = String(data.postImageUrl ?? '').trim();
  const actorAvatarUrl = String(data.actorAvatarUrl ?? '').trim();
  const chatAvatarUrl = String(data.chatAvatarUrl ?? data.groupImageUrl ?? '').trim();
  const isGroupChat = data.isGroupChat === true || String(data.isGroupChat ?? '').toLowerCase() === 'true';

  if (['post_like', 'post_comment', 'comment_reply', 'post_save', 'weekly_stars'].includes(type)) {
    return postImageUrl;
  }
  if (type === 'pop_join' || type === 'new_follower' || type === 'new_friend') {
    return actorAvatarUrl;
  }
  if (type === 'group_join' || type === 'added_to_group') {
    return chatAvatarUrl || actorAvatarUrl;
  }
  if (type === 'new_message') {
    return isGroupChat ? (chatAvatarUrl || actorAvatarUrl) : actorAvatarUrl;
  }
  return postImageUrl || chatAvatarUrl || actorAvatarUrl;
}

function isHttpUrl(value) {
  try {
    const url = new URL(String(value ?? '').trim());
    return url.protocol === 'https:' || url.protocol === 'http:';
  } catch (_) {
    return false;
  }
}

async function resolveNotificationImageUrlForFcm(rawUrl) {
  const candidate = String(rawUrl ?? '').trim();
  if (!candidate || !isHttpUrl(candidate)) return '';

  try {
    const response = await fetch(candidate, {
      method: 'GET',
      redirect: 'follow',
      signal: AbortSignal.timeout(2500),
      headers: { range: 'bytes=0-0' },
    });
    await response.body?.cancel?.();

    const contentType = String(response.headers.get('content-type') ?? '').toLowerCase();
    if (!response.ok || !contentType.startsWith('image/')) {
      return '';
    }
    return response.url || candidate;
  } catch (_) {
    return candidate;
  }
}

function notificationDataPayload(notificationId, data, recipientUid = '', imageUrl = '') {
  const payload = { notificationId };
  const normalizedRecipientUid = String(recipientUid ?? data.recipientUid ?? '').trim();
  if (normalizedRecipientUid) payload.recipientUid = normalizedRecipientUid;
  const notificationImageUrl = String(imageUrl || notificationImageUrlFromData(data)).trim();
  if (notificationImageUrl) payload.notificationImageUrl = notificationImageUrl;
  for (const key of [
    'type',
    'postId',
    'chatId',
    'groupId',
    'commentId',
    'actorUid',
    'actorName',
    'actorAvatarUrl',
    'postImageUrl',
    'chatName',
    'chatAvatarUrl',
    'groupName',
    'groupImageUrl',
    'isGroupChat',
  ]) {
    const value = String(data[key] ?? '').trim();
    if (value) payload[key] = value;
  }
  return payload;
}

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

exports.processFollowSecureAction = onDocumentCreated(
  { document: 'users/{uid}/secure_actions/{actionId}', region: REGION },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data() || {};
    const actorUid = String(data.actorUid ?? '').trim();
    const type = String(data.type ?? '').trim();
    if (!actorUid || !type) return;

    try {
      // Every secure_action type (follow/unfollow, likes, saves, shares,
      // comments, comment likes, comment deletion cascades, group/chat
      // actions) is processed immediately here with admin rights, the
      // moment the client enqueues it — not just follow-related ones. The
      // scheduled sweep below remains only as a retry safety net for
      // anything that fails on this first attempt.
      await processSingleAction(snapshot);

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

exports.sendPushForNotification = onDocumentWritten(
  { document: 'users/{uid}/notifications/{notificationId}', region: REGION },
  async (event) => {
    // Fires on create AND update (e.g. a like notification is upserted per post,
    // not recreated), so every new like/comment/etc. also replaces the prior push.
    const snapshot = event.data?.after;
    if (!snapshot || !snapshot.exists) return;

    const uid = String(event.params.uid ?? '').trim();
    if (!uid) return;

    const data = snapshot.data() || {};
    const title = String(data.title ?? '').trim();
    const body = String(data.body ?? '').trim();
    if (!title && !body) return;

    const userSnap = await db.collection('users').doc(uid).get();
    if (!userSnap.exists) return;

    const tokens = collectFcmTokens(userSnap.data() || {});
    if (!tokens.length) return;

    const notificationImageUrl = await resolveNotificationImageUrlForFcm(
      notificationImageUrlFromData(data)
    );
    const response = await messaging.sendEachForMulticast({
      tokens,
      notification: {
        title,
        body,
        ...(notificationImageUrl ? { imageUrl: notificationImageUrl } : {}),
      },
      data: notificationDataPayload(snapshot.id, data, uid, notificationImageUrl),
      android: {
        priority: 'high',
        notification: {
          channelId: 'hundred_notifications',
          tag: snapshot.id,
          priority: 'high',
          defaultSound: true,
          ...(notificationImageUrl ? { imageUrl: notificationImageUrl } : {}),
        },
      },
      apns: {
        headers: {
          'apns-collapse-id': snapshot.id.slice(0, 64),
        },
        payload: {
          aps: {
            sound: 'default',
            ...(notificationImageUrl ? { mutableContent: true } : {}),
          },
        },
        ...(notificationImageUrl
          ? { fcmOptions: { imageUrl: notificationImageUrl } }
          : {}),
      },
    });

    if (response.failureCount > 0) {
      console.warn('Push notification failures', {
        uid,
        notificationId: snapshot.id,
        failureCount: response.failureCount,
      });
    }
  },
);

exports.processPendingSecureActions = onSchedule(
  {
    region: REGION,
    schedule: 'every 2 minutes',
    timeZone: 'Asia/Jerusalem',
    maxInstances: 1,
    retryCount: 3,
  },
  async () => {
    const result = await runPendingSecureActions({ limit: 200 });
    console.log('Secure actions scheduled run completed', result);
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