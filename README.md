# Claude Code Proxy

A self-hosted LiteLLM proxy that gives every developer on your team Claude Code access — using your existing cloud credits, without handing out API keys.

**Two env vars per developer. That's the entire setup.**

## What This Does

- Routes Claude Code traffic through a single proxy with weighted load balancing across DigitalOcean, Bedrock, and Anthropic Direct
- Tracks per-developer cost, token usage, and model selection in PostgreSQL
- Enforces budget limits via virtual keys
- Enables prompt caching automatically through session affinity
- Provides automatic failover across providers

## Architecture

```
Developer machines (Claude Code CLI)
        │
        ▼
  Nginx (TLS + session extraction via Lua)
        │
        ▼
  LiteLLM Proxy (routing, auth, cost tracking)
        │
        ├── DigitalOcean   (weight: 6  ≈ 60%)
        ├── Anthropic      (weight: 2  ≈ 20%)
        └── AWS Bedrock    (weight: 2  ≈ 20%)
```

Everything runs on a single VM.

## Prerequisites

- A VM with Ubuntu (any cloud provider — AWS, GCP, DigitalOcean, etc.)
- A domain name pointed at your VM (A record)
- API credentials for at least one Claude provider (Anthropic, GCP, AWS, or DigitalOcean)

## Quick Start

1. **Clone and configure:**

```bash
git clone https://github.com/your-org/claude-code-proxy.git
cd claude-code-proxy
cp env.example .env
# Edit .env with your credentials
```

2. **Add your GCP credentials** (if using Vertex AI):

```bash
# Place your Application Default Credentials file
cp /path/to/your/adc.json ./gcp-adc.json
```

3. **Deploy:**

```bash
chmod +x deploy.sh
./deploy.sh your-domain.com you@example.com
```

This installs Docker, Nginx, provisions an SSL certificate via Let's Encrypt, and starts the stack.

4. **Create virtual keys** for your developers via the LiteLLM admin dashboard at `https://your-domain.com/ui`.

5. **Developer setup** (2 minutes per person):

```bash
echo 'export ANTHROPIC_BASE_URL=https://your-domain.com/v1' >> ~/.bashrc
echo 'export ANTHROPIC_AUTH_TOKEN=sk-...' >> ~/.bashrc
source ~/.bashrc
```

Done. `claude` works as normal.

## Provider Setup

You need credentials for **at least one** provider. Configure all four for maximum reliability and credit utilization.

### Anthropic Direct

