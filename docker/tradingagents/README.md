# TradingAgents-astock Docker Image

Multi-Agent A-stock trading analysis framework. Daily automated build, multi-arch (amd64/arm64).

## Quick Start

### Docker Compose (recommended)

```bash
# 1. create .env file with your API keys
cp .env.example .env
# edit .env, set at least one API key

# 2. run CLI mode
docker compose -f docker-compose.yml run --rm tradingagents

# 3. or run web UI (Streamlit on http://localhost:8501)
docker compose -f docker-compose.yml --profile web up tradingagents-web

# 4. or run with local Ollama
docker compose -f docker-compose.yml --profile ollama run --rm tradingagents-ollama
```

### Docker Run

```bash
# pull image
docker pull ghcr.io/viogus/tradingagents:latest

# run CLI (interactive analysis)
docker run -it --rm \
  -e OPENAI_API_KEY=sk-xxx \
  ghcr.io/viogus/tradingagents:latest

# run web UI (Streamlit)
docker run -it --rm \
  -p 8501:8501 \
  -e OPENAI_API_KEY=sk-xxx \
  ghcr.io/viogus/tradingagents:latest \
  tradingagents-web
```

## Supported LLM Providers

Set one of these env vars in `.env` or via `-e`:

| Provider | Env Var |
|----------|---------|
| OpenAI | `OPENAI_API_KEY` |
| Anthropic | `ANTHROPIC_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Google | `GOOGLE_API_KEY` |
| xAI | `XAI_API_KEY` |
| Zhipu | `ZHIPU_API_KEY` |
| MiniMax | `MINIMAX_API_KEY` |
| DashScope | `DASHSCOPE_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |

## Persist Data

```bash
docker run -it --rm \
  -v tradingagents_data:/home/appuser/.tradingagents \
  -v $(pwd)/results:/data/results \
  -e OPENAI_API_KEY=sk-xxx \
  ghcr.io/viogus/tradingagents:latest
```

## With Ollama (Local LLM)

```bash
# start ollama
docker run -d --name ollama -p 11434:11434 ollama/ollama:latest

# run tradingagents with ollama
docker run -it --rm \
  --network host \
  -e LLM_PROVIDER=ollama \
  ghcr.io/viogus/tradingagents:latest
```

## Image Info

- **Base**: python:3.12-slim
- **Size**: ~256 MB
- **Arch**: linux/amd64, linux/arm64
- **Build**: daily at 02:47 UTC, checks upstream for new releases
- **User**: runs as `appuser` (non-root)
