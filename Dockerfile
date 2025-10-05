# First stage: source image
FROM vdsm/virtual-dsm:7.38@sha256:9c02102a1cef6ec30250a2e89adbc526a63ce5e08b03a0a74750e94b72ab5a85 AS source

# Second stage: copy to empty image without VOLUME declaration
FROM scratch
COPY --from=source / /

# Set default DISK_FMT to qcow2
ENV DISK_FMT=qcow2

# Add labels for image management
LABEL org.opencontainers.image.vendor="vdsm-ci"
LABEL vdsm-ci.image.type="base"
LABEL vdsm-ci.managed="true"

# Install Playwright and dependencies
RUN apt-get update -qq && \
    apt-get install -y -qq python3 python3-pip python3-venv && \
    python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --quiet playwright==1.55.0 && \
    /opt/venv/bin/playwright install chromium && \
    /opt/venv/bin/playwright install-deps chromium && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Apply patches for qcow2 support
COPY convert.sh /run/convert.sh
RUN chmod +x /run/convert.sh && \
    sed -i '/\. install\.sh/a . convert.sh    # Convert images to qcow2' /run/entry.sh

RUN mkdir -p /storage

# Duplicate the entrypoint from the source image
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
