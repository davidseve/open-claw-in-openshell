// Bootstrap script for Node.js inside OpenShell sandboxes.
// Patches http.request() to route through the sandbox HTTP proxy
// (HTTP_PROXY env var), since Node.js core http module does not
// respect proxy env vars by default.
// Usage: NODE_OPTIONS="--require /path/to/http-proxy-bootstrap.js"
"use strict";
const http = require("http");
const { URL } = require("url");
const origRequest = http.request;

http.request = function patchedRequest(options, callback) {
  if (typeof options === "string") {
    options = Object.assign(new URL(options), {});
  }
  if (options instanceof URL) {
    options = {
      protocol: options.protocol,
      hostname: options.hostname,
      port: options.port,
      path: options.pathname + options.search,
      method: "GET",
    };
  }

  const proxyEnv = process.env.HTTP_PROXY || process.env.http_proxy;
  if (!proxyEnv) return origRequest.call(http, options, callback);

  const noProxy = (process.env.NO_PROXY || process.env.no_proxy || "")
    .split(",")
    .map((s) => s.trim().toLowerCase());
  const target = (options.hostname || options.host || "")
    .toLowerCase()
    .split(":")[0];

  if (noProxy.some((p) => p && (target === p || target.endsWith("." + p)))) {
    return origRequest.call(http, options, callback);
  }

  const proxy = new URL(proxyEnv);
  const targetPort = options.port || 80;
  const fullUrl =
    "http://" +
    (options.hostname || options.host) +
    ":" +
    targetPort +
    (options.path || "/");

  const proxiedOptions = Object.assign({}, options, {
    hostname: proxy.hostname,
    port: parseInt(proxy.port, 10) || 3128,
    path: fullUrl,
    headers: Object.assign({}, options.headers, {
      host: (options.hostname || options.host) + ":" + targetPort,
    }),
  });

  return origRequest.call(http, proxiedOptions, callback);
};
