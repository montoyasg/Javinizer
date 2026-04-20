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
        wget curl ca-certificates \
        supervisor \
        xvfb fluxbox x11vnc novnc websockify \
        python3 python3-pip \
        mediainfo \
        libicu70 \
    && rm -rf /var/lib/apt/lists/*

ARG POWERSHELL_VERSION=7.4.6
RUN set -eux \
    && case "$(dpkg --print-architecture)" in \
        amd64) PS_ARCH=x64 ;; \
        arm64) PS_ARCH=arm64 ;; \
        *) echo "Unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && wget -q "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-${PS_ARCH}.tar.gz" -O /tmp/pwsh.tar.gz \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7 \
    && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && rm /tmp/pwsh.tar.gz

RUN pwsh -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module Pode -Scope AllUsers -Force"

RUN pip3 install --no-cache-dir pillow requests

RUN dotnet new console -o /opt/playwright \
    && dotnet add /opt/playwright package Microsoft.Playwright \
    && dotnet build /opt/playwright -c Release \
    && pwsh -NoProfile -Command "/opt/playwright/bin/Release/net8.0/playwright.ps1 install --with-deps chromium"

COPY src/Javinizer/ /opt/javinizer/src/Javinizer/
COPY design/ /opt/javinizer/design/
COPY docker/ /opt/docker/

RUN chmod +x /opt/docker/entrypoint.sh /opt/docker/x11vnc-launch.sh

EXPOSE 8600 6080

VOLUME ["/root/.jvsettings", "/root/.javinizer", "/root/.config/Javinizer"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${JVWEB_PORT}/api/settings" >/dev/null || exit 1

ENTRYPOINT ["/opt/docker/entrypoint.sh"]
