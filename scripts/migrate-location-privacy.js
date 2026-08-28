/*
  One-time location privacy migration.

  Moves exact user coordinates to users/{uid}/private/location, replaces each
  Pop's exact geo with a coarse discoveryGeo cell, and removes legacy exact
  location fields. Dry run is enabled by default.
*/

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, GeoPoint } = require('firebase-admin/firestore');
const fs = require('fs');
const path = require('path');

const DRY_RUN = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 300);
const DISCOVERY_PRECISION = 5;
const GEOHASH_ALPHABET = '0123456789bcdefghjkmnpqrstuvwxyz';

function resolveProjectId() {
  return process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT ||
    process.env.FIREBASE_PROJECT_ID || (() => {
      try {
        const config = JSON.parse(fs.readFileSync(path.join(process.cwd(), '.firebaserc'), 'utf8'));
        return config?.projects?.default || '';
      } catch (_) {
        return '';
      }
    })();
}

initializeApp(resolveProjectId() ? { projectId: resolveProjectId() } : undefined);
const db = getFirestore();

function geoPointFrom(data) {
  const geo = data.geo;
  if (geo && typeof geo.latitude === 'number' && typeof geo.longitude === 'number') return geo;
  if (typeof data.latitude === 'number' && typeof data.longitude === 'number') {
    return new GeoPoint(data.latitude, data.longitude);
  }
  return null;
}

function spans(precision) {
  const bits = precision * 5;
  return {
    latitude: 180 / (2 ** Math.floor(bits / 2)),
    longitude: 360 / (2 ** Math.ceil(bits / 2)),
  };
}

function snapToCellCenter(point, precision) {
  const step = spans(precision);
  const latitudeIndex = Math.floor((point.latitude + 90) / step.latitude);
  const longitudeIndex = Math.floor((point.longitude + 180) / step.longitude);
  return new GeoPoint(
    Math.max(-89.999999, Math.min(89.999999, -90 + ((latitudeIndex + 0.5) * step.latitude))),
    Math.max(-180, Math.min(180, -180 + ((longitudeIndex + 0.5) * step.longitude))),
  );
}

function encodeGeoHash(point, precision) {
  let minLatitude = -90;
  let maxLatitude = 90;
  let minLongitude = -180;
  let maxLongitude = 180;
  let longitudeTurn = true;
  let bit = 0;
  let charIndex = 0;
  let value = '';
  while (value.length < precision) {
    if (longitudeTurn) {
      const midpoint = (minLongitude + maxLongitude) / 2;
      if (point.longitude >= midpoint) {
        charIndex = (charIndex << 1) | 1;
        minLongitude = midpoint;
      } else {
        charIndex <<= 1;
        maxLongitude = midpoint;
      }
    } else {
      const midpoint = (minLatitude + maxLatitude) / 2;
      if (point.latitude >= midpoint) {
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
      value += GEOHASH_ALPHABET[charIndex];
      bit = 0;
      charIndex = 0;
    }
  }
  return value;
}

async function commitIfNeeded(state, force = false) {
  if (!state.writes || (!force && state.writes < BATCH_SIZE)) return;
  await state.batch.commit();
  state.batch = db.batch();
  state.writes = 0;
}

async function run() {
  console.log(`[location-privacy] starting. dryRun=${DRY_RUN} batchSize=${BATCH_SIZE}`);
  const [users, posts] = await Promise.all([
    db.collection('users').get(),
    db.collection('meet_now_posts').get(),
  ]);
  const state = { batch: db.batch(), writes: 0 };
  let migratedUsers = 0;
  let sanitizedPosts = 0;

  for (const user of users.docs) {
    const location = geoPointFrom(user.data() || {});
    if (!location) continue;
    migratedUsers += 1;
    if (!DRY_RUN) {
      state.batch.set(user.ref.collection('private').doc('location'), {
        geo: location,
        latitude: location.latitude,
        longitude: location.longitude,
        locationUpdatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      state.batch.set(user.ref, {
        geo: FieldValue.delete(),
        latitude: FieldValue.delete(),
        longitude: FieldValue.delete(),
        locationUpdatedAt: FieldValue.delete(),
      }, { merge: true });
      state.writes += 2;
      await commitIfNeeded(state);
    }
  }

  for (const post of posts.docs) {
    const exactLocation = geoPointFrom(post.data() || {});
    if (!exactLocation) continue;
    sanitizedPosts += 1;
    if (!DRY_RUN) {
      const discoveryGeo = snapToCellCenter(exactLocation, DISCOVERY_PRECISION);
      state.batch.set(post.ref, {
        geo: FieldValue.delete(),
        latitude: FieldValue.delete(),
        longitude: FieldValue.delete(),
        discoveryGeo,
        geohash: encodeGeoHash(discoveryGeo, DISCOVERY_PRECISION),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      state.writes += 1;
      await commitIfNeeded(state);
    }
  }

  if (!DRY_RUN) await commitIfNeeded(state, true);
  console.log(JSON.stringify({ dryRun: DRY_RUN, users: users.size, migratedUsers, posts: posts.size, sanitizedPosts }, null, 2));
}

run().catch((error) => {
  console.error('[location-privacy] failed', error);
  process.exitCode = 1;
});