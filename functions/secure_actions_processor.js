const { getApps, initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

if (getApps().length === 0) {
  initializeApp();
}
const db = getFirestore();
let DRY_RUN = false;

const ACTION_STATUS = {
  pending: 'pending',
  processing: 'processing',
  done: 'done',
  failed: 'failed',
};

const ACTION_TYPE = {
  followUser: 'follow_user',
  unfollowUser: 'unfollow_user',
  removeFollower: 'remove_follower',
  cancelFollowRequest: 'cancel_follow_request',
  approveFollowRequest: 'approve_follow_request',
  togglePostLike: 'toggle_post_like',
  togglePostSave: 'toggle_post_save',
  syncCommentLikeScore: 'sync_comment_like_score',
  syncUserScoreDelta: 'sync_user_score_delta',
  registerPostShare: 'register_post_share',
  syncPostCommentSideEffects: 'sync_post_comment_side_effects',
  deletePostCommentCascade: 'delete_post_comment_cascade',
  createNotification: 'create_notification',
  reconcilePostLikeNotification: 'reconcile_post_like_notification',
  deletePostSaveNotification: 'delete_post_save_notification',
  deletePostCommentNotifications: 'delete_post_comment_notifications',
  joinGroup: 'join_group',
  cancelGroupJoinRequest: 'cancel_group_join_request',
  inviteUserToGroup: 'invite_user_to_group',
  removeGroupMember: 'remove_group_member',
  leaveGroup: 'leave_group',
  updateGroupImage: 'update_group_image',
  joinPublicChat: 'join_public_chat',
};

const NOTIFICATION_SETTING_BY_TYPE = {
  post_like: 'postLikes',
  post_save: 'postSaves',
  new_message: 'newMessages',
  post_comment: 'postComments',
  comment_reply: 'commentReplies',
  pop_join: 'popJoins',
  group_join: 'groupJoins',
  added_to_group: 'addedToGroups',
  weekly_challenge_updated: 'weeklyChallengeUpdates',
  daily_challenge_updated: 'dailyChallengeUpdates',
  spontaneous_reminder: 'spontaneousReminders',
  spontaneous_time_warning: 'spontaneousTimeWarnings',
  weekly_stars: 'weeklyStars',
  new_follower: 'newFollowers',
  new_friend: 'newFriends',
};

function normalizeUidSet(raw) {
  if (!Array.isArray(raw)) return new Set();
  return new Set(
    raw
      .map((v) => String(v ?? '').trim())
      .filter((v) => v.length > 0)
  );
}

async function actorSummary(uid) {
  const normalizedUid = String(uid ?? '').trim();
  if (!normalizedUid) {
    return { uid: '', name: 'משתמש', avatarUrl: '' };
  }

  const publicSnap = await db.collection('users_public').doc(normalizedUid).get();
  const privateSnap = publicSnap.exists
    ? null
    : await db.collection('users').doc(normalizedUid).get();
  const data = publicSnap.exists ? (publicSnap.data() || {}) : (privateSnap?.data() || {});
  const name = String(
    data.displayName ??
    data.username ??
    data.name ??
    ''
  ).trim().replace(/^@/, '');
  const avatarUrl = String(
    data.profilePictureUrl ??
    data.profileImageUrl ??
    data.avatarUrl ??
    ''
  ).trim();

  return {
    uid: normalizedUid,
    name: name || 'משתמש',
    avatarUrl,
  };
}

function postScoreFromData(data = {}) {
  const scoreAwarded = Number(data.scoreAwarded ?? 0) || 0;
  const likesCount = Number(data.likesCount ?? (Array.isArray(data.likes) ? data.likes.length : 0)) || 0;
  const commentsCount = Number(data.commentsCount ?? 0) || 0;
  const sharesCount = Number(data.sharesCount ?? 0) || 0;
  const savesCount = Number(data.savesCount ?? (Array.isArray(data.savedBy) ? data.savedBy.length : 0)) || 0;
  return scoreAwarded + likesCount + commentsCount * 2 + sharesCount * 3 + savesCount;
}

function taggedBonusForPostScore(postScore) {
  if (postScore <= 0) return 0;
  return Math.ceil(postScore / 5);
}

function taggedParticipantUids(postData = {}) {
  const authorId = String(postData.authorId ?? '').trim();
  const members = Array.isArray(postData.members)
    ? postData.members
    : Array.isArray(postData.participants)
      ? postData.participants
      : [];
  return new Set(
    members
      .map((v) => String(v ?? '').trim())
      .filter((uid) => uid && uid !== authorId)
  );
}

async function markAction(ref, patch) {
  if (DRY_RUN) return;
  await ref.set(
    {
      ...patch,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

async function incrementUserScoreIfExists(uid, delta) {
  const normalizedUid = String(uid ?? '').trim();
  if (!normalizedUid || !delta) return;

  const userRef = db.collection('users').doc(normalizedUid);
  const publicRef = db.collection('users_public').doc(normalizedUid);
  const [userSnap, publicSnap] = await Promise.all([userRef.get(), publicRef.get()]);

  if (!DRY_RUN) {
    if (userSnap.exists) {
      await userRef.set({ score: FieldValue.increment(delta) }, { merge: true });
    }
    if (publicSnap.exists) {
      await publicRef.set({ score: FieldValue.increment(delta) }, { merge: true });
    }
  }
}

async function syncTaggedScoreFromPostDelta(postBefore, postAfter) {
  const oldBonus = taggedBonusForPostScore(postScoreFromData(postBefore));
  const newBonus = taggedBonusForPostScore(postScoreFromData(postAfter));
  const delta = newBonus - oldBonus;
  if (!delta) return;

  const tagged = taggedParticipantUids(postAfter);
  for (const uid of tagged) {
    await incrementUserScoreIfExists(uid, delta);
  }
}

async function isNotificationEnabled(recipientUid, type) {
  const settingKey = NOTIFICATION_SETTING_BY_TYPE[String(type ?? '').trim()];
  if (!settingKey) return true;

  const userSnap = await db.collection('users').doc(recipientUid).get();
  const settings = userSnap.data()?.notificationSettings || {};
  return settings[settingKey] !== false;
}

async function createNotification({
  recipientUid,
  type,
  title,
  body = '',
  actorUid = '',
  actorName = '',
  actorAvatarUrl = '',
  postId = '',
  postImageUrl = '',
  chatId = '',
  groupId = '',
  groupName = '',
  commentId = '',
  extra = {},
}) {
  const uid = String(recipientUid ?? '').trim();
  if (!uid) return;

  const notificationType = String(type ?? '').trim();
  if (!notificationType) return;

  if (!(await isNotificationEnabled(uid, notificationType))) return;

  if (DRY_RUN) return;

  const userRef = db.collection('users').doc(uid);
  const notifRef = userRef.collection('notifications').doc();
  const actor = String(actorUid ?? '').trim();
  const actorProfile = await actorSummary(actor);
  const resolvedActorName = String(actorName ?? '').trim() || actorProfile.name;
  const resolvedActorAvatarUrl =
    String(actorAvatarUrl ?? '').trim() || actorProfile.avatarUrl;

  await notifRef.set({
    recipientUid: uid,
    type: notificationType,
    title: String(title ?? '').trim(),
    body: String(body ?? '').trim(),
    actorUid: actor,
    actorName: resolvedActorName,
    actorAvatarUrl: resolvedActorAvatarUrl,
    postId: String(postId ?? '').trim(),
    postImageUrl: String(postImageUrl ?? '').trim(),
    chatId: String(chatId ?? '').trim(),
    groupId: String(groupId ?? '').trim(),
    groupName: String(groupName ?? '').trim(),
    commentId: String(commentId ?? '').trim(),
    isRead: false,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    ...(extra && typeof extra === 'object' ? extra : {}),
  });

  await userRef.set(
    { unreadNotificationsCount: FieldValue.increment(1) },
    { merge: true }
  );
}

async function deleteNotificationDocs(docs) {
  if (!docs.length || DRY_RUN) return;

  const unreadByUserPath = new Map();
  const batch = db.batch();
  for (const doc of docs) {
    const isRead = Boolean(doc.get('isRead') ?? false);
    if (!isRead) {
      const userRef = doc.ref.parent.parent;
      if (userRef) {
        unreadByUserPath.set(
          userRef.path,
          (unreadByUserPath.get(userRef.path) ?? 0) + 1,
        );
      }
    }
    batch.delete(doc.ref);
  }
  for (const [path, count] of unreadByUserPath.entries()) {
    batch.set(db.doc(path), {
      unreadNotificationsCount: FieldValue.increment(-count),
    }, { merge: true });
  }
  await batch.commit();
}

async function queryUserNotifications(uid, filters) {
  let query = db.collection('users').doc(uid).collection('notifications');
  for (const [field, value] of filters) {
    query = query.where(field, '==', value);
  }
  const snapshot = await query.get();
  return snapshot.docs;
}

async function upsertPostLikeNotification({
  recipientUid,
  postId,
  actorUid,
  postImageUrl = '',
  likeCount,
  currentLikeUids = null,
}) {
  const recipient = String(recipientUid ?? '').trim();
  const normalizedPostId = String(postId ?? '').trim();
  if (!recipient || !normalizedPostId) return;
  if (!(await isNotificationEnabled(recipient, 'post_like'))) return;

  const canonicalRef = db
    .collection('users')
    .doc(recipient)
    .collection('notifications')
    .doc(`post_like_${normalizedPostId}`);

  const canonicalSnap = await canonicalRef.get();
  const existing = canonicalSnap.data() || {};
  const normalizedActorUid = String(actorUid ?? '').trim();
  const likes = Array.isArray(currentLikeUids)
    ? currentLikeUids.map((uid) => String(uid ?? '').trim()).filter(Boolean)
    : null;
  const resolvedLikeCount = Number.isFinite(Number(likeCount))
    ? Math.max(0, Number(likeCount) || 0)
    : (likes ? likes.length : 1);

  if (resolvedLikeCount <= 0 || (likes && likes.length === 0)) {
    if (canonicalSnap.exists) await deleteNotificationDocs([canonicalSnap]);
    return;
  }

  const existingRecent = Array.isArray(existing.recentLikeActorUids)
    ? existing.recentLikeActorUids.map((uid) => String(uid ?? '').trim()).filter(Boolean)
    : [];
  const allowedLikes = likes ? new Set(likes) : null;
  const recent = [];
  const addRecent = (uid) => {
    const normalized = String(uid ?? '').trim();
    if (!normalized || normalized === recipient) return;
    if (allowedLikes && !allowedLikes.has(normalized)) return;
    if (!recent.includes(normalized)) recent.push(normalized);
  };

  addRecent(normalizedActorUid);
  for (const uid of existingRecent) addRecent(uid);
  if (likes) {
    for (const uid of likes) addRecent(uid);
  }

  const recentActorUids = recent.slice(0, 3);
  const primaryActorUid = recentActorUids[0] || normalizedActorUid;
  const primaryActor = await actorSummary(primaryActorUid);
  const recentProfiles = await Promise.all(recentActorUids.map(actorSummary));
  const recentAvatarUrls = recentProfiles
    .map((profile) => profile.avatarUrl)
    .filter(Boolean);

  const wasRead = Boolean(existing.isRead ?? false);
  const payload = {
    recipientUid: recipient,
    type: 'post_like',
    title: `${primaryActor.name} עשה לך לייק על הפוסט`,
    body: `יש לך עכשיו ${resolvedLikeCount} לייקים על הפוסט`,
    actorUid: primaryActor.uid,
    actorName: primaryActor.name,
    actorAvatarUrl: primaryActor.avatarUrl,
    postId: normalizedPostId,
    postImageUrl: String(postImageUrl || existing.postImageUrl || '').trim(),
    isRead: canonicalSnap.exists ? wasRead : false,
    likeCount: resolvedLikeCount,
    recentLikeActorUids,
    recentLikeActorAvatarUrls: recentAvatarUrls,
    updatedAt: FieldValue.serverTimestamp(),
    ...(canonicalSnap.exists ? {} : { createdAt: FieldValue.serverTimestamp() }),
  };

  await canonicalRef.set(payload, { merge: true });
  if (!canonicalSnap.exists) {
    await db.collection('users').doc(recipient).set(
      { unreadNotificationsCount: FieldValue.increment(1) },
      { merge: true }
    );
  }
}

async function deletePostSaveNotification({ recipientUid, postId, actorUid }) {
  const recipient = String(recipientUid ?? '').trim();
  const normalizedPostId = String(postId ?? '').trim();
  const actor = String(actorUid ?? '').trim();
  if (!recipient || !normalizedPostId || !actor) return;

  const docs = await queryUserNotifications(recipient, [
    ['type', 'post_save'],
    ['postId', normalizedPostId],
    ['actorUid', actor],
  ]);
  await deleteNotificationDocs(docs);
}

async function deletePostCommentNotifications({ postId, comments, postAuthorId = '' }) {
  const normalizedPostId = String(postId ?? '').trim();
  if (!normalizedPostId || !Array.isArray(comments) || comments.length === 0) return;

  const docsToDelete = [];
  const seenPaths = new Set();
  const addDocs = async (recipientUid, filters) => {
    const recipient = String(recipientUid ?? '').trim();
    if (!recipient) return;
    const docs = await queryUserNotifications(recipient, filters);
    for (const doc of docs) {
      if (seenPaths.has(doc.ref.path)) continue;
      seenPaths.add(doc.ref.path);
      docsToDelete.push(doc);
    }
  };

  for (const comment of comments) {
    const commentId = String(comment.id ?? comment.commentId ?? '').trim();
    if (!commentId) continue;
    const authorId = String(comment.authorId ?? '').trim();
    const parentAuthorId = String(comment.parentAuthorId ?? '').trim();
    const recipientPostAuthor = String(comment.postAuthorId ?? postAuthorId).trim();

    await addDocs(recipientPostAuthor, [
      ['type', 'post_comment'],
      ['postId', normalizedPostId],
      ['commentId', commentId],
    ]);
    await addDocs(parentAuthorId, [
      ['type', 'comment_reply'],
      ['postId', normalizedPostId],
      ['commentId', commentId],
    ]);

    // Older reply notifications used the parent comment id instead of the
    // reply id. Limit the cleanup by actor to avoid deleting unrelated replies.
    const parentId = String(comment.parentId ?? '').trim();
    if (parentId && authorId) {
      await addDocs(parentAuthorId, [
        ['type', 'comment_reply'],
        ['postId', normalizedPostId],
        ['commentId', parentId],
        ['actorUid', authorId],
      ]);
    }
  }

  await deleteNotificationDocs(docsToDelete);
}

async function processCreateNotification(actorUid, payload) {
  const recipientUid = String(payload.recipientUid ?? '').trim();
  if (!recipientUid || recipientUid === actorUid) return;

  if (String(payload.type ?? '').trim() === 'post_like') {
    const postId = String(payload.postId ?? '').trim();
    const postSnap = postId ? await db.collection('posts').doc(postId).get() : null;
    if (!postSnap?.exists) return;
    const postData = postSnap?.data() || {};
    const currentLikeUids = Array.isArray(postData.likes) ? postData.likes : null;
    await upsertPostLikeNotification({
      recipientUid,
      postId,
      actorUid: currentLikeUids?.map((uid) => String(uid ?? '').trim()).includes(actorUid)
        ? actorUid
        : '',
      postImageUrl: payload.postImageUrl ?? postData.imageUrl ?? postData.mediaUrl,
      likeCount: currentLikeUids ? currentLikeUids.length : payload.likeCount,
      currentLikeUids,
    });
    return;
  }

  const type = String(payload.type ?? '').trim();
  const postId = String(payload.postId ?? '').trim();
  if (type === 'post_save' && postId) {
    const postSnap = await db.collection('posts').doc(postId).get();
    const savedBy = normalizeUidSet(postSnap.data()?.savedBy);
    if (!savedBy.has(actorUid)) return;
  }

  if ((type === 'post_comment' || type === 'comment_reply') && postId) {
    const commentId = String(payload.commentId ?? '').trim();
    if (commentId) {
      const commentSnap = await db
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .doc(commentId)
        .get();
      if (!commentSnap.exists) return;
    }
  }

  const reservedKeys = new Set([
    'recipientUid',
    'type',
    'title',
    'body',
    'actorUid',
    'actorName',
    'actorAvatarUrl',
    'postId',
    'postImageUrl',
    'chatId',
    'groupId',
    'groupName',
    'commentId',
    'isRead',
    'createdAt',
    'updatedAt',
  ]);
  const extra = {};
  for (const [key, value] of Object.entries(payload)) {
    if (!reservedKeys.has(key)) extra[key] = value;
  }

  await createNotification({
    recipientUid,
    type: payload.type,
    title: payload.title,
    body: payload.body,
    actorUid,
    actorName: payload.actorName,
    actorAvatarUrl: payload.actorAvatarUrl,
    postId: payload.postId,
    postImageUrl: payload.postImageUrl,
    chatId: payload.chatId,
    groupId: payload.groupId,
    groupName: payload.groupName,
    commentId: payload.commentId,
    extra,
  });
}

async function processFollowUser(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!targetUid || targetUid === actorUid) return;

  const myUserRef = db.collection('users').doc(actorUid);
  const targetUserRef = db.collection('users').doc(targetUid);
  const myPublicRef = db.collection('users_public').doc(actorUid);
  const targetPublicRef = db.collection('users_public').doc(targetUid);

  if (DRY_RUN) return;

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

    const isPrivate = Boolean(targetData.isPrivate ?? false);
    if (isPrivate) {
      mySentRequests.add(targetUid);
      targetRequests.add(actorUid);
      tx.set(myUserRef, {
        sentFollowRequests: Array.from(mySentRequests),
      }, { merge: true });
      tx.set(targetUserRef, {
        followRequests: Array.from(targetRequests),
      }, { merge: true });
      return;
    }

    const didCreateFollow = !targetFollowers.has(actorUid);
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
      ...(didCreateFollow ? { score: FieldValue.increment(50) } : {}),
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
      ...(didCreateFollow ? { score: FieldValue.increment(50) } : {}),
    }, { merge: true });
  });
}

