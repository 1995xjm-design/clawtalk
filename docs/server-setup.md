# OpenClaw Server Setup for ClawTalk

Instructions for configuring your OpenClaw instance to accept connections from the iOS app.

## 1. Enable the HTTP API Endpoints

OpenClaw's HTTP API endpoints are disabled by default. You need to enable the ones you want to use.

### Chat Completions (recommended starting point)

Edit your OpenClaw config file (usually `~/.openclaw/config.json` or `openclaw.json` in your project root):

```json
{
  "gateway": {
    "http": {
      "endpoints": {
        "chatCompletions": {
          "enabled": true
        }
      }
    }
  }
}
```

### Open Responses (optional, enables token usage)

The Open Responses API provides structured streaming events and real token usage data. To enable it:

```json
{
  "gateway": {
    "http": {
      "endpoints": {
        "chatCompletions": {
          "enabled": true
        },
        "responses": {
          "enabled": true
        }
      }
    }
  }
}
```

Restart OpenClaw after making config changes.

### Verify it works locally

```bash
# Test Chat Completions
curl -X POST http://127.0.0.1:18789/v1/chat/completions \
  -H "Authorization: Bearer YOUR_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openclaw:main",
    "messages": [{"role": "user", "content": "Hello, are you there?"}],
    "stream": false
  }'
```

You should get back a JSON response with `choices[0].message.content`. If you get a connection refused or 404, the API isn't enabled or OpenClaw isn't running.

```bash
# Test Open Responses (if enabled)
curl -X POST http://127.0.0.1:18789/v1/responses \
  -H "Authorization: Bearer YOUR_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openclaw:main",
    "input": "Hello, are you there?",
    "stream": false
  }'
```

### Find your gateway token

Your gateway token is set via the `OPENCLAW_GATEWAY_TOKEN` environment variable or the `--token` CLI flag when you start OpenClaw. If you haven't set one, check your OpenClaw startup command or config.

```bash
# Check if it's set in your environment
echo $OPENCLAW_GATEWAY_TOKEN

# Or look in your config
cat ~/.openclaw/config.json | grep -i token
```

If you don't have one set, add one:

```bash
export OPENCLAW_GATEWAY_TOKEN="your-secure-token-here"
```

Use a strong random string. You'll enter this same token in the iOS app.

## 2. Expose the Gateway Securely

Your OpenClaw gateway listens on localhost by default. You need a way to reach it from your phone. Two options:

### Option A: Tailscale (recommended)

The simplest option. Install Tailscale on your server and iPhone, and your gateway is instantly accessible over an encrypted mesh network — no DNS, no tunnels, no port forwarding.

#### Install Tailscale

- **Server**: [tailscale.com/download](https://tailscale.com/download) (available for macOS, Linux, Windows)
- **iPhone**: Install [Tailscale from the App Store](https://apps.apple.com/app/tailscale/id1470499037)

Sign into the same Tailscale account on both devices.

#### Enable HTTPS

Tailscale can provision TLS certificates for your devices automatically:

```bash
# On the server running OpenClaw
tailscale cert <hostname>.your-tailnet.ts.net
```

Or use Tailscale Serve to proxy with automatic HTTPS:

```bash
tailscale serve https / http://127.0.0.1:18789
```

Your gateway is now accessible at `https://<hostname>.your-tailnet.ts.net` from any device on your tailnet.

#### Verify

From your phone (with Tailscale connected):

```bash
curl -X POST https://<hostname>.your-tailnet.ts.net/v1/chat/completions \
  -H "Authorization: Bearer YOUR_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"openclaw:main","messages":[{"role":"user","content":"Hello!"}],"stream":false}'
```

### Option B: Cloudflare Tunnel

Exposes your gateway via a custom HTTPS domain without opening any ports. Useful if you want a public-facing URL or don't want to install Tailscale on your phone.

#### Install cloudflared

```bash
# macOS
brew install cloudflare/cloudflare/cloudflared

# Linux (Debian/Ubuntu)
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

# Linux (other)
curl -L --output cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo mv cloudflared /usr/local/bin/
sudo chmod +x /usr/local/bin/cloudflared
```

#### Authenticate and create the tunnel

```bash
cloudflared tunnel login
# Select your domain and authorize in the browser

cloudflared tunnel create openclaw
# Note down the tunnel ID (UUID)
```

#### Configure the tunnel

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /home/<your-user>/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: openclaw.yourdomain.com
    service: http://127.0.0.1:18789
    originRequest:
      noTLSVerify: false
  - service: http_status:404
```

Replace `<TUNNEL_ID>` with the UUID from the create step and `openclaw.yourdomain.com` with your subdomain.

#### Create the DNS record and start

```bash
cloudflared tunnel route dns openclaw openclaw.yourdomain.com
cloudflared tunnel run openclaw
```

#### Run as a service (recommended)

```bash
# macOS
sudo cloudflared service install
sudo launchctl start com.cloudflare.cloudflared

# Linux (systemd)
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

### Verify remote access

From any other machine (or your phone):

```bash
curl -X POST https://openclaw.yourdomain.com/v1/chat/completions \
  -H "Authorization: Bearer YOUR_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openclaw:main",
    "messages": [{"role": "user", "content": "Hello from outside!"}],
    "stream": false
  }'
```

If this returns a response, everything is working.

## 3. Configure the iOS App

Open ClawTalk on your phone/simulator:

1. Tap the gear icon (Settings)
2. Under **OpenClaw Gateway**:
   - URL: `https://openclaw.yourdomain.com` (your tunnel/Tailscale URL)
   - Token: your gateway token from step 1
   - API Mode: **Chat Completions** (default) or **Open Responses** (if you enabled it)
3. Go back to the chat screen
4. Type a message or use voice to test

### API Mode

- **Chat Completions**: Standard OpenAI-compatible API. Works with all gateways. No token usage data.
- **Open Responses**: Structured streaming with real token usage. Requires the responses endpoint to be enabled in your OpenClaw config.

## 4. Security Checklist

- [ ] Gateway token is a strong random string (not something guessable)
- [ ] Cloudflare Tunnel / Tailscale handles TLS — traffic is encrypted end-to-end
- [ ] OpenClaw gateway only listens on `127.0.0.1` (localhost) — the tunnel connects locally
- [ ] No ports are open on your firewall/router
- [ ] The iOS app enforces HTTPS-only — it will reject `http://` URLs
- [ ] API keys (ElevenLabs, OpenAI) stored in iOS Keychain, not UserDefaults
- [ ] Consider enabling Cloudflare Access for additional authentication (IP allowlists, SSO, etc.)

## Troubleshooting

**"Connection refused" from curl locally**
- OpenClaw isn't running, or it's on a different port. Check `ps aux | grep openclaw` and verify the port.

**404 from the /v1/chat/completions endpoint**
- The HTTP API isn't enabled. Double-check your config and restart OpenClaw.

**404 from the /v1/responses endpoint**
- The Open Responses endpoint isn't enabled. Add `"responses": { "enabled": true }` to your config.

**401 Unauthorized**
- Token mismatch. Make sure the token in your curl/app matches `OPENCLAW_GATEWAY_TOKEN`.

**502 Bad Gateway from Cloudflare**
- The tunnel is running but OpenClaw isn't, or the port in `config.yml` doesn't match. Check that `http://127.0.0.1:18789` is reachable locally.

**Tunnel not starting**
- Check `cloudflared tunnel info openclaw` and verify credentials file exists.

**App shows "HTTPS is required"**
- The app rejects plain HTTP. Make sure your URL starts with `https://`.
