import express from 'express';
import nodemailer from 'nodemailer';
import { requireAuth } from '../middleware/auth.mjs';

const router = express.Router();

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

router.post('/api/feedback', requireAuth, async (req, res, next) => {
  try {
    const type = clean(req.body?.type, 80) || 'Signalement';
    const message = clean(req.body?.message, 10000);
    const context = req.body?.context && typeof req.body.context === 'object'
      ? req.body.context
      : {};
    const user = req.appUser || {};

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
    });

    await transporter.sendMail({
      from: config.from,
      to: config.to,
      replyTo: senderEmail || undefined,
      subject,
      text,
      html,
    });

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
