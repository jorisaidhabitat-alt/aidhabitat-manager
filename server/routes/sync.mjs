import express from 'express';
import { requireAuth, requireAdmin } from '../middleware/auth.mjs';
import { mobileSyncStore } from '../helpers.mjs';

const router = express.Router();

router.get('/api/mobile-sync/schema', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: {
        mode: await mobileSyncStore.getMode(),
        schema: mobileSyncStore.schemaSpec,
      },
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/mobile-sync/migration-status', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: await mobileSyncStore.getMigrationStatus(),
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/mobile-sync/schema-check', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: await mobileSyncStore.getSchemaCheck(),
    });
  } catch (error) {
    next(error);
  }
});

router.post('/api/mobile-sync/migrate', requireAdmin, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: await mobileSyncStore.migrateLocalToNocodb(),
    });
  } catch (error) {
    next(error);
  }
});

export default router;
