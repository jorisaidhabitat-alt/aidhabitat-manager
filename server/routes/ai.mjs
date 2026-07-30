import express from 'express';
import { requireAuth } from '../middleware/auth.mjs';
import {
  getLocalAiStatus,
  normalizeRewriteMode,
  rewriteNote,
} from '../ai/rewrite.mjs';

const router = express.Router();
const rateLimitBuckets = new Map();

const MAX_TEXT_LENGTH = 8_000;
const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000;
const RATE_LIMIT_MAX = 30;

const checkRateLimit = (userId) => {
  const key = String(userId || 'unknown');
  const now = Date.now();
  const bucket = rateLimitBuckets.get(key);
  if (!bucket || now - bucket.startedAt >= RATE_LIMIT_WINDOW_MS) {
    rateLimitBuckets.set(key, { startedAt: now, count: 1 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= RATE_LIMIT_MAX;
};

router.get('/api/ai/status', requireAuth, async (_req, res) => {
  const status = await getLocalAiStatus();
  res.json({
    success: true,
    error: null,
    data: status,
  });
});

router.post('/api/ai/rewrite', requireAuth, async (req, res, next) => {
  try {
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (text.length < 3) {
      res.status(400).json({
        success: false,
        error: 'La note est trop courte pour être reformulée.',
      });
      return;
    }
    if (text.length > MAX_TEXT_LENGTH) {
      res.status(413).json({
        success: false,
        error: `La note ne doit pas dépasser ${MAX_TEXT_LENGTH} caractères.`,
      });
      return;
    }

    const userKey = req.appUser?.id || req.appUser?.email;
    if (!checkRateLimit(userKey)) {
      res.status(429).json({
        success: false,
        error: 'Limite de reformulations atteinte. Réessayez plus tard.',
      });
      return;
    }

    const result = await rewriteNote({
      text,
      mode: normalizeRewriteMode(req.body?.mode),
    });
    res.json({
      success: true,
      error: null,
      data: result,
    });
  } catch (error) {
    next(error);
  }
});

export default router;
