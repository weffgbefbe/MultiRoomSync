ARG BUILD_FROM
FROM ${BUILD_FROM:-python:3.12-alpine}

# Build PortAudio from source with PulseAudio hostapi support
# (Alpine's portaudio package lacks PulseAudio backend, so
# sounddevice/sendspin can't discover PulseAudio sinks)
RUN apk add --no-cache --virtual .build-deps \
        build-base cmake git pulseaudio-dev alsa-lib-dev \
    && git clone --depth 1 https://github.com/PortAudio/portaudio.git /tmp/portaudio \
    && cd /tmp/portaudio \
    && cmake -B build -DPA_USE_PULSEAUDIO=ON -DPA_USE_ALSA=ON -DCMAKE_INSTALL_PREFIX=/usr \
    && cmake --build build --parallel \
    && cmake --install build \
    && rm -rf /tmp/portaudio \
    && apk del .build-deps

RUN apk add --no-cache alsa-lib alsa-utils pulseaudio-utils pulseaudio-libs python3 py3-pip \
    && pip install --no-cache-dir --break-system-packages sendspin

COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
