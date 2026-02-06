// Cloudflare Worker for MeshCentral

// Status codes indicating Cloud Run is offline / cold-starting
const OFFLINE_STATUS_CODES = [502, 503, 521, 523, 530, 404];
// Auto-refresh interval (seconds) for the loading page
const LOADING_REFRESH_SECONDS = 3;

export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") {
      const origin = request.headers.get("Origin") || "";
      const allowedOrigin = env.DOMAIN ? `https://${env.DOMAIN}` : "*";
      const corsOrigin = allowedOrigin === "*" || origin === allowedOrigin ? allowedOrigin : "";
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": corsOrigin,
          "Access-Control-Allow-Methods": "GET, HEAD, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    const url = new URL(request.url);

    // 1. Health check route
    if (url.pathname === "/healthz") {
      return new Response("OK", { status: 200 });
    }

    // 2. Proxy Logic (Default to Tunnel/Origin)
    let response;
    try {
      // Try fetching the original request (Tunnel)
      // We do NOT rewrite to CLOUD_RUN_URL here, because that bypasses the Tunnel.
      response = await fetch(request);
    } catch (e) {
      console.error("Fetch error:", e);
      response = new Response("Network Error", { status: 502 });
    }

    // 3. Keep-Alive / Wakeup Logic
    if (OFFLINE_STATUS_CODES.includes(response.status) && !url.searchParams.has("now")) {
      const acceptHeader = request.headers.get("Accept") || "";
      const isBrowser = acceptHeader.includes("text/html");

      if (isBrowser) {
        // Authenticated Wakeup Ping
        if (env.CLOUD_RUN_URL) {
          console.log(`[Wakeup] Pinging Cloud Run at ${env.CLOUD_RUN_URL}...`);
          ctx.waitUntil(
            (async () => {
              try {
                // Generate Token for Waker SA
                const token = await getGoogleAuthToken(env, env.CLOUD_RUN_URL);
                const headers = token ? { "Authorization": `Bearer ${token}` } : {};

                // Ping the Ingress (this hits 'ingress-guard' but wakes up the whole pod)
                const resp = await fetch(env.CLOUD_RUN_URL, { headers });
                console.log(`[Wakeup] Cloud Run Response: ${resp.status} ${resp.statusText}`);

                if (!resp.ok) {
                  const t = await resp.text();
                  console.error(`[Wakeup] Error Body: ${t.slice(0, 200)}`);
                }
              } catch (err) {
                console.error("[Wakeup] Network Request Failed:", err);
              }
            })()
          );
        }

        // Return a "Waking Up" HTML page with status info
        return new Response(getLoadingHtml(), {
          headers: { "Content-Type": "text/html" },
          status: 503,
        });
      }
    }

    return response;
  },
};

// HTML for the Loading Page
function getLoadingHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Waking up MeshCentral...</title>
    <style>
        body { font-family: -apple-system, system-ui, sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; background: #0f172a; color: #e2e8f0; margin: 0; }
        .spinner { width: 50px; height: 50px; border: 5px solid #334155; border-top-color: #3b82f6; border-radius: 50%; animation: spin 1s linear infinite; margin-bottom: 20px; }
        @keyframes spin { to { transform: rotate(360deg); } }
        h1 { font-size: 1.5rem; margin-bottom: 1rem; }
        p { color: #94a3b8; }
    </style>
    <meta http-equiv="refresh" content="${LOADING_REFRESH_SECONDS}">
</head>
<body>
    <div class="spinner"></div>
    <h1>Waking up MeshCentral...</h1>
    <p>Please wait, this usually takes 10-20 seconds.</p>
</body>
</html>`;
}

// === GOOGLE AUTH HELPER ===

async function getGoogleAuthToken(env, audience) {
  if (!env.GCP_SA_KEY) {
    console.warn("[Auth] GCP_SA_KEY is missing. Cannot authenticate.");
    return null;
  }

  try {
    const saKey = JSON.parse(env.GCP_SA_KEY);
    const pem = saKey.private_key;
    const clientEmail = saKey.client_email;

    // 1. Create JWT
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: "RS256", typ: "JWT" };
    const claim = {
      iss: clientEmail,
      sub: clientEmail,
      aud: "https://www.googleapis.com/oauth2/v4/token",
      target_audience: audience,
      exp: now + 3600,
      iat: now,
    };

    const encodedHeader = b64url(JSON.stringify(header));
    const encodedClaim = b64url(JSON.stringify(claim));
    const data = new TextEncoder().encode(`${encodedHeader}.${encodedClaim}`);

    // 2. Sign JWT
    const binaryDer = pem2ab(pem);
    const key = await crypto.subtle.importKey(
      "pkcs8",
      binaryDer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, data);
    const encodedSignature = b64url(signature);
    const jwt = `${encodedHeader}.${encodedClaim}.${encodedSignature}`;

    // 3. Exchange for ID Token
    const tokenResp = await fetch("https://www.googleapis.com/oauth2/v4/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });

    if (!tokenResp.ok) {
      const txt = await tokenResp.text();
      console.error("[Auth] Token exchange failed:", txt);
      return null;
    }

    const tokenData = await tokenResp.json();
    return tokenData.id_token;

  } catch (e) {
    console.error("[Auth] Error generating token:", e);
    return null;
  }
}

// Helpers
function b64url(str) {
  if (typeof str !== "string") {
    // Assume ArrayBuffer
    return btoa(String.fromCharCode(...new Uint8Array(str)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  return btoa(unescape(encodeURIComponent(str)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pem2ab(pem) {
  const b64 = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s/g, "");
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0)).buffer;
}
