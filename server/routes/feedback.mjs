import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import nodemailer from 'nodemailer';
import { dataFileUrl, resolveSessionUser } from '../helpers.mjs';

const router = express.Router();
const rateLimitBuckets = new Map();

const FEEDBACK_WINDOW_MS = 60 * 60 * 1000;
const FEEDBACK_MAX_PER_WINDOW = 12;
const FEEDBACK_SMTP_TIMEOUT_MS = 4500;

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

const smtpCandidates = (config) => {
  if (!config.ready) return [];
  const makeCandidate = (host, port, secure) => ({
    host,
    port,
    secure,
    auth: config.auth,
  });
  const addCandidate = (candidates, host, port, secure) => {
    if (!host) return;
    if (candidates.some((candidate) => (
      candidate.host === host &&
      candidate.port === port &&
      candidate.secure === secure
    ))) {
      return;
    }
    candidates.push(makeCandidate(host, port, secure));
  };

  const candidates = [];
  addCandidate(candidates, config.host, config.port, config.secure);

  const o2switchHost = 'mail.tuyau.o2switch.net';
  if (config.host === 'mail.aidhabitat.fr') {
    addCandidate(candidates, o2switchHost, config.port, config.secure);
  }

  if (config.port === 465) {
    addCandidate(candidates, config.host, 587, false);
    if (config.host === 'mail.aidhabitat.fr') {
      addCandidate(candidates, o2switchHost, 587, false);
    }
  } else if (config.port === 587) {
    addCandidate(candidates, config.host, 465, true);
    if (config.host === 'mail.aidhabitat.fr') {
      addCandidate(candidates, o2switchHost, 465, true);
    }
  }

  return candidates;
};

const publicSmtpCandidate = (candidate) => ({
  host: candidate.host,
  port: candidate.port,
  secure: candidate.secure,
});

const formatMailError = (error) => ({
  code: clean(error?.code, 80),
  command: clean(error?.command, 80),
  responseCode: error?.responseCode || null,
  message: clean(error?.message, 1000),
  attempts: Array.isArray(error?.attempts) ? error.attempts : undefined,
});

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

const appendFeedbackReport = async (report) => {
  await fs.mkdir(dataFileUrl('feedback/'), { recursive: true });
  await fs.appendFile(
    dataFileUrl('feedback/reports.jsonl'),
    `${JSON.stringify(report)}\n`,
    'utf8',
  );
};

const appendFeedbackMailEvent = async (event) => {
  await fs.mkdir(dataFileUrl('feedback/'), { recursive: true });
  await fs.appendFile(
    dataFileUrl('feedback/mail-events.jsonl'),
    `${JSON.stringify({ ...event, at: new Date().toISOString() })}\n`,
    'utf8',
  );
};

const safeAppendFeedbackMailEvent = async (event) => {
  try {
    await appendFeedbackMailEvent(event);
  } catch (error) {
    console.error('[feedback] mail event store failed', error);
  }
};

const readRecentFeedbackMailEvents = async (limit = 20) => {
  try {
    const raw = await fs.readFile(dataFileUrl('feedback/mail-events.jsonl'), 'utf8');
    return raw
      .trim()
      .split('\n')
      .filter(Boolean)
      .slice(-limit)
      .map((line) => JSON.parse(line));
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  }
};

const publicMailEvent = (event) => {
  const { diagnosticToken: _omit, ...safeEvent } = event;
  return safeEvent;
};

const findFeedbackMailEvent = async (feedbackId, diagnosticToken) => {
  if (!feedbackId || !diagnosticToken) return null;
  const raw = await readRecentFeedbackMailEvents(200);
  return raw
    .reverse()
    .find((event) => (
      event.feedbackId === feedbackId &&
      event.diagnosticToken === diagnosticToken
    )) || null;
};

