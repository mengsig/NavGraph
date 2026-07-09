// Express middleware for the catalog service. CommonJS module. These are
// exported as arrow-function values to exercise arrow handlers in the graph.

// Log every incoming request as `METHOD path`. Always calls next().
const requestLogger = (req, res, next) => {
  console.log(req.method + ' ' + req.url);
  next();
};

// Reject admin traffic that is missing the shared-secret header. Named helper
// keeps the token comparison out of the arrow body.
const requireAdmin = (req, res, next) => {
  if (!hasAdminToken(req)) {
    res.status(401).json({ error: 'admin token required' });
    return;
  }
  next();
};

// Check whether the request carries the expected admin token header.
function hasAdminToken(req) {
  return req.headers['x-admin-token'] === 'let-me-in';
}

module.exports = { requestLogger, requireAdmin };