async function processUnfollowUser(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!targetUid || targetUid === actorUid) return;

  const myUserRef = db.collection('users').doc(actorUid);
  const targetUserRef = db.collection('users').doc(targetUid);
  const myPublicRef = db.collection('users_public').doc(actorUid);
  const targetPublicRef = db.collection('users_public').doc(targetUid);

  if (DRY_RUN) return;

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

    myFollowing.delete(targetUid);
    mySentRequests.delete(targetUid);
    const wasFollowing = targetFollowers.delete(actorUid);
    targetRequests.delete(actorUid);

    // Mirror the +50 awarded on follow so repeated follow/unfollow cycles
    // don't leave the target's score permanently inflated. No score-dependent
    // guard: it would strand the +50 whenever the total dipped below 50.
    const canDeduct = wasFollowing;

    tx.set(myUserRef, {
      following: Array.from(myFollowing),
      followingCount: myFollowing.size,
      sentFollowRequests: Array.from(mySentRequests),
    }, { merge: true });

    tx.set(targetUserRef, {
      followers: Array.from(targetFollowers),
      followersCount: targetFollowers.size,
      followRequests: Array.from(targetRequests),
      ...(canDeduct ? { score: FieldValue.increment(-50) } : {}),
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
      ...(canDeduct ? { score: FieldValue.increment(-50) } : {}),
    }, { merge: true });
  });
}

