import express from 'express';
import nodemailer from 'nodemailer';
import { resolveSessionUser } from '../helpers.mjs';

const router = express.Router();
const rateLimitBuckets = new Map();

const FEEDBACK_WINDOW_MS = 60 * 60 * 1000;
const FEEDBACK_MAX_PER_WINDOW = 12;
const FEEDBACK_SMTP_TIMEOUT_MS = 9000;

const clean = (value, max = 2000) => String(value || '').trim().slice(0, max);

const escapeHtml = (value) => clean(value, 10000)
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#039;');

const smtpConfig = () => {
  const host = clean(process.env.SMTP_HOST || process.env.NC_SMTP_HOST, 300);
  const port = Number(process.env.SMTP_PORT || process.env.NC_SMTP_PORT || 465);
  const user = clean(process.env.SMTP_USERNAME || process.env.NC_SMTP_USERNAME, 300);
  const pass = String(process.env.SMTP_PASSWORD || process.env.NC_SMTP_PASSWORD || '');
  const secureRaw = clean(process.env.SMTP_SECURE || process.env.NC_SMTP_SECURE || 'true', 10).toLowerCase();
  const secure = secureRaw !== 'false' && port !== 587;
  const from = clean(
    process.env.FEEDBACK_SMTP_FROM ||
      process.env.SMTP_FROM ||
      process.env.NC_SMTP_FROM ||
      user ||
      'contact@aidhabitat.fr',
    300,
  );
  const to = clean(process.env.FEEDBACK_TO || 'contact@aidhabitat.fr', 300);

  if (!host || !user || !pass) {
    return { ready: false, error: 'Configuration SMTP absente côté API.' };
  }

  return {
    ready: true,
    host,
    port,
    secure,
    auth: { user, pass },
    from,
    to,
  };
};

const formatContextText = (context = {}) => {
  const rows = [
    ['Page', context.page],
    ['Dossier', context.dossierName],
    ['ID dossier', context.dossierId],
    ['Section', context.section],
    ['Dernière action', context.lastAction],
    ['URL', context.url],
    ['User agent', context.userAgent],
    ['Date appareil', context.clientTimestamp],
  ];
  return rows
    .map(([label, value]) => `${label} : ${clean(value, 2000) || 'Non renseigné'}`)
    .join('\n');
};

const formatContextHtml = (context = {}) => {
  const rows = [
    ['Page', context.page],
    ['Dossier', context.dossierName],
    ['ID dossier', context.dossierId],
    ['Section', context.section],
    ['Dernière action', context.lastAction],
    ['URL', context.url],
    ['User agent', context.userAgent],
    ['Date appareil', context.clientTimestamp],
  ];
  return rows
    .map(([label, value]) => `
      <tr>
        <td style="padding:6px 10px;border-bottom:1px solid #eee;color:#6b7280">${escapeHtml(label)}</td>
        <td style="padding:6px 10px;border-bottom:1px solid #eee">${escapeHtml(value || 'Non renseigné')}</td>
      </tr>
    `)
    .join('');
};

const getClientIp = (req) => {
  const forwarded = String(req.get('x-forwarded-for') || '').split(',')[0].trim();
  return forwarded || req.ip || req.socket?.remoteAddress || 'unknown';
};

