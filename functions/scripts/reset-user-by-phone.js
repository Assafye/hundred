'use strict';

const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');

const EXPECTED_PROJECT_ID = 'hundred-6c680';
const PROJECT_ID = String(process.env.PROJECT_ID ?? '').trim();
const PHONE = normalizeIsraeliPhone(process.env.PHONE);
const CONFIRM_PHONE = normalizeIsraeliPhone(process.env.CONFIRM_PHONE);
const EXECUTE = String(process.env.EXECUTE ?? 'false').toLowerCase() === 'true';

function normalizeIsraeliPhone(value) {
  const digits = String(value ?? '').replace(/\D/g, '');
  if (/^05\d{8}$/.test(digits)) return `+972${digits.slice(1)}`;
  if (/^9725\d{8}$/.test(digits)) return `+${digits}`;
  return '';
}

function maskUid(uid) {
  if (uid.length <= 10) return '***';
  return `${uid.slice(0, 6)}${'*'.repeat(uid.length - 10)}${uid.slice(-4)}`;
}

async function authUserByPhone(auth, phone) {
  try {
    return await auth.getUserByPhoneNumber(phone);
  } catch (error) {
    if (error?.code === 'auth/user-not-found') return null;
    throw error;
  }
}

async function authUserByUid(auth, uid) {
  try {
    return await auth.getUser(uid);
  } catch (error) {
    if (error?.code === 'auth/user-not-found') return null;
    throw error;
  }
}

async function queryDocuments(query) {
  const snapshot = await query.get();
  return snapshot.docs;
}

async function queryByFields(collection, fields, uid, { array = false } = {}) {
  const documents = new Map();
  for (const field of fields) {
    const query = array
      ? collection.where(field, 'array-contains', uid)
      : collection.where(field, '==', uid);
    for (const document of await queryDocuments(query)) {
      documents.set(document.ref.path, document);
    }
  }
  return [...documents.values()];
}

async function queryChildCollections(
  db,
  parentCollectionNames,
  childCollectionName,
  fields,
  uid,
) {
  const documents = new Map();
  for (const parentCollectionName of parentCollectionNames) {
    const parentRefs = await db.collection(parentCollectionName).listDocuments();
    for (let offset = 0; offset < parentRefs.length; offset += 20) {
      const chunk = parentRefs.slice(offset, offset + 20);
      const results = await Promise.all(chunk.map(async (parentRef) =>
        queryByFields(parentRef.collection(childCollectionName), fields, uid)
      ));
      for (const result of results) {
        for (const document of result) {
          documents.set(document.ref.path, document);
        }
      }
    }
  }
  return [...documents.values()];
}

async function resolveIdentity(auth, db) {
  const mappingRef = db.doc(`registered_phones/${PHONE}`);
  const [phoneUser, mappingSnapshot] = await Promise.all([
    authUserByPhone(auth, PHONE),
    mappingRef.get(),
  ]);
  const mappingUid = String(mappingSnapshot.get('uid') ?? '').trim();
  const authUid = String(phoneUser?.uid ?? '').trim();

  if (authUid && mappingUid && authUid !== mappingUid) {
    throw new Error('Auth and registered_phones resolve to different UIDs.');
  }

  const uid = authUid || mappingUid;
  if (!uid) {
    throw new Error('No account was found for the supplied phone.');
  }

  const uidUser = phoneUser ?? await authUserByUid(auth, uid);
  if (uidUser?.phoneNumber && normalizeIsraeliPhone(uidUser.phoneNumber) !== PHONE) {
    throw new Error('The resolved Auth user has a different phone number.');
  }

  return { uid, uidUser, mappingRef, mappingExists: mappingSnapshot.exists };
}