async function processApproveFollowRequest(ownerUid, payload) {
  const requesterUid = String(payload.requesterUid ?? '').trim();
  if (!requesterUid || requesterUid === ownerUid || DRY_RUN) return;

  const ownerRef = db.collection('users').doc(ownerUid);
  const requesterRef = db.collection('users').doc(requesterUid);
  const ownerPublicRef = db.collection('users_public').doc(ownerUid);
  const requesterPublicRef = db.collection('users_public').doc(requesterUid);

  await db.runTransaction(async (tx) => {
    const [ownerSnap, requesterSnap] = await Promise.all([
      tx.get(ownerRef),
      tx.get(requesterRef),
    ]);
    if (!ownerSnap.exists || !requesterSnap.exists) return;

    const owner = ownerSnap.data() || {};
    const requester = requesterSnap.data() || {};
    const ownerFollowers = normalizeUidSet(owner.followers);
    const requesterFollowing = normalizeUidSet(requester.following);
    const wasFollowing = requesterFollowing.has(ownerUid);
    const hasRequest = normalizeUidSet(owner.followRequests).has(requesterUid) ||
      normalizeUidSet(requester.sentFollowRequests).has(ownerUid);
    if (!hasRequest && !wasFollowing) return;

    ownerFollowers.add(requesterUid);
    requesterFollowing.add(ownerUid);
    const didApprove = !wasFollowing;

    tx.set(ownerRef, {
      followers: Array.from(ownerFollowers),
      followersCount: ownerFollowers.size,
      followRequests: FieldValue.arrayRemove(requesterUid),
      ...(didApprove ? { score: FieldValue.increment(50) } : {}),
    }, { merge: true });
    tx.set(requesterRef, {
      following: Array.from(requesterFollowing),
      followingCount: requesterFollowing.size,
      sentFollowRequests: FieldValue.arrayRemove(ownerUid),
    }, { merge: true });
    tx.set(ownerPublicRef, {
      followers: Array.from(ownerFollowers).sort(),
      followersCount: ownerFollowers.size,
      ...(didApprove ? { score: FieldValue.increment(50) } : {}),
    }, { merge: true });
    tx.set(requesterPublicRef, {
      following: Array.from(requesterFollowing).sort(),
      followingCount: requesterFollowing.size,
    }, { merge: true });
  });
}