const checkRateLimit = (req) => {
  const key = getClientIp(req);
  const now = Date.now();
  const bucket = rateLimitBuckets.get(key);
  if (!bucket || now - bucket.startedAt > FEEDBACK_WINDOW_MS) {
    rateLimitBuckets.set(key, { startedAt: now, count: 1 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= FEEDBACK_MAX_PER_WINDOW;
};

const sendMailWithTimeout = async (transporter, payload) => {
  let timeoutId;
  try {
    return await Promise.race([
      transporter.sendMail(payload),
      new Promise((_, reject) => {
        timeoutId = setTimeout(() => {
          const error = new Error('Feedback SMTP timeout');
          error.code = 'FEEDBACK_SMTP_TIMEOUT';
          reject(error);
        }, FEEDBACK_SMTP_TIMEOUT_MS);
      }),
    ]);
  } finally {
    if (timeoutId) clearTimeout(timeoutId);
    transporter.close();
  }
};

const optionalUser = async (req) => {
  try {
    const user = await resolveSessionUser(req);
    if (!user) return null;
    const { nocoPassword: _omit, ...safeUser } = user;
    return safeUser;
  } catch {
    return null;
  }
};

router.post('/api/feedback', async (req, res, next) => {
  try {
    if (!checkRateLimit(req)) {
      res.status(429).json({
        success: false,
        error: 'Trop de signalements envoyés depuis cet appareil. Réessayez plus tard.',
      });
      return;
    }

    const type = clean(req.body?.type, 80) || 'Signalement';
    const message = clean(req.body?.message, 10000);
    const context = req.body?.context && typeof req.body.context === 'object'
      ? req.body.context
      : {};
    const authenticatedUser = await optionalUser(req);
    const clientUser = req.body?.user && typeof req.body.user === 'object'
      ? req.body.user
      : {};
    const user = authenticatedUser || clientUser || {};

    if (message.length < 3) {
      res.status(400).json({ success: false, error: 'Message trop court.' });
      return;
    }

    const config = smtpConfig();
    if (!config.ready) {
      res.status(503).json({ success: false, error: config.error });
      return;
    }

    const dossierLabel = clean(context.dossierName, 120);
    const subjectParts = ["Signalement App'Ergo", type];
    if (dossierLabel) subjectParts.push(dossierLabel);
    const subject = subjectParts.join(' - ');

    const senderLabel = clean(user.displayName || user.email || 'Utilisateur', 160);
    const senderEmail = clean(user.email, 300);
    const text = [
      subject,
      '',
      `Utilisateur : ${senderLabel}${senderEmail ? ` <${senderEmail}>` : ''}`,
      `Type : ${type}`,
      '',
      'Message :',
      message,
      '',
      'Contexte :',
      formatContextText(context),
    ].join('\n');

    const html = `
      <div style="font-family:Arial,sans-serif;color:#111827;line-height:1.45">
        <h2 style="margin:0 0 12px">Signalement App'Ergo</h2>
        <p><strong>Utilisateur :</strong> ${escapeHtml(senderLabel)}${senderEmail ? ` &lt;${escapeHtml(senderEmail)}&gt;` : ''}</p>
        <p><strong>Type :</strong> ${escapeHtml(type)}</p>
        <h3 style="margin:20px 0 8px">Message</h3>
        <div style="white-space:pre-wrap;background:#FDFCFB;border:1px solid #eadff0;border-radius:12px;padding:14px">${escapeHtml(message)}</div>
        <h3 style="margin:20px 0 8px">Contexte détecté</h3>
        <table style="border-collapse:collapse;width:100%;font-size:14px">${formatContextHtml(context)}</table>
      </div>
    `;

    const transporter = nodemailer.createTransport({
      host: config.host,
      port: config.port,
      secure: config.secure,
      auth: config.auth,
      connectionTimeout: 8000,
      greetingTimeout: 8000,
      socketTimeout: 8000,
    });

    try {
      await sendMailWithTimeout(transporter, {
        from: config.from,
        to: config.to,
        replyTo: senderEmail || undefined,
        subject,
        text,
        html,
      });
    } catch (mailError) {
      console.error('[feedback] SMTP send failed', mailError);
      res.status(502).json({
        success: false,
        error: 'Serveur mail indisponible. Le signalement n’a pas pu être envoyé.',
      });
      return;
    }

    res.json({
      success: true,
      error: null,
      data: { sentAt: new Date().toISOString() },
    });
  } catch (error) {
    next(error);
  }
});

export default router;
