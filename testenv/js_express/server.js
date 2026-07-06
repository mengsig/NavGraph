// Entry point: wires up the Express application, mounts the catalog router,
// and starts listening. CommonJS module (require / module.exports).
const express = require('express');
const routes = require('./routes');

const app = express();
const PORT = process.env.PORT || 3000;

// Parse JSON request bodies and mount the catalog router at the root.
app.use(express.json());
app.use(routes);

// Root landing route handled by a named function below.
app.get('/', homeHandler);

// Render a short welcome message at the site root.
function homeHandler(req, res) {
  res.status(200).send('Catalog service is running');
}

// Bind the HTTP server to the configured port and log once it is up.
function startServer() {
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