async function processRemoveFollower(actorUid, payload) {
  const followerUid = String(payload.followerUid ?? '').trim();
  if (!followerUid || followerUid === actorUid) return;

  const myUserRef = db.collection('users').doc(actorUid);
  const followerUserRef = db.collection('users').doc(followerUid);
  const myPublicRef = db.collection('users_public').doc(actorUid);
  const followerPublicRef = db.collection('users_public').doc(followerUid);

  if (DRY_RUN) return;

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

    const wasFollower = myFollowers.delete(followerUid);
    followerFollowing.delete(actorUid);

    tx.set(myUserRef, {
      followers: Array.from(myFollowers),
      followersCount: myFollowers.size,
      // Losing a follower undoes the +50 that follower granted.
      ...(wasFollower ? { score: FieldValue.increment(-50) } : {}),
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
      ...(wasFollower ? { score: FieldValue.increment(-50) } : {}),
    }, { merge: true });

    tx.set(followerPublicRef, {
      followers: Array.from(followerFollowers).sort(),
      followersCount: followerFollowers.size,
      following: Array.from(followerFollowing).sort(),
      followingCount: followerFollowing.size,
    }, { merge: true });
  });
}

async function processCancelFollowRequest(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!targetUid || targetUid === actorUid) return;

  const myRef = db.collection('users').doc(actorUid);
  const targetRef = db.collection('users').doc(targetUid);

  if (!DRY_RUN) {
    await Promise.all([
      myRef.set(
        { sentFollowRequests: FieldValue.arrayRemove(targetUid) },
        { merge: true }
      ),
      targetRef.set(
        { followRequests: FieldValue.arrayRemove(actorUid) },
        { merge: true }
      ),
    ]);
  }
}

