import { resolveSessionUser } from '../helpers.mjs';

export const requireAuth = async (req, res, next) => {
  try {
    const user = await resolveSessionUser(req);
    if (!user) {
      res.status(401).json({ success: false, error: 'Session invalide ou expirée' });
      return;
    }
    const { nocoPassword: _omit, ...safeUser } = user;
    req.appUser = safeUser;
    next();
  } catch (error) {
    next(error);
  }
};

export const requireAdmin = async (req, res, next) => {
  try {
    const user = await resolveSessionUser(req);
    if (!user) {
      res.status(401).json({ success: false, error: 'Session invalide ou expirée' });
      return;
    }
    if (user.role !== 'ADMIN') {
      res.status(403).json({ success: false, error: 'Accès administrateur requis' });
      return;
    }
    const { nocoPassword: _omit, ...safeUser } = user;
    req.appUser = safeUser;
    next();
  } catch (error) {
    next(error);
  }
};
