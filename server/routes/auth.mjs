import express from 'express';
import fs from 'node:fs/promises';
import { requireAuth, requireAdmin } from '../middleware/auth.mjs';
import {
  normalizeEmail,
  hashPassword,
  generatePassword,
  randomSecret,
  signSessionToken,
  loadMemberRegistryForAuth,
  loadMemberRegistry,
  readAuthStore,
  writeAuthStore,
  parseImageDataUrl,
  updateRecord,
  TABLES,
  buildLocalAuthUserPayload,
  getAdminAccessMembers,
  resolveClientMediaUrl,
  PROFILE_PHOTOS_DIR_URL,
} from '../helpers.mjs';

const router = express.Router();

router.post('/api/auth/login', async (req, res, next) => {
  try {
    const email = normalizeEmail(req.body?.email);
    const password = String(req.body?.password || '');
    const { members, store } = await loadMemberRegistryForAuth();
    const member = members.find((entry) => entry.email === email);

    if (!member) {
      res.status(401).json({ success: false, error: 'Adresse mail non autorisée' });
      return;
    }

    const credentials = store.users[email];
    if (!credentials) {
      res.status(401).json({ success: false, error: 'Aucun mot de passe généré pour ce membre' });
      return;
    }

    const isValid = credentials.passwordHash === hashPassword(password, credentials.salt);
    if (!isValid) {
      res.status(401).json({ success: false, error: 'Mot de passe incorrect' });
      return;
    }

    const token = await signSessionToken(email);
    res.json({
      success: true,
      error: null,
      data: {
        token,
        user: member,
      },
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/auth/session', requireAuth, async (req, res) => {
  res.json({
    success: true,
    error: null,
    data: { user: req.appUser },
  });
});

router.get('/api/auth/local-state', requireAuth, async (req, res, next) => {
  try {
    const { members } = await loadMemberRegistryForAuth();
    const currentUser = req.appUser;
    const visibleMembers = currentUser?.role === 'ADMIN'
      ? members
      : members.filter((member) => member.email === currentUser?.email);

    res.json({
      success: true,
      error: null,
      data: {
        users: visibleMembers.map(buildLocalAuthUserPayload),
        syncedAt: new Date().toISOString(),
      },
    });
  } catch (error) {
    next(error);
  }
});

router.post('/api/auth/logout', requireAuth, async (_req, res) => {
  res.json({ success: true, error: null });
});

router.post('/api/profile/photo', requireAuth, async (req, res, next) => {
  try {
    const imageDataUrl = String(req.body?.imageDataUrl || '').trim();
    if (!imageDataUrl) {
      res.status(400).json({ success: false, error: 'Image manquante' });
      return;
    }

    const currentUser = req.appUser;
    if (!currentUser?.email) {
      res.status(400).json({ success: false, error: 'Utilisateur introuvable' });
      return;
    }

    const { extension, buffer } = parseImageDataUrl(imageDataUrl);
    if (buffer.length > 5 * 1024 * 1024) {
      res.status(400).json({ success: false, error: 'Image trop volumineuse' });
      return;
    }

    await fs.mkdir(PROFILE_PHOTOS_DIR_URL, { recursive: true });
    const safeEmail = currentUser.email.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
    const fileName = `${safeEmail}-${Date.now()}.${extension}`;
    const filePath = new URL(fileName, PROFILE_PHOTOS_DIR_URL);
    await fs.writeFile(filePath, buffer);

    const relativeUrl = `/uploads/profile-photos/${fileName}`;
    const store = await readAuthStore();
    const credentials = store.users[currentUser.email];
    if (credentials) {
      store.users[currentUser.email] = {
        ...credentials,
        profilePhotoUrl: relativeUrl,
      };
      await writeAuthStore(store);
    }

    if (currentUser.ergoRecordId) {
      try {
        await updateRecord(TABLES.ergotherapeutes, currentUser.ergoRecordId, {
          nom_etablissement_id: relativeUrl,
        });
      } catch (error) {
        console.warn('[profile-photo] sync NocoDB impossible, photo conservée localement.', error);
      }
    }

    const { members } = await loadMemberRegistry({ forceRefresh: true });
    const refreshedUser = members.find((member) => member.email === currentUser.email) || currentUser;

    res.json({
      success: true,
      error: null,
      data: {
        user: refreshedUser,
        photoUrl: resolveClientMediaUrl(relativeUrl),
      },
    });
  } catch (error) {
    next(error);
  }
});

router.post('/api/auth/provision', requireAdmin, async (req, res, next) => {
  try {
    const requestedEmail = normalizeEmail(req.body?.email);
    const forceReset = Boolean(req.body?.forceReset);
    const { members } = await loadMemberRegistry({ forceRefresh: true });
    const store = await readAuthStore();
    const targets = requestedEmail
      ? members.filter((member) => member.email === requestedEmail)
      : members;

    if (targets.length === 0) {
      throw new Error('Aucun membre correspondant');
    }

    const generated = [];

    for (const member of targets) {
      if (!forceReset && store.users[member.email]) continue;
      const password = generatePassword(member.displayName);
      const salt = randomSecret(16);
      store.users[member.email] = {
        salt,
        passwordHash: hashPassword(password, salt),
        createdAt: new Date().toISOString(),
      };
      store.pendingCredentials[member.email] = {
        displayName: member.displayName,
        password,
        role: member.role,
        createdAt: new Date().toISOString(),
      };
      generated.push({
        email: member.email,
        displayName: member.displayName,
        role: member.role,
        password,
      });
    }

    await writeAuthStore(store);
    res.json({ success: true, error: null, data: { generated } });
  } catch (error) {
    next(error);
  }
});

router.get('/api/admin/access-members', requireAdmin, async (_req, res, next) => {
  try {
    const members = await getAdminAccessMembers();
    res.json({
      success: true,
      error: null,
      data: { members },
    });
  } catch (error) {
    next(error);
  }
});

export default router;
