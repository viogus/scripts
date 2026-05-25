FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build

# layer cache: install heavy deps before copying source
COPY pyproject.toml .
RUN pip install --no-cache-dir \
    langchain-core>=0.3.81 \
    backtrader>=1.9.78.123 \
    langchain-anthropic>=0.3.15 \
    langchain-experimental>=0.3.4 \
    langchain-openai>=0.3.23 \
    langgraph>=0.4.8 \
    langgraph-checkpoint-sqlite>=2.0.0 \
    pandas>=2.3.0 \
    parsel>=1.10.0 \
    pytz>=2025.2 \
    questionary>=2.1.0 \
    redis>=6.2.0 \
    requests>=2.32.4 \
    rich>=14.0.0 \
    typer>=0.21.0 \
    stockstats>=0.6.5 \
    tqdm>=4.67.1 \
    typing-extensions>=4.14.0 \
    yfinance>=0.2.63 \
    streamlit>=1.45.0 \
    fpdf2>=2.8.0 \
    python-dotenv>=1.1.0 \
    mootdx>=0.10.0

# copy remaining source + install package (no dep re-download)
COPY . .
RUN pip install --no-cache-dir --no-deps .

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN useradd --create-home appuser \
    && mkdir -p /home/appuser/.tradingagents /data/results \
    && chown -R appuser:appuser /home/appuser /data

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

USER appuser
WORKDIR /data

ENV TRADINGAGENTS_DATA_DIR=/home/appuser/.tradingagents

ENTRYPOINT ["tradingagents"]
