FROM mcr.microsoft.com/dotnet/sdk:8.0-jammy

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/root \
    DISPLAY=:99 \
    JVWEB_PORT=8600 \
    JVWEB_BIND=0.0.0.0 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    VNC_PASSWORD= \
    PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget curl ca-certificates gnupg apt-transport-https \
        supervisor \
        xvfb fluxbox x11vnc novnc websockify \
        python3 python3-pip \
        mediainfo \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

RUN pwsh -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module Pode -Scope AllUsers -Force"

RUN pip3 install --no-cache-dir pillow requests

RUN dotnet new console -o /opt/playwright \
    && dotnet add /opt/playwright package Microsoft.Playwright \
    && dotnet build /opt/playwright -c Release \
    && pwsh -NoProfile -Command "/opt/playwright/bin/Release/net8.0/playwright.ps1 install --with-deps chromium"

COPY src/Javinizer/ /opt/javinizer/src/Javinizer/
COPY docker/ /opt/docker/

RUN chmod +x /opt/docker/entrypoint.sh /opt/docker/x11vnc-launch.sh

EXPOSE 8600 6080

VOLUME ["/root/.jvsettings", "/root/.javinizer", "/root/.config/Javinizer"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${JVWEB_PORT}/api/settings" >/dev/null || exit 1

ENTRYPOINT ["/opt/docker/entrypoint.sh"]
