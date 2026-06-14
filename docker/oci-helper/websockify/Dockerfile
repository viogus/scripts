FROM python:3-alpine
RUN pip install --no-cache-dir websockify
EXPOSE 6080
ENTRYPOINT ["websockify", "6080", "oci-helper:6080"]