async function collectPlan(db, storage, uid) {
  const userRef = db.doc(`users/${uid}`);
  const userPublicRef = db.doc(`users_public/${uid}`);
  const presenceRef = db.doc(`user_presence/${uid}`);
  const [userSnapshot, publicSnapshot, presenceSnapshot, subcollections] =
    await Promise.all([
      userRef.get(),
      userPublicRef.get(),
      presenceRef.get(),
      userRef.listCollections(),
    ]);

  const subcollectionCounts = {};
  for (const collection of subcollections) {
    subcollectionCounts[collection.id] =
      (await collection.count().get()).data().count;
  }

  const [posts, comments, messages, notifications, meetNowPosts, reservations] =
    await Promise.all([
      queryByFields(db.collection('posts'), ['authorId', 'uid', 'userId'], uid),
      queryChildCollections(
        db,
        ['posts'],
        'comments',
        ['authorId', 'authorUid', 'uid'],
        uid,
      ),
      queryChildCollections(
        db,
        ['chats', 'groups'],
        'messages',
        ['senderId', 'senderUid', 'uid'],
        uid,
      ),
      queryChildCollections(
        db,
        ['users'],
        'notifications',
        ['actorUid'],
        uid,
      ),
      queryByFields(
        db.collection('meet_now_posts'),
        ['authorUid', 'authorId', 'uid'],
        uid,
      ),
      queryByFields(
        db.collection('phone_otp_identity_reservations'),
        ['uid'],
        uid,
      ),
    ]);

  const relationshipFields = [
    'followers',
    'following',
    'friends',
    'followRequests',
    'sentFollowRequests',
  ];
  const relationshipDocs = new Map();
  for (const field of relationshipFields) {
    const docs = await queryDocuments(
      db.collection('users').where(field, 'array-contains', uid),
    );
    for (const document of docs) {
      if (document.id === uid) continue;
      const entry = relationshipDocs.get(document.ref.path) ?? {
        document,
        fields: [],
      };
      entry.fields.push(field);
      relationshipDocs.set(document.ref.path, entry);
    }
  }

  const groupFields = ['members', 'membersList', 'participants', 'invitedFriendUids'];
  const groupDocs = new Map();
  for (const field of groupFields) {
    const docs = await queryDocuments(
      db.collection('groups').where(field, 'array-contains', uid),
    );
    for (const document of docs) {
      const entry = groupDocs.get(document.ref.path) ?? {
        document,
        fields: [],
      };
      entry.fields.push(field);
      groupDocs.set(document.ref.path, entry);
    }
  }
  const administeredGroups = await queryDocuments(
    db.collection('groups').where('adminUid', '==', uid),
  );

  const memberDocs = await queryChildCollections(
    db,
    ['groups'],
    'members',
    ['uid', 'userId', 'memberUid'],
    uid,
  );

  const bucket = storage.bucket();
  const [profileFiles] = await bucket.getFiles({
    prefix: `users/${uid}/`,
    autoPaginate: true,
  });

  return {
    userRef,
    userPublicRef,
    presenceRef,
    userExists: userSnapshot.exists,
    publicUserExists: publicSnapshot.exists,
    presenceExists: presenceSnapshot.exists,
    subcollections,
    subcollectionCounts,
    posts,
    comments,
    messages,
    notifications,
    meetNowPosts,
    reservations,
    relationshipDocs: [...relationshipDocs.values()],
    groupDocs: [...groupDocs.values()],
    administeredGroups,
    memberDocs,
    profileFiles,
  };
}

function printPlan(identity, plan) {
  console.log(JSON.stringify({
    mode: EXECUTE ? 'execute' : 'dry-run',
    projectId: PROJECT_ID,
    phone: PHONE.replace(/\d(?=\d{4})/g, '*'),
    uid: maskUid(identity.uid),
    authUserExists: Boolean(identity.uidUser),
    phoneMappingExists: identity.mappingExists,
    userExists: plan.userExists,
    publicUserExists: plan.publicUserExists,
    presenceExists: plan.presenceExists,
    privateSubcollections: plan.subcollectionCounts,
    sharedContentToAnonymize: {
      posts: plan.posts.length,
      comments: plan.comments.length,
      messages: plan.messages.length,
      notifications: plan.notifications.length,
    },
    privateDataToDelete: {
      meetNowPosts: plan.meetNowPosts.length,
      otpIdentityReservations: plan.reservations.length,
      relationshipDocuments: plan.relationshipDocs.length,
      groupMembershipDocuments: plan.memberDocs.length,
      groupsToDetach: plan.groupDocs.length,
      profileStorageObjects: plan.profileFiles.length,
    },
    administeredGroups: plan.administeredGroups.length,
  }, null, 2));
}

