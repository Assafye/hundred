/*
  Secure actions worker (admin): processes client-enqueued intents that were
  blocked by strict Firestore rules and applies server-side global updates.

  Usage:
    node scripts/process-secure-actions.js

  Env:
    DRY_RUN=true|false   (default: true)
    LIMIT=200            (max actions to process in one run)
*/

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const fs = require('fs');
const path = require('path');

const DRY_RUN = (process.env.DRY_RUN ?? 'true').toLowerCase() !== 'false';
const LIMIT = Number(process.env.LIMIT ?? 200);

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
  togglePostLike: 'toggle_post_like',
  togglePostSave: 'toggle_post_save',
  registerPostShare: 'register_post_share',
  syncPostCommentSideEffects: 'sync_post_comment_side_effects',
  joinGroup: 'join_group',
  cancelGroupJoinRequest: 'cancel_group_join_request',
  inviteUserToGroup: 'invite_user_to_group',
  removeGroupMember: 'remove_group_member',
  leaveGroup: 'leave_group',
  updateGroupImage: 'update_group_image',
  joinPublicChat: 'join_public_chat',
};

function normalizeUidSet(raw) {
  if (!Array.isArray(raw)) return new Set();
  return new Set(
    raw
      .map((v) => String(v ?? '').trim())
      .filter((v) => v.length > 0)
  );
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
  return Math.floor(postScore / 5);
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

async function createNotification({ recipientUid, type, title, body = '', actorUid = '', postId = '', postImageUrl = '' }) {
  const uid = String(recipientUid ?? '').trim();
  if (!uid) return;

  if (DRY_RUN) return;

  const userRef = db.collection('users').doc(uid);
  const notifRef = userRef.collection('notifications').doc();
  const actor = String(actorUid ?? '').trim();

  await notifRef.set({
    recipientUid: uid,
    type,
    title: String(title ?? '').trim(),
    body: String(body ?? '').trim(),
    actorUid: actor,
    postId: String(postId ?? '').trim(),
    postImageUrl: String(postImageUrl ?? '').trim(),
    isRead: false,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  await userRef.set(
    { unreadNotificationsCount: FieldValue.increment(1) },
    { merge: true }
  );
}

async function processFollowUser(actorUid, payload) {
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
    }, { merge: true });

    tx.set(myPublicRef, {
      followingCount: myFollowing.size,
      followersCount: normalizeUidSet(myData.followers).size,
    }, { merge: true });

    tx.set(targetPublicRef, {
      followersCount: targetFollowers.size,
      followingCount: targetFollowing.size,
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
    targetFollowers.delete(actorUid);
    targetRequests.delete(actorUid);

    tx.set(myUserRef, {
      following: Array.from(myFollowing),
      followingCount: myFollowing.size,
      sentFollowRequests: Array.from(mySentRequests),
    }, { merge: true });

    tx.set(targetUserRef, {
      followers: Array.from(targetFollowers),
      followersCount: targetFollowers.size,
      followRequests: Array.from(targetRequests),
    }, { merge: true });

    tx.set(myPublicRef, {
      followingCount: myFollowing.size,
      followersCount: normalizeUidSet(myData.followers).size,
    }, { merge: true });

    tx.set(targetPublicRef, {
      followersCount: targetFollowers.size,
      followingCount: targetFollowing.size,
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
      followersCount: myFollowers.size,
      followingCount: myFollowing.size,
    }, { merge: true });

    tx.set(followerPublicRef, {
      followersCount: followerFollowers.size,
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
  if (authorId && authorId !== actorUid) {
    await incrementUserScoreIfExists(authorId, didAddLike ? 1 : -1);
    if (didAddLike) {
      await createNotification({
        recipientUid: authorId,
        type: 'post_like',
        title: 'אהבו את הפוסט שלך',
        body: 'משתמש אהב את הפוסט שלך',
        actorUid,
        postId,
        postImageUrl: String(postAfter.imageUrl ?? postAfter.mediaUrl ?? '').trim(),
      });
    }
  }
}

async function processTogglePostSave(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  if (!postId) return;

  const postRef = db.collection('posts').doc(postId);
  const savedPostRef = db.collection('users').doc(actorUid).collection('saved_posts').doc(postId);
  let postBefore = null;
  let postAfter = null;
  let didAddSave = false;

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
  if (authorId && authorId !== actorUid) {
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
    }
  }
}

async function processRegisterPostShare(actorUid, payload) {
  const postId = String(payload.postId ?? '').trim();
  if (!postId) return;

  const postRef = db.collection('posts').doc(postId);
  let postBefore = null;
  let postAfter = null;

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
  if (authorId && authorId !== actorUid) {
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

  await db.runTransaction(async (tx) => {
    const [postSnap, commentSnap] = await Promise.all([tx.get(postRef), tx.get(commentRef)]);
    if (!postSnap.exists || !commentSnap.exists) return;

    const commentData = commentSnap.data() || {};
    if (String(commentData.authorId ?? '').trim() !== actorUid) return;
    if (commentData.sideEffectsApplied === true) return;

    postBefore = postSnap.data() || {};
    postImageUrl = String(postBefore.imageUrl ?? postBefore.mediaUrl ?? '').trim();

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

    if (parentRef) {
      const parentSnap = await tx.get(parentRef);
      if (parentSnap.exists) {
        const parentData = parentSnap.data() || {};
        parentCommentAuthor = String(parentData.authorId ?? '').trim();
        const replyCount = Number(parentData.replyCount ?? 0) || 0;
        tx.set(parentRef, {
          replyCount: replyCount + 1,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }
  });

  if (!postAfter || !postBefore) return;

  await syncTaggedScoreFromPostDelta(postBefore, postAfter);

  const effectivePostAuthor = String(postAfter.authorId ?? postAuthorId).trim();
  if (effectivePostAuthor && effectivePostAuthor !== actorUid) {
    await incrementUserScoreIfExists(effectivePostAuthor, 2);
    await createNotification({
      recipientUid: effectivePostAuthor,
      type: 'post_comment',
      title: 'תגובה חדשה לפוסט שלך',
      body: commentText || 'משתמש הגיב על הפוסט שלך',
      actorUid,
      postId,
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
      postImageUrl,
    });
  }
}

async function processJoinGroup(actorUid, payload) {
  const groupId = String(payload.groupId ?? '').trim();
  if (!groupId) return;

  const groupRef = db.collection('groups').doc(groupId);
  const memberRef = groupRef.collection('members').doc(actorUid);
  const chatRef = db.collection('chats').doc(groupId);

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
    case ACTION_TYPE.togglePostLike:
      await processTogglePostLike(actorUid, payload);
      return;
    case ACTION_TYPE.togglePostSave:
      await processTogglePostSave(actorUid, payload);
      return;
    case ACTION_TYPE.registerPostShare:
      await processRegisterPostShare(actorUid, payload);
      return;
    case ACTION_TYPE.syncPostCommentSideEffects:
      await processCommentSideEffects(actorUid, payload);
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

async function run() {
  console.log(`[secure-actions] start dryRun=${DRY_RUN} limit=${LIMIT}`);

  const pendingSnap = await db
    .collectionGroup('secure_actions')
    .where('status', '==', ACTION_STATUS.pending)
    .limit(LIMIT)
    .get();

  console.log(`[secure-actions] pending=${pendingSnap.size}`);

  let done = 0;
  let failed = 0;

  for (const actionDoc of pendingSnap.docs) {
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

  console.log('[secure-actions] summary');
  console.log(JSON.stringify({ dryRun: DRY_RUN, scanned: pendingSnap.size, done, failed }, null, 2));
}

run().catch((error) => {
  console.error('[secure-actions] fatal', error);
  process.exitCode = 1;
});
