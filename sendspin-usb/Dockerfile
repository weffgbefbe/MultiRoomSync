ARG BUILD_FROM
FROM ${BUILD_FROM:-python:3.12-alpine}

RUN apk add --no-cache portaudio alsa-lib alsa-utils \
    && pip install --no-cache-dir --break-system-packages sendspin

COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
