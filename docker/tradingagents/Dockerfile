FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build
COPY . .
RUN pip install --no-cache-dir .

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
