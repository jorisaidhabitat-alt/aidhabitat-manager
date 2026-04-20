import express from 'express';
import fs from 'node:fs/promises';
import { requireAuth, requireAdmin } from '../middleware/auth.mjs';
import crypto from 'node:crypto';
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
  createRecord,
  callNocoTool,
  queryAll,
  field,
  TABLES,
  FIELD_SETS,
  buildLocalAuthUserPayload,
  getAdminAccessMembers,
  resolveClientMediaUrl,
  splitDisplayName,
  specialMemberProfile,
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
    // Nouveau : si `password` est fourni, on l'utilise directement au lieu
    // d'en générer un aléatoire. Permet au front admin de *définir* un
    // mot de passe précis (et pas seulement de le réinitialiser).
    const explicitPassword = typeof req.body?.password === 'string'
      ? req.body.password.trim()
      : '';
    if (explicitPassword && explicitPassword.length < 8) {
      res.status(400).json({
        success: false,
        error: 'Le mot de passe doit contenir au moins 8 caractères.',
      });
      return;
    }
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
      if (!forceReset && !explicitPassword && store.users[member.email]) continue;
      const password = explicitPassword || generatePassword(member.displayName);
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

// ---------------------------------------------------------------------------
// CRUD membres via NocoDB (table ergotherapeutes).
// Source de vérité : table NocoDB `ergotherapeutes`. Les credentials
// (salt + hash) restent dans authStore côté serveur mais leur création /
// suppression est pilotée par ces endpoints.
// ---------------------------------------------------------------------------

router.post('/api/admin/access-members', requireAdmin, async (req, res, next) => {
  try {
    const email = normalizeEmail(req.body?.email);
    const displayName = String(req.body?.displayName || '').trim();
    const role = String(req.body?.role || 'ERGO').toUpperCase() === 'ADMIN' ? 'ADMIN' : 'ERGO';
    const establishmentId = req.body?.establishmentId != null && String(req.body.establishmentId).trim() !== ''
      ? Number(req.body.establishmentId) || String(req.body.establishmentId).trim()
      : undefined;
    const explicitPassword = typeof req.body?.password === 'string'
      ? req.body.password.trim()
      : '';

    if (!email || !displayName) {
      res.status(400).json({ success: false, error: 'Email et nom sont requis.' });
      return;
    }
    if (explicitPassword && explicitPassword.length < 8) {
      res.status(400).json({ success: false, error: 'Mot de passe trop court (min 8).' });
      return;
    }

    // Vérifie l'absence de doublon via le registre (tolère les presets).
    const { members: existingMembers } = await loadMemberRegistry({ forceRefresh: true });
    if (existingMembers.find((m) => m.email === email)) {
      res.status(409).json({ success: false, error: 'Ce membre existe déjà.' });
      return;
    }

    const { prenom, nom } = splitDisplayName(displayName);
    const created = await createRecord(TABLES.ergotherapeutes, {
      uuid_source: crypto.randomUUID(),
      prenom,
      nom,
      email,
      ...(establishmentId !== undefined ? { etablissements_id: establishmentId } : {}),
      created_at: new Date().toISOString(),
    });

    // Provisionne les credentials immédiatement pour que le membre puisse
    // se connecter sans passer par un "reset".
    const store = await readAuthStore();
    const password = explicitPassword || generatePassword(displayName);
    const salt = randomSecret(16);
    store.users[email] = {
      salt,
      passwordHash: hashPassword(password, salt),
      createdAt: new Date().toISOString(),
    };
    store.pendingCredentials[email] = {
      displayName,
      password,
      role,
      createdAt: new Date().toISOString(),
    };
    await writeAuthStore(store);

    // Invalide le cache et récupère la fiche finale (membres + passwords).
    const { members } = await loadMemberRegistry({ forceRefresh: true });
    const freshMembers = await getAdminAccessMembers();
    const memberPayload = freshMembers.find((m) => m.email === email) || null;

    res.json({
      success: true,
      error: null,
      data: {
        member: memberPayload,
        password,
        ergoRecordId: created?.id ? String(created.id) : '',
        membersCount: members.length,
      },
    });
  } catch (error) {
    next(error);
  }
});

router.patch('/api/admin/access-members/:email', requireAdmin, async (req, res, next) => {
  try {
    const email = normalizeEmail(req.params.email);
    if (!email) {
      res.status(400).json({ success: false, error: 'Email manquant.' });
      return;
    }

    const displayName = req.body?.displayName != null
      ? String(req.body.displayName).trim()
      : null;
    const establishmentId = req.body?.establishmentId != null
      ? String(req.body.establishmentId).trim()
      : null;

    // Lookup record NocoDB par email.
    const records = await queryAll(TABLES.ergotherapeutes, { fields: FIELD_SETS.ergotherapeutes });
    const record = records.find((r) => normalizeEmail(field(r, 'email')) === email);
    if (!record) {
      res.status(404).json({ success: false, error: 'Membre introuvable.' });
      return;
    }

    const patch = {};
    if (displayName) {
      const { prenom, nom } = splitDisplayName(displayName);
      patch.prenom = prenom;
      patch.nom = nom;
    }
    if (establishmentId != null) {
      patch.etablissements_id = establishmentId
        ? (Number(establishmentId) || establishmentId)
        : null;
    }

    if (Object.keys(patch).length > 0) {
      await updateRecord(TABLES.ergotherapeutes, record.id, patch);
    }

    // Mise à jour du nom dans les credentials stockées (display_name utilisé
    // par la réinit random-password).
    if (displayName) {
      const store = await readAuthStore();
      if (store.pendingCredentials[email]) {
        store.pendingCredentials[email] = {
          ...store.pendingCredentials[email],
          displayName,
        };
        await writeAuthStore(store);
      }
    }

    await loadMemberRegistry({ forceRefresh: true });
    const members = await getAdminAccessMembers();
    const memberPayload = members.find((m) => m.email === email) || null;

    res.json({
      success: true,
      error: null,
      data: { member: memberPayload },
    });
  } catch (error) {
    next(error);
  }
});

router.delete('/api/admin/access-members/:email', requireAdmin, async (req, res, next) => {
  try {
    const email = normalizeEmail(req.params.email);
    if (!email) {
      res.status(400).json({ success: false, error: 'Email manquant.' });
      return;
    }

    // Garde-fou : refuser la suppression des 3 profils preset, sinon le
    // prochain `syncPresetMembersInErgos` les recréera en boucle.
    if (specialMemberProfile(email)) {
      res.status(400).json({
        success: false,
        error: 'Ce membre est protégé (profil preset) et ne peut pas être supprimé.',
      });
      return;
    }

    const records = await queryAll(TABLES.ergotherapeutes, { fields: FIELD_SETS.ergotherapeutes });
    const record = records.find((r) => normalizeEmail(field(r, 'email')) === email);
    if (record) {
      try {
        await callNocoTool('deleteRecords', {
          tableId: TABLES.ergotherapeutes,
          records: [{ id: String(record.id) }],
        });
      } catch (syncError) {
        console.error('[auth] suppression NocoDB ergos échouée', syncError);
        res.status(502).json({
          success: false,
          error: 'Échec suppression côté NocoDB.',
        });
        return;
      }
    }

    // Purge credentials locales.
    const store = await readAuthStore();
    delete store.users[email];
    delete store.pendingCredentials[email];
    await writeAuthStore(store);
    await loadMemberRegistry({ forceRefresh: true });

    res.json({ success: true, error: null, data: { email } });
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