async function processTogglePostLike(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  if (!postId) return;

  const postRef = db.collection('posts').doc(postId);
  let postAfter = null;
  let postBefore = null;
  let didAddLike = false;

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists) return;

    postBefore = postSnap.data() || {};
    const likes = normalizeUidSet(postBefore.likes);
    const hadLiked = likes.has(actorUid);
    if (hadLiked) {
      likes.delete(actorUid);
      didAddLike = false;
    } else {
      likes.add(actorUid);
      didAddLike = true;
    }

    postAfter = {
      ...postBefore,
      likes: Array.from(likes),
      likesCount: likes.size,
    };

    tx.set(postRef, {
      likes: Array.from(likes),
      likesCount: likes.size,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  if (!postAfter || !postBefore) return;

  await syncTaggedScoreFromPostDelta(postBefore, postAfter);

  const authorId = String(postAfter.authorId ?? payload.postAuthorId ?? '').trim();
  if (authorId) {
    await incrementUserScoreIfExists(authorId, didAddLike ? 1 : -1);
    await upsertPostLikeNotification({
      recipientUid: authorId,
      postId,
      actorUid: didAddLike ? actorUid : '',
      postImageUrl: String(postAfter.imageUrl ?? postAfter.mediaUrl ?? '').trim(),
      likeCount: Number(postAfter.likesCount ?? 0) || 0,
      currentLikeUids: Array.isArray(postAfter.likes) ? postAfter.likes : [],
    });
  }
}

async function processReconcilePostLikeNotification(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  const recipientUid = String(payload.recipientUid ?? payload.postAuthorId ?? '').trim();
  if (!postId || !recipientUid) return;

  const postSnap = await db.collection('posts').doc(postId).get();
  const postData = postSnap.data() || {};
  await upsertPostLikeNotification({
    recipientUid,
    postId,
    actorUid: '',
    postImageUrl: String(
      payload.postImageUrl ?? postData.imageUrl ?? postData.mediaUrl ?? ''
    ).trim(),
    likeCount: Number(postData.likesCount ?? 0) || 0,
    currentLikeUids: Array.isArray(postData.likes) ? postData.likes : [],
  });
}

async function processDeletePostSaveNotification(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  const recipientUid = String(payload.recipientUid ?? payload.postAuthorId ?? '').trim();
  if (!postId || !recipientUid) return;

  await deletePostSaveNotification({
    recipientUid,
    postId,
    actorUid,
  });
}

async function processDeletePostCommentNotifications(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  const comments = Array.isArray(payload.comments) ? payload.comments : [];
  if (!postId || comments.length === 0) return;

  await deletePostCommentNotifications({
    postId,
    comments,
    postAuthorId: payload.postAuthorId,
  });
}

async function processTogglePostSave(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  if (!postId) return;

  const postRef = db.collection('posts').doc(postId);
  const savedPostRef = db.collection('users').doc(actorUid).collection('saved_posts').doc(postId);
  let postBefore = null;
  let postAfter = null;
  let didAddSave = false;

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists) return;

    postBefore = postSnap.data() || {};
    const savedBy = normalizeUidSet(postBefore.savedBy);
    if (savedBy.has(actorUid)) {
      savedBy.delete(actorUid);
      didAddSave = false;
      tx.delete(savedPostRef);
    } else {
      savedBy.add(actorUid);
      didAddSave = true;
      tx.set(savedPostRef, {
        postId,
        authorId: String(postBefore.authorId ?? '').trim(),
        title: String(postBefore.title ?? '').trim(),
        description: String(postBefore.caption ?? postBefore.description ?? '').trim(),
        imageUrl: String(postBefore.mediaUrl ?? postBefore.imageUrl ?? '').trim(),
        mediaUrl: String(postBefore.mediaUrl ?? postBefore.imageUrl ?? '').trim(),
        category: String(postBefore.category ?? '').trim(),
        subCategory: String(postBefore.subCategory ?? '').trim(),
        createdAt: postBefore.createdAt ?? null,
        savedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    postAfter = {
      ...postBefore,
      savedBy: Array.from(savedBy),
      savesCount: savedBy.size,
    };

    tx.set(postRef, {
      savedBy: Array.from(savedBy),
      savesCount: savedBy.size,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  if (!postAfter || !postBefore) return;

  await syncTaggedScoreFromPostDelta(postBefore, postAfter);

  const authorId = String(postAfter.authorId ?? '').trim();
  if (authorId) {
    await incrementUserScoreIfExists(authorId, didAddSave ? 1 : -1);
    if (didAddSave) {
      await createNotification({
        recipientUid: authorId,
        type: 'post_save',
        title: 'שמרו את הפוסט שלך',
        body: 'משתמש שמר את הפוסט שלך',
        actorUid,
        postId,
        postImageUrl: String(postAfter.mediaUrl ?? postAfter.imageUrl ?? '').trim(),
      });
    } else {
      await deletePostSaveNotification({
        recipientUid: authorId,
        postId,
        actorUid,
      });
    }
  }
}

async function processRegisterPostShare(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  if (!postId) return;

  const postRef = db.collection('posts').doc(postId);
  let postBefore = null;
  let postAfter = null;

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists) return;

    postBefore = postSnap.data() || {};
    const shares = Number(postBefore.sharesCount ?? 0) || 0;
    postAfter = {
      ...postBefore,
      sharesCount: shares + 1,
    };

    tx.set(postRef, {
      sharesCount: shares + 1,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  if (!postAfter || !postBefore) return;

  await syncTaggedScoreFromPostDelta(postBefore, postAfter);

  const authorId = String(postAfter.authorId ?? payload.postAuthorId ?? '').trim();
  if (authorId) {
    await incrementUserScoreIfExists(authorId, 3);
  }
}

async function processCommentSideEffects(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  const commentId = String(payload.commentId ?? '').trim();
  const postAuthorId = String(payload.postAuthorId ?? '').trim();
  const parentCommentId = String(payload.parentCommentId ?? '').trim();
  const commentText = String(payload.commentText ?? '').trim();

  if (!postId || !commentId) return;

  const postRef = db.collection('posts').doc(postId);
  const commentRef = postRef.collection('comments').doc(commentId);
  const parentRef = parentCommentId ? postRef.collection('comments').doc(parentCommentId) : null;

  let postBefore = null;
  let postAfter = null;
  let parentCommentAuthor = '';
  let postImageUrl = '';

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const [postSnap, commentSnap, parentSnap] = await Promise.all([
      tx.get(postRef),
      tx.get(commentRef),
      parentRef ? tx.get(parentRef) : Promise.resolve(null),
    ]);
    if (!postSnap.exists || !commentSnap.exists) return;

    const commentData = commentSnap.data() || {};
    if (String(commentData.authorId ?? '').trim() !== actorUid) return;
    if (commentData.sideEffectsApplied === true) return;

    postBefore = postSnap.data() || {};
    postImageUrl = String(postBefore.imageUrl ?? postBefore.mediaUrl ?? '').trim();

    if (parentSnap && parentSnap.exists) {
      const parentData = parentSnap.data() || {};
      parentCommentAuthor = String(parentData.authorId ?? '').trim();
    }

    const currentComments = Number(postBefore.commentsCount ?? 0) || 0;
    postAfter = {
      ...postBefore,
      commentsCount: currentComments + 1,
    };

    tx.set(postRef, {
      commentsCount: currentComments + 1,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(commentRef, {
      sideEffectsApplied: true,
      sideEffectsAppliedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    if (parentSnap && parentSnap.exists) {
      const replyCount = Number(parentSnap.data()?.replyCount ?? 0) || 0;
      tx.set(parentRef, {
        replyCount: replyCount + 1,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  });

  if (!postAfter || !postBefore) return;

  await syncTaggedScoreFromPostDelta(postBefore, postAfter);

  const effectivePostAuthor = String(postAfter.authorId ?? postAuthorId).trim();
  const rewardUserIds = new Set();
  if (effectivePostAuthor) rewardUserIds.add(effectivePostAuthor);
  if (parentCommentAuthor) rewardUserIds.add(parentCommentAuthor);
  for (const rewardUid of rewardUserIds) {
    await incrementUserScoreIfExists(rewardUid, 2);
  }
  if (effectivePostAuthor) {
    await createNotification({
      recipientUid: effectivePostAuthor,
      type: 'post_comment',
      title: 'תגובה חדשה לפוסט שלך',
      body: commentText || 'משתמש הגיב על הפוסט שלך',
      actorUid,
      postId,
        commentId,
      postImageUrl,
    });
  }

  if (
    parentCommentAuthor &&
    parentCommentAuthor !== actorUid &&
    parentCommentAuthor !== effectivePostAuthor
  ) {
    await createNotification({
      recipientUid: parentCommentAuthor,
      type: 'comment_reply',
      title: 'תגובה חדשה לתגובה שלך',
      body: commentText || 'משתמש השיב לתגובה שלך',
      actorUid,
      postId,
      commentId,
      postImageUrl,
    });
  }
}

async function processCommentLikeScore(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  const commentId = String(payload.commentId ?? '').trim();
  const intendedLiked = payload.isLiked === true;
  if (!postId || !commentId || DRY_RUN) return;

  const commentRef = db.collection('posts').doc(postId).collection('comments').doc(commentId);
  const commentSnap = await commentRef.get();
  if (!commentSnap.exists) return;

  const comment = commentSnap.data() || {};
  const currentLiked = normalizeUidSet(comment.likes).has(actorUid);
  if (currentLiked !== intendedLiked) return;

  await incrementUserScoreIfExists(
    String(comment.authorId ?? '').trim(),
    intendedLiked ? 1 : -1,
  );
}

async function processUserScoreDelta(actorUid, payload) {
  const targetUid = String(payload.targetUid ?? '').trim();
  const delta = Number(payload.delta ?? 0) || 0;
  if (!targetUid || !delta) return;

  await incrementUserScoreIfExists(targetUid, delta);
}

async function processDeletePostCommentCascade(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  const postAuthorId = String(payload.postAuthorId ?? '').trim();
  const comments = Array.isArray(payload.comments) ? payload.comments : [];
  if (!postId || comments.length === 0) return;

  const postRef = db.collection('posts').doc(postId);
  const commentsRef = postRef.collection('comments');

  const deletedScoreDeltasByAuthor = new Map();
  const addDeltaFor = (uid, delta) => {
    const normalizedUid = String(uid ?? '').trim();
    if (!normalizedUid || !delta) return;
    deletedScoreDeltasByAuthor.set(
      normalizedUid,
      (deletedScoreDeltasByAuthor.get(normalizedUid) ?? 0) + delta,
    );
  };

  let taggedScoreDelta = 0;
  let taggedUids = new Set();
  const parentReplyCounts = new Map();

  if (!DRY_RUN) {
    await db.runTransaction(async (tx) => {
      const postSnap = await tx.get(postRef);
      if (!postSnap.exists) return;
      const postData = postSnap.data() || {};
      const resolvedPostAuthorId = String(postData.authorId ?? postAuthorId).trim();

      for (const comment of comments) {
        const commentId = String(comment.id ?? '').trim();
        if (!commentId) continue;
        const commentAuthorId = String(comment.authorId ?? '').trim();
        const likesCount = Number(comment.likesCount ?? 0) || 0;
        if (commentAuthorId && likesCount > 0) {
          addDeltaFor(commentAuthorId, -likesCount);
        }

        // Reverse the reward granted to the post owner / parent-comment
        // author when this comment was originally created (mirrors
        // _commentRewardUserIds in post_service.dart), regardless of
        // whether the parent comment is also being deleted.
        const parentAuthorId = String(comment.parentAuthorId ?? '').trim();
        const creationRewardUids = new Set();
        if (resolvedPostAuthorId) creationRewardUids.add(resolvedPostAuthorId);
        if (parentAuthorId) creationRewardUids.add(parentAuthorId);
        for (const rewardUid of creationRewardUids) {
          addDeltaFor(rewardUid, -2);
        }

        const parentId = String(comment.parentId ?? '').trim();
        if (parentId && !comments.some((c) => String(c.id ?? '').trim() === parentId)) {
          parentReplyCounts.set(parentId, (parentReplyCounts.get(parentId) ?? 0) + 1);
        }
        tx.delete(commentsRef.doc(commentId));
      }

      const removedCount = comments.length;
      const currentComments = Number(postData.commentsCount ?? 0) || 0;
      const nextComments = Math.max(0, currentComments - removedCount);
      tx.set(postRef, {
        commentsCount: nextComments,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });

      taggedScoreDelta = taggedBonusForPostScore(
        postScoreFromData({ ...postData, commentsCount: nextComments }),
      ) - taggedBonusForPostScore(postScoreFromData(postData));
      taggedUids = taggedParticipantUids(postData);

      for (const [parentId, removed] of parentReplyCounts) {
        const parentRef = commentsRef.doc(parentId);
        const parentSnap = await tx.get(parentRef);
        if (!parentSnap.exists) continue;
        const currentReplies = Number(parentSnap.data()?.replyCount ?? 0) || 0;
        tx.set(parentRef, {
          replyCount: Math.max(0, currentReplies - removed),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    });
  }

  for (const [uid, delta] of deletedScoreDeltasByAuthor) {
    await incrementUserScoreIfExists(uid, delta);
  }
  if (taggedScoreDelta) {
    for (const uid of taggedUids) {
      await incrementUserScoreIfExists(uid, taggedScoreDelta);
    }
  }

  await deletePostCommentNotifications({
    postId,
    comments,
    postAuthorId,
  });
}

async function processJoinGroup(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  if (!groupId) return;

  const groupRef = db.collection('groups').doc(groupId);
  const memberRef = groupRef.collection('members').doc(actorUid);
  const chatRef = db.collection('chats').doc(groupId);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const groupSnap = await tx.get(groupRef);
    if (!groupSnap.exists) return;

    const groupData = groupSnap.data() || {};
    const adminUid = String(groupData.adminUid ?? '').trim();
    if (actorUid === adminUid) return;

    const minScoreRequired = Boolean(groupData.isMinScoreRequired ?? false);
    const minScore = Number(groupData.minScore ?? 0) || 0;
    if (minScoreRequired && minScore > 0) {
      const userSnap = await tx.get(db.collection('users').doc(actorUid));
      const userScore = Number(userSnap.data()?.score ?? 0) || 0;
      if (userScore < minScore) return;
    }

    const memberSnap = await tx.get(memberRef);
    if (memberSnap.exists) return;

    const approvalRequired = Boolean(groupData.isAdminApprovalRequired ?? false);
    const status = approvalRequired ? 'pending' : 'approved';

    tx.set(memberRef, {
      uid: actorUid,
      status,
      role: 'member',
      joinedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    if (approvalRequired) {
      tx.set(groupRef, {
        pendingCount: FieldValue.increment(1),
      }, { merge: true });
      return;
    }

    tx.set(groupRef, {
      membersCount: FieldValue.increment(1),
      members: FieldValue.arrayUnion(actorUid),
      membersList: FieldValue.arrayUnion(actorUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(chatRef, {
      participants: FieldValue.arrayUnion(actorUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processCancelGroupJoinRequest(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  if (!groupId) return;

  const groupRef = db.collection('groups').doc(groupId);
  const memberRef = groupRef.collection('members').doc(actorUid);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const [groupSnap, memberSnap] = await Promise.all([tx.get(groupRef), tx.get(memberRef)]);
    if (!groupSnap.exists || !memberSnap.exists) return;

    const status = String(memberSnap.data()?.status ?? '').trim();
    if (status !== 'pending') return;

    tx.delete(memberRef);
    tx.set(groupRef, {
      pendingCount: FieldValue.increment(-1),
      invitedFriendUids: FieldValue.arrayRemove(actorUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processInviteUserToGroup(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!groupId || !targetUid || targetUid === actorUid) return;

  const groupRef = db.collection('groups').doc(groupId);
  const chatRef = db.collection('chats').doc(groupId);
  const targetMemberRef = groupRef.collection('members').doc(targetUid);
  const inviterMemberRef = groupRef.collection('members').doc(actorUid);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const [groupSnap, chatSnap] = await Promise.all([
      tx.get(groupRef),
      tx.get(chatRef),
    ]);
    if (!groupSnap.exists) return;

    const groupData = groupSnap.data() || {};
    const chatData = chatSnap.exists ? (chatSnap.data() || {}) : {};

    const adminUid = String(groupData.adminUid ?? '').trim();
    if (actorUid !== adminUid) {
      const inviterMemberSnap = await tx.get(inviterMemberRef);
      const inviterStatus = String(inviterMemberSnap.data()?.status ?? '').trim();
      const chatParticipants = normalizeUidSet(chatData.participants);
      const members = normalizeUidSet(groupData.members);
      const membersList = normalizeUidSet(groupData.membersList);
      const canInvite =
        inviterStatus === 'approved' ||
        chatParticipants.has(actorUid) ||
        members.has(actorUid) ||
        membersList.has(actorUid);
      if (!canInvite) return;
    }

    const targetMemberSnap = await tx.get(targetMemberRef);
    if (targetMemberSnap.exists) return;

    const isPublic = Boolean(groupData.isPublic ?? true);
    const approvalRequired = Boolean(groupData.isAdminApprovalRequired ?? false);
    const status = (!isPublic || approvalRequired) ? 'pending' : 'approved';

    tx.set(targetMemberRef, {
      uid: targetUid,
      status,
      role: 'member',
      invitedBy: actorUid,
      joinedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    if (status === 'pending') {
      tx.set(groupRef, {
        pendingCount: FieldValue.increment(1),
        invitedFriendUids: FieldValue.arrayUnion(targetUid),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    tx.set(groupRef, {
      membersCount: FieldValue.increment(1),
      members: FieldValue.arrayUnion(targetUid),
      membersList: FieldValue.arrayUnion(targetUid),
      invitedFriendUids: FieldValue.arrayUnion(targetUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(chatRef, {
      participants: FieldValue.arrayUnion(targetUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processRemoveGroupMember(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  const targetUid = String(payload.targetUid ?? '').trim();
  if (!groupId || !targetUid) return;

  const groupRef = db.collection('groups').doc(groupId);
  const memberRef = groupRef.collection('members').doc(targetUid);
  const chatRef = db.collection('chats').doc(groupId);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const [groupSnap, memberSnap] = await Promise.all([
      tx.get(groupRef),
      tx.get(memberRef),
    ]);
    if (!groupSnap.exists) return;

    const groupData = groupSnap.data() || {};
    const adminUid = String(groupData.adminUid ?? '').trim();
    if (actorUid !== adminUid || targetUid === adminUid) return;

    const status = String(memberSnap.data()?.status ?? '').trim();
    if (memberSnap.exists) {
      tx.delete(memberRef);
    }

    const updates = {
      members: FieldValue.arrayRemove(targetUid),
      membersList: FieldValue.arrayRemove(targetUid),
      invitedFriendUids: FieldValue.arrayRemove(targetUid),
      updatedAt: FieldValue.serverTimestamp(),
      ...(status === 'approved'
        ? { membersCount: FieldValue.increment(-1) }
        : status === 'pending'
          ? { pendingCount: FieldValue.increment(-1) }
          : {}),
    };
    tx.set(groupRef, updates, { merge: true });

    tx.set(chatRef, {
      participants: FieldValue.arrayRemove(targetUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processLeaveGroup(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  if (!groupId) return;

  const groupRef = db.collection('groups').doc(groupId);
  const memberRef = groupRef.collection('members').doc(actorUid);
  const chatRef = db.collection('chats').doc(groupId);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const [groupSnap, memberSnap] = await Promise.all([
      tx.get(groupRef),
      tx.get(memberRef),
    ]);
    if (!groupSnap.exists) return;

    const groupData = groupSnap.data() || {};
    const adminUid = String(groupData.adminUid ?? '').trim();
    if (actorUid === adminUid) return;

    const status = String(memberSnap.data()?.status ?? '').trim();
    if (memberSnap.exists) {
      tx.delete(memberRef);
    }

    const updates = {
      members: FieldValue.arrayRemove(actorUid),
      membersList: FieldValue.arrayRemove(actorUid),
      invitedFriendUids: FieldValue.arrayRemove(actorUid),
      updatedAt: FieldValue.serverTimestamp(),
      ...(status === 'approved'
        ? { membersCount: FieldValue.increment(-1) }
        : status === 'pending'
          ? { pendingCount: FieldValue.increment(-1) }
          : {}),
    };
    tx.set(groupRef, updates, { merge: true });

    tx.set(chatRef, {
      participants: FieldValue.arrayRemove(actorUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processJoinPublicChat(actorUid, payload) {
  const chatId = String(payload.chatId ?? '').trim();
  if (!chatId) return;

  const chatRef = db.collection('chats').doc(chatId);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const chatSnap = await tx.get(chatRef);
    if (!chatSnap.exists) return;

    const chatData = chatSnap.data() || {};
    const isPublic = Boolean(chatData.isPublic ?? false);
    if (!isPublic) return;

    const participants = normalizeUidSet(chatData.participants);
    if (participants.has(actorUid)) return;

    tx.set(chatRef, {
      participants: FieldValue.arrayUnion(actorUid),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processUpdateGroupImage(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  const groupImageUrl = String(payload.groupImageUrl ?? '').trim();
  if (!groupId || !groupImageUrl) return;

  const groupRef = db.collection('groups').doc(groupId);
  const chatRef = db.collection('chats').doc(groupId);
  const memberRef = groupRef.collection('members').doc(actorUid);

  if (DRY_RUN) return;

  await db.runTransaction(async (tx) => {
    const [groupSnap, memberSnap] = await Promise.all([
      tx.get(groupRef),
      tx.get(memberRef),
    ]);
    if (!groupSnap.exists) return;

    const groupData = groupSnap.data() || {};
    const adminUid = String(groupData.adminUid ?? '').trim();
    const isAllowed = actorUid === adminUid || memberSnap.exists;
    if (!isAllowed) return;

    tx.set(groupRef, {
      groupImageUrl,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(chatRef, {
      groupImageUrl,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

async function processSingleAction(actionDoc) {
  const data = actionDoc.data() || {};
  const actorUid = String(data.actorUid ?? '').trim();
  const type = String(data.type ?? '').trim();
  const payload = data.payload && typeof data.payload === 'object' ? data.payload : {};

  if (!actorUid || !type) {
    throw new Error('Missing actorUid/type');
  }

  switch (type) {
    case ACTION_TYPE.followUser:
      await processFollowUser(actorUid, payload);
      return;
    case ACTION_TYPE.unfollowUser:
      await processUnfollowUser(actorUid, payload);
      return;
    case ACTION_TYPE.removeFollower:
      await processRemoveFollower(actorUid, payload);
      return;
    case ACTION_TYPE.cancelFollowRequest:
      await processCancelFollowRequest(actorUid, payload);
      return;
    case ACTION_TYPE.approveFollowRequest:
      await processApproveFollowRequest(actorUid, payload);
      return;
    case ACTION_TYPE.togglePostLike:
      await processTogglePostLike(actorUid, payload);
      return;
    case ACTION_TYPE.togglePostSave:
      await processTogglePostSave(actorUid, payload);
      return;
    case ACTION_TYPE.syncCommentLikeScore:
      await processCommentLikeScore(actorUid, payload);
      return;
    case ACTION_TYPE.syncUserScoreDelta:
      await processUserScoreDelta(actorUid, payload);
      return;
    case ACTION_TYPE.registerPostShare:
      await processRegisterPostShare(actorUid, payload);
      return;
    case ACTION_TYPE.syncPostCommentSideEffects:
      await processCommentSideEffects(actorUid, payload);
      return;
    case ACTION_TYPE.deletePostCommentCascade:
      await processDeletePostCommentCascade(actorUid, payload);
      return;
    case ACTION_TYPE.createNotification:
      await processCreateNotification(actorUid, payload);
      return;
    case ACTION_TYPE.reconcilePostLikeNotification:
      await processReconcilePostLikeNotification(actorUid, payload);
      return;
    case ACTION_TYPE.deletePostSaveNotification:
      await processDeletePostSaveNotification(actorUid, payload);
      return;
    case ACTION_TYPE.deletePostCommentNotifications:
      await processDeletePostCommentNotifications(actorUid, payload);
      return;
    case ACTION_TYPE.joinGroup:
      await processJoinGroup(actorUid, payload);
      return;
    case ACTION_TYPE.cancelGroupJoinRequest:
      await processCancelGroupJoinRequest(actorUid, payload);
      return;
    case ACTION_TYPE.inviteUserToGroup:
      await processInviteUserToGroup(actorUid, payload);
      return;
    case ACTION_TYPE.removeGroupMember:
      await processRemoveGroupMember(actorUid, payload);
      return;
    case ACTION_TYPE.leaveGroup:
      await processLeaveGroup(actorUid, payload);
      return;
    case ACTION_TYPE.joinPublicChat:
      await processJoinPublicChat(actorUid, payload);
      return;
    case ACTION_TYPE.updateGroupImage:
      await processUpdateGroupImage(actorUid, payload);
      return;
    default:
      throw new Error(`Unknown action type: ${type}`);
  }
}

async function getPendingActions(limit) {
  const userRefs = await db.collection('users').listDocuments();
  const actions = [];
  let remaining = Math.max(0, Number(limit) || 0);

  for (const userRef of userRefs) {
    if (remaining <= 0) break;

    const pendingSnap = await userRef
      .collection('secure_actions')
      .where('status', '==', ACTION_STATUS.pending)
      .limit(remaining)
      .get();

    if (pendingSnap.empty) {
      continue;
    }

    actions.push(...pendingSnap.docs);
    remaining -= pendingSnap.docs.length;
  }

  return actions;
}

async function processPendingSecureActions({ limit = 200, dryRun = false } = {}) {
  const previousDryRun = DRY_RUN;
  DRY_RUN = dryRun;
  console.log(`[secure-actions] start dryRun=${DRY_RUN} limit=${limit}`);

  try {
    const pendingDocs = await getPendingActions(limit);

    console.log(`[secure-actions] pending=${pendingDocs.length}`);

    let done = 0;
    let failed = 0;

    for (const actionDoc of pendingDocs) {
      const ref = actionDoc.ref;
      const actionId = actionDoc.id;

      try {
        await markAction(ref, {
          status: ACTION_STATUS.processing,
        });

        await processSingleAction(actionDoc);

        await markAction(ref, {
          status: ACTION_STATUS.done,
          processedAt: FieldValue.serverTimestamp(),
          attempts: FieldValue.increment(1),
          lastError: '',
        });

        done += 1;
        console.log(`[secure-actions] done action=${actionId}`);
      } catch (error) {
        failed += 1;
        const message = String(error?.message ?? error ?? 'unknown-error');
        await markAction(ref, {
          status: ACTION_STATUS.failed,
          attempts: FieldValue.increment(1),
          lastError: message,
        });
        console.error(`[secure-actions] failed action=${actionId} error=${message}`);
      }
    }

    const result = { dryRun: DRY_RUN, scanned: pendingDocs.length, done, failed };
    console.log('[secure-actions] summary');
    console.log(JSON.stringify(result, null, 2));
    return result;
  } finally {
    DRY_RUN = previousDryRun;
  }
}

module.exports = { processPendingSecureActions, processSingleAction };