const sendFeedbackEmail = async (config, payload) => {
  const errors = [];

  for (const candidate of smtpCandidates(config)) {
    const transporter = nodemailer.createTransport({
      ...candidate,
      connectionTimeout: FEEDBACK_SMTP_TIMEOUT_MS,
      greetingTimeout: FEEDBACK_SMTP_TIMEOUT_MS,
      socketTimeout: FEEDBACK_SMTP_TIMEOUT_MS,
    });

    try {
      const info = await sendMailWithTimeout(transporter, payload);
      console.info('[feedback] SMTP send success', {
        host: candidate.host,
        port: candidate.port,
        secure: candidate.secure,
        messageId: info?.messageId,
      });
      return info;
    } catch (error) {
      errors.push({
        ...publicSmtpCandidate(candidate),
        code: error?.code,
        command: error?.command,
        message: error?.message,
      });
    }
  }

  const error = new Error('All feedback SMTP attempts failed');
  error.attempts = errors;
  throw error;
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

router.get('/api/feedback/mail-events', async (req, res, next) => {
  try {
    const user = await optionalUser(req);
    if (!user) {
      res.status(401).json({ success: false, error: 'Session invalide ou expirée' });
      return;
    }

    const limit = Math.min(Math.max(Number(req.query?.limit || 20), 1), 50);
    const events = await readRecentFeedbackMailEvents(limit);
    res.json({
      success: true,
      error: null,
      data: events,
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/feedback/mail-events/:feedbackId', async (req, res, next) => {
  try {
    const feedbackId = clean(req.params?.feedbackId, 200);
    const diagnosticToken = clean(req.query?.token, 200);
    const event = await findFeedbackMailEvent(feedbackId, diagnosticToken);

    if (!event) {
      res.status(404).json({
        success: false,
        error: 'Diagnostic mail non disponible pour ce signalement.',
      });
      return;
    }

    res.json({
      success: true,
      error: null,
      data: publicMailEvent(event),
    });
  } catch (error) {
    next(error);
  }
});

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

    const report = {
      id: `feedback_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`,
      diagnosticToken: crypto.randomBytes(18).toString('base64url'),
      receivedAt: new Date().toISOString(),
      type,
      message,
      user: {
        displayName: clean(user.displayName, 160),
        email: clean(user.email, 300),
        role: clean(user.role, 120),
      },
      context: {
        page: clean(context.page, 300),
        dossierName: clean(context.dossierName, 300),
        dossierId: clean(context.dossierId, 300),
        section: clean(context.section, 300),
        lastAction: clean(context.lastAction, 1000),
        url: clean(context.url, 1000),
        userAgent: clean(context.userAgent, 1000),
        clientTimestamp: clean(context.clientTimestamp, 120),
      },
      clientIp: getClientIp(req),
    };

    const config = smtpConfig();
    const mailPayload = {
        from: config.from,
        to: config.to,
        replyTo: senderEmail || undefined,
        subject,
        text,
        html,
    };

    res.json({
      success: true,
      error: null,
      data: {
        id: report.id,
        queuedAt: report.receivedAt,
        emailQueued: Boolean(config.ready),
        diagnosticToken: report.diagnosticToken,
      },
    });

    setImmediate(async () => {
      try {
        await appendFeedbackReport(report);
      } catch (storeError) {
        console.error('[feedback] local store failed', storeError);
        return;
      }

      if (!config.ready) {
        console.error('[feedback] SMTP disabled', config.error);
        await safeAppendFeedbackMailEvent({
          feedbackId: report.id,
          diagnosticToken: report.diagnosticToken,
          status: 'disabled',
          error: { message: config.error },
        });
        return;
      }

      try {
        const info = await sendFeedbackEmail(config, mailPayload);
        await safeAppendFeedbackMailEvent({
          feedbackId: report.id,
          diagnosticToken: report.diagnosticToken,
          status: 'sent',
          messageId: clean(info?.messageId, 300),
          accepted: Array.isArray(info?.accepted) ? info.accepted.map((value) => clean(value, 300)) : [],
          rejected: Array.isArray(info?.rejected) ? info.rejected.map((value) => clean(value, 300)) : [],
          response: clean(info?.response, 1000),
        });
      } catch (mailError) {
        console.error('[feedback] SMTP background send failed', mailError);
        await safeAppendFeedbackMailEvent({
          feedbackId: report.id,
          diagnosticToken: report.diagnosticToken,
          status: 'failed',
          error: formatMailError(mailError),
        });
      }
    });
  } catch (error) {
    next(error);
  }
});

export default router;
