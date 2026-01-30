export default {
  async fetch(request, env) {
    // 1. Try to fetch the request from the Origin (MeshCentral Tunnel)
    // When configured as a Route (e.g. mesh.example.com/*), this fetches the underlying Tunnel.
    // If the Tunnel is down, Cloudflare throws a 530/502/521/523 error.
    let response;
    try {
      // Set a strict timeout (e.g., 2 seconds) for the Origin fetch.
      // If the Tunnel is down, we want to fail FAST and trigger the wakeup,
      // rather than waiting for a long TCP timeout.
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 10000); // 10 second timeout

      response = await fetch(request, {
        signal: controller.signal
      });
      clearTimeout(timeoutId);

    } catch (e) {
      // Network error or other immediate failure
      console.error("Fetch failed:", e);
      // Fall through to wakeup logic by creating a dummy error response
      response = new Response(`Tunnel Unreachable: ${e.message}`, { status: 530 });
    }

    // List of status codes that indicate the Tunnel/Origin is down
    const offlineStatusCodes = [502, 503, 521, 522, 523, 530];
    const url = new URL(request.url);

    // 2. Check if the Tunnel is down (and no bypass)
    if (offlineStatusCodes.includes(response.status) && !url.searchParams.has("now")) {

      // CRITICAL: Filter to ensure we ONLY wake up for humans (Browsers), not Agents.
      const acceptHeader = request.headers.get("Accept") || "";
      const isBrowser = acceptHeader.includes("text/html");

      if (isBrowser) {
        // 3. Ping the Cloud Run instance to wake it up
        if (env.CLOUD_RUN_URL) {
          console.log(`Pinging Cloud Run at ${env.CLOUD_RUN_URL} to wake up...`);
          fetch(env.CLOUD_RUN_URL).catch(err => console.error("Wakeup ping failed", err));
        }

        // 4. Return a "Waking Up" HTML page with status info
        return new Response(getLoadingHtml(response.status), {
          headers: { "content-type": "text/html;charset=UTF-8" },
          status: 503
        });
      }
    }

    // Tunnel is up, or it's an API request, or user forced bypass
    return response;
  },
};

function getLoadingHtml(statusCode) {
  return `
<!DOCTYPE html>
<html>
<head>
  <title>Waking up MeshCentral...</title>
  <meta http-equiv="refresh" content="5">
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; background: #f0f2f5; color: #333; margin: 0; }
    .container { text-align: center; padding: 2rem; background: white; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 400px; width: 90%; }
    .spinner { border: 4px solid #f3f3f3; border-top: 4px solid #3498db; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 0 auto 20px; }
    h1 { font-size: 1.5rem; margin-bottom: 0.5rem; color: #1a1a1a; }
    p { color: #666; line-height: 1.5; }
    .status { font-family: monospace; font-size: 0.8rem; color: #aaa; margin-top: 1.5rem; }
    .btn { display: inline-block; margin-top: 1rem; padding: 8px 16px; background: #3498db; color: white; text-decoration: none; border-radius: 6px; font-size: 0.9rem; }
    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div class="container">
    <div class="spinner"></div>
    <h1>Waking up Server...</h1>
    <p>The MeshCentral instance is currently sleeping to save costs. It is being started now.</p>
    <p>Please wait automatically (approx 10-20 seconds)...</p>
    <a href="?now=1" class="btn">Force Try Again</a>
    <div class="status">Source Status: ${statusCode || 'Unknown'}</div>
  </div>
</body>
</html>
  `;
}
