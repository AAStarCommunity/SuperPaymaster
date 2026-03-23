// x402 Facilitator Node — SuperPaymaster Operator
// Hono HTTP server compatible with x402 protocol

import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { serve } from "@hono/node-server";
import { loadConfig } from "./lib/config.js";
import { initClients } from "./lib/chain.js";
import { healthRoute } from "./routes/health.js";
import { verifyRoute } from "./routes/verify.js";
import { settleRoute } from "./routes/settle.js";
import { quoteRoute } from "./routes/quote.js";
import { wellKnownRoute } from "./routes/well-known.js";

const config = loadConfig();
initClients(config);

const app = new Hono();

// Middleware
app.use("*", cors());
app.use("*", logger());

// Routes
app.route("/", healthRoute(config));
app.route("/", verifyRoute(config));
app.route("/", settleRoute(config));
app.route("/", quoteRoute(config));
app.route("/", wellKnownRoute(config));

// Root
app.get("/", (c) =>
  c.json({
    name: "@superpaymaster/x402-facilitator-node",
    version: "0.1.0",
    description: "x402 Facilitator Node for SuperPaymaster operators",
    endpoints: ["/health", "/verify", "/settle", "/quote", "/.well-known/x-payment-info"],
  })
);

// Start server
const port = config.port;
console.log(`x402 Facilitator Node starting on port ${port}`);
console.log(`  Network: ${config.network} (chainId: ${config.chainId})`);
console.log(`  SuperPaymaster: ${config.superPaymasterAddress}`);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`  Listening on http://localhost:${info.port}`);
});

export default app;
