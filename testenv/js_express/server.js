// Entry point: wires up the Express application, installs middleware, mounts
// the catalog router plus the admin sub-router, subscribes the notification
// handlers, and starts listening. CommonJS module (require / module.exports).
const express = require('express');
const routes = require('./routes');
const adminRouter = require('./adminRoutes');
const { requestLogger } = require('./middleware');
const { registerHandlers } = require('./notifications');

const app = express();
const PORT = process.env.PORT || 3000;

// Log requests, parse JSON bodies, then mount the routers. The admin router is
// mounted under a path prefix so its paths become /admin/*.
app.use(requestLogger);
app.use(express.json());
app.use(routes);
app.use('/admin', adminRouter);

// Root landing route handled by a named function below.
app.get('/', homeHandler);

// Health probe handled inline as an arrow function.
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Render a short welcome message at the site root.
function homeHandler(req, res) {
  res.status(200).send('Catalog service is running');
}

// Bind the HTTP server to the configured port, subscribe event handlers, and
// log once it is up.
function startServer() {
  registerHandlers();
  return app.listen(PORT, () => {
    logStartup(PORT);
  });
}

// Emit a single startup log line.
function logStartup(port) {
  console.log('listening on port ' + port);
}

startServer();

module.exports = { app, homeHandler, startServer };