async function anonymizeDocuments(db, uid, plan) {
  const writer = db.bulkWriter();
  const deletedUser = 'משתמש מחוק';

  for (const document of plan.posts) {
    writer.set(document.ref, {
      authorName: deletedUser,
      authorUsername: '',
      authorHandle: '',
      authorProfileImg: '',
      authorProfileImageUrl: '',
      authorAvatarUrl: '',
    }, { merge: true });
  }
  for (const document of plan.comments) {
    writer.set(document.ref, {
      authorName: deletedUser,
      authorUsername: '',
      authorHandle: '',
      authorProfileImageUrl: '',
      authorAvatarUrl: '',
    }, { merge: true });
  }
  for (const document of plan.messages) {
    writer.set(document.ref, {
      senderName: deletedUser,
      senderAvatarUrl: '',
    }, { merge: true });
  }
  for (const document of plan.notifications) {
    writer.set(document.ref, {
      actorName: deletedUser,
      actorAvatarUrl: '',
    }, { merge: true });
  }

  for (const entry of plan.relationshipDocs) {
    const data = entry.document.data();
    const update = {};
    for (const field of entry.fields) {
      const values = Array.isArray(data[field]) ? data[field] : [];
      const filtered = values.filter((value) => String(value) !== uid);
      update[field] = filtered;
      if (field === 'followers' || field === 'following' || field === 'friends') {
        update[`${field}Count`] = filtered.length;
      }
    }
    writer.set(entry.document.ref, update, { merge: true });
  }

  for (const entry of plan.groupDocs) {
    const data = entry.document.data();
    const update = {};
    for (const field of entry.fields) {
      const values = Array.isArray(data[field]) ? data[field] : [];
      update[field] = values.filter((value) => String(value) !== uid);
    }
    const memberValues = Array.isArray(update.members)
      ? update.members
      : (Array.isArray(data.members) ? data.members : []);
    update.membersCount = memberValues.length;
    writer.set(entry.document.ref, update, { merge: true });
  }

  for (const document of plan.memberDocs) writer.delete(document.ref);
  for (const document of plan.meetNowPosts) writer.delete(document.ref);
  for (const document of plan.reservations) writer.delete(document.ref);
  if (plan.presenceExists) writer.delete(plan.presenceRef);

  await writer.close();
}

async function replaceProfilesWithTombstones(db, uid, plan) {
  await db.recursiveDelete(plan.userRef);
  const tombstone = {
    uid,
    isDeleted: true,
    isSearchable: false,
    searchPrefixes: [],
    displayName: 'משתמש מחוק',
    username: '',
    profilePictureUrl: '',
    profileImageUrls: [],
    deletedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  await Promise.all([
    plan.userRef.set(tombstone),
    plan.userPublicRef.set(tombstone),
  ]);
}

async function main() {
  if (PROJECT_ID !== EXPECTED_PROJECT_ID) {
    throw new Error(`PROJECT_ID must be exactly ${EXPECTED_PROJECT_ID}.`);
  }
  if (!PHONE) throw new Error('PHONE must be a valid Israeli mobile number.');
  if (EXECUTE && CONFIRM_PHONE !== PHONE) {
    throw new Error('CONFIRM_PHONE must match PHONE when EXECUTE=true.');
  }

  const app = initializeApp({
    projectId: PROJECT_ID,
    storageBucket: `${PROJECT_ID}.firebasestorage.app`,
  });
  const auth = getAuth(app);
  const db = getFirestore(app);
  const storage = getStorage(app);

  const identity = await resolveIdentity(auth, db);
  const plan = await collectPlan(db, storage, identity.uid);
  printPlan(identity, plan);
  if (!EXECUTE) {
    process.exit(0);
  }
  if (plan.administeredGroups.length > 0) {
    throw new Error('Reset aborted: the user administers one or more groups.');
  }

  await anonymizeDocuments(db, identity.uid, plan);
  await replaceProfilesWithTombstones(db, identity.uid, plan);
  await Promise.all(plan.profileFiles.map((file) => file.delete()));
  if (identity.uidUser) await auth.deleteUser(identity.uid);
  await identity.mappingRef.delete();
  console.log('SAFE_RESET_COMPLETED');
  process.exit(0);
}

main().catch((error) => {
  console.error(`SAFE_RESET_FAILED: ${error.message}`);
  process.exit(1);
});