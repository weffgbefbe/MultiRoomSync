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

RUN apk add --no-cache alsa-lib alsa-utils pulseaudio-utils python3 py3-pip \
    && pip install --no-cache-dir --break-system-packages "sendspin~=7.3"

# Patch the installed sendspin library to recover from USB-DAC loss
# (stall watchdog + device re-open). Upstream sendspin/audio.py does not notice
# when PortAudio's callback thread dies after an ALSA device disappears, so the
# player stays silent (or permanently late) until the process restarts.
# See PR/HANDOFF-sendspin-usb-recovery.md for the analysis.
# Strict apply (fuzz 0) plus a grep check: if the resolved sendspin version's
# audio.py has drifted from the patch context, the build FAILS here instead of
# silently shipping an unpatched or half-patched library.
COPY patches/usb-device-loss-recovery.patch /tmp/
RUN apk add --no-cache --virtual .patch-deps patch \
    && SENDSPIN_PKG="$(python3 -c 'import os, sendspin; print(os.path.dirname(sendspin.__file__))')" \
    && patch -p1 -F0 -d "$(dirname "$SENDSPIN_PKG")" < /tmp/usb-device-loss-recovery.patch \
    && grep -q "_reopen_lost_device" "$SENDSPIN_PKG/audio.py" \
    && rm /tmp/usb-device-loss-recovery.patch \
    && apk del .patch-deps

COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