The simplest option. Create an API key at [console.anthropic.com](https://console.anthropic.com/):

1. Sign up or log in at console.anthropic.com
2. Go to **API Keys** and create a new key
3. Add to your `.env`:

```bash
ANTHROPIC_API_KEY=sk-ant-your-key-here
```

### Google Cloud (Vertex AI)

Use this to route traffic through your GCP cloud credits.

1. **Enable the Vertex AI API** in your GCP project:

```bash
gcloud services enable aiplatform.googleapis.com
```

2. **Enable the Claude models** you need. Go to [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden) and enable Claude Opus, Sonnet, and/or Haiku.

3. **Create a service account and download its key:**

```bash
gcloud iam service-accounts create litellm-proxy \
    --display-name="LiteLLM Proxy Service Account"
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member="serviceAccount:litellm-proxy@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/aiplatform.user"
gcloud iam service-accounts keys create ./gcp-adc.json \
    --iam-account=litellm-proxy@YOUR_PROJECT_ID.iam.gserviceaccount.com
```

> **Do not use `gcloud auth application-default login`** for production. User credentials contain an OAuth2 refresh token that expires, causing `500 "Reauthentication is needed"` errors. Service account keys do not expire.

4. **Add to your `.env`:**

```bash
VERTEX_PROJECT=your-gcp-project-id
VERTEX_LOCATION=us-east5          # Region where Claude is available
```

The `gcp-adc.json` file is mounted into the container automatically by `docker-compose.yml`.

### AWS Bedrock

Use this to route traffic through your AWS cloud credits.

1. **Enable Claude model access** in the AWS console:
   - Go to [Amazon Bedrock](https://console.aws.amazon.com/bedrock/) in your preferred region
   - Navigate to **Model access** in the left sidebar
   - Request access to the Anthropic Claude models you need
   - Wait for access to be granted (usually instant for on-demand)

2. **Create an IAM user** with Bedrock permissions:

```bash
aws iam create-user --user-name litellm-proxy

# Attach the Bedrock policy
aws iam attach-user-policy \
    --user-name litellm-proxy \
    --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess

# Create access keys
aws iam create-access-key --user-name litellm-proxy
```

3. **Add to your `.env`:**

```bash
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1              # Region where you enabled Claude
```

### DigitalOcean (Gradient AI)

Use this to route traffic through your DigitalOcean cloud credits.

1. **Create a DigitalOcean API token** with GenAI permissions:
   - Go to [DigitalOcean API Tokens](https://cloud.digitalocean.com/account/api/tokens)
   - Create a new token with read/write access
   - Ensure GenAI / GPU Droplets are enabled on your account

2. **Enable Claude models** in your DigitalOcean GenAI dashboard:
   - Go to [GenAI Platform](https://cloud.digitalocean.com/gen-ai)
   - Verify the Claude models you need are available

3. **Add to your `.env`:**

```bash
GRADIENT_AI_API_KEY=dop_v1_your-token-here
```

## Configuring Routing Weights

The `weight` parameter in `litellm-config.yaml` controls what percentage of traffic goes to each provider. **Set weights to match your available cloud credit ratio.**

### How Weights Work

Each model is defined once per provider under the same `model_name`. The router picks a provider using weighted random selection:

```yaml
# Example: 60% DigitalOcean, 20% each Anthropic/AWS
- model_name: claude-sonnet-4-6
  litellm_params:
    model: gradient_ai/anthropic-claude-4.6-sonnet
    weight: 6                     # ~60% of traffic

- model_name: claude-sonnet-4-6
  litellm_params:
    model: anthropic/claude-sonnet-4-6
    weight: 2                     # ~20% of traffic

- model_name: claude-sonnet-4-6
  litellm_params:
    model: bedrock/us.anthropic.claude-sonnet-4-6
    weight: 2                     # ~20% of traffic
```

### Common Ratios

| Scenario | DigitalOcean | Bedrock | Anthropic | Result |
|----------|--------------|---------|-----------|--------|
| Default (current) | 6 | 2 | 2 | 60% DO, 20% each AWS/Anthropic |
| Equal credits | 1 | 1 | 1 | ~33% each |
| DO only | 1 | 0 | 0 | 100% DO (remove other entries) |
| DO + Anthropic | 3 | 0 | 1 | 75/25 (remove Bedrock entries) |
| Anthropic only | 0 | 0 | 1 | 100% direct (remove other entries) |

To change the ratio, edit `litellm-config.yaml` and restart:

```bash
sudo docker compose restart litellm
```

### Removing a Provider

If you only have credentials for some providers, simply delete the model entries you don't need from `litellm-config.yaml`. For example, to use only Anthropic Direct, keep only the `anthropic/` entries and remove all `vertex_ai/`, `bedrock/`, and `gradient_ai/` entries.

## Session Affinity

The Lua script (`extract_session.lua`) automatically extracts Claude Code's `session_id` from request bodies and pins sessions to the same provider for 4 hours. This enables prompt caching with zero developer configuration. Prompt caching can reduce costs by up to 90% on cached prefixes.

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | One-command deployment (Docker, Nginx, SSL, containers) |
| `docker-compose.yml` | LiteLLM + PostgreSQL service definitions |
| `litellm-config.yaml` | Model routing, weights, and general settings |
| `nginx.conf` | Reverse proxy with TLS and Lua session extraction |
| `extract_session.lua` | Extracts session ID from request body for routing affinity |
| `setup-claude-session.sh` | Optional shell wrapper for session ID injection |
| `env.example` | Template for required environment variables |

## Troubleshooting

### "Reauthentication is needed" error from Vertex AI

If you see `500 {"error":{"message":"Reauthentication is needed..."}}`, your `gcp-adc.json` contains user credentials (from `gcloud auth application-default login`) whose OAuth2 refresh token has expired.

**Fix:** Replace `gcp-adc.json` with a service account key (see [Google Cloud setup](#google-cloud-vertex-ai) above), then restart:

```bash
sudo docker compose restart litellm
```

The router's `allowed_fails` / `cooldown_time` settings automatically route traffic to healthy providers while Vertex is failing, but you should still replace the credentials to restore full capacity.

## License

MIT
