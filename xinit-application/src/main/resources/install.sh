#!/usr/bin/env bash

set -e

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Xinit 2.0.0 Installation"
echo "========================"
echo ""

if [[ -f /var/lib/xinit/vars ]]; then
    source /var/lib/xinit/vars
    echo "Detected existing xinit installation (version ${VERSION})"
    echo ""
    read -p "Upgrade to 2.0.0? [Y/n] " -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        exit 0
    fi
    echo ""

    if [[ -f /etc/xinit/xinit.cfg ]]; then
        cp -p /etc/xinit/xinit.cfg /etc/xinit/xinit.cfg.backup.$(date +%Y%m%d-%H%M%S)
        echo "Backed up configuration to /etc/xinit/xinit.cfg.backup.*"
    fi
fi

echo "Installing xinit files..."

install -m 755 bin/xinit /usr/local/bin/xinit
echo "  Installed executable to /usr/local/bin/"

mkdir -p /var/lib/xinit
cp -r var/lib/xinit/* /var/lib/xinit/
chmod 755 /var/lib/xinit/functions
chmod 755 /var/lib/xinit/check-xwiki-install
echo "  Installed libraries to /var/lib/xinit/"

mkdir -p /etc/xinit
if [[ ! -f /etc/xinit/xinit.cfg ]]; then
    cp etc/xinit/xinit.cfg /etc/xinit/xinit.cfg
    echo "  Installed default configuration to /etc/xinit/xinit.cfg"
else
    echo "  Kept existing configuration at /etc/xinit/xinit.cfg"
fi

mkdir -p /var/run/xinit
mkdir -p /var/log
touch /var/log/xinit.log

echo ""
echo "Detecting environment..."
source /var/lib/xinit/vars
source /var/lib/xinit/functions
source /var/lib/xinit/default.cfg
[[ -f /etc/xinit/xinit.cfg ]] && source /etc/xinit/xinit.cfg

VERBOSE_DETECTION="true"
detect_container_type
resolve_container_paths
detect_database_type

echo "  Container: ${CONTAINER_TYPE} ${CONTAINER_VERSION}"
echo "  Service: ${SERVICE_NAME}"
echo "  Database: ${DB_TYPE}"
echo "  User: ${CONTAINER_USER}"

# For legacy/manual Tomcat installs (no Debian package), install xwiki.service
# if no systemd unit exists for the detected service name.
if ! systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
    if [[ -f etc/systemd/xwiki.service ]]; then
        echo ""
        echo "  No systemd unit found for ${SERVICE_NAME}, installing xwiki.service..."
        local_service="/etc/systemd/system/xwiki.service"
        cp etc/systemd/xwiki.service "${local_service}"
        if [[ -n "${CONTAINER_USER}" ]] && id "${CONTAINER_USER}" &>/dev/null; then
            sed -i "s/XWIKI_USER/${CONTAINER_USER}/" "${local_service}"
            sed -i "s/XWIKI_GROUP/${CONTAINER_USER}/" "${local_service}"
        else
            sed -i '/^User=\|^Group=/d' "${local_service}"
        fi
        chmod 644 "${local_service}"
        systemctl daemon-reload
        systemctl enable xwiki.service
        echo "  Installed and enabled xwiki.service for ${CONTAINER_USER:-root}"
        SERVICE_NAME="xwiki.service"
    fi
fi

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "=========="
echo ""
echo "1. Verify detection:"
echo "   xinit detect"
echo ""
echo "2. Configure memory/monitoring in /etc/xinit/xinit.cfg"
echo "   Example for Jetty with Glowroot:"
echo "     XWIKI_OPTS=\"-Xms2048m -Xmx4096m -javaagent:/opt/glowroot/glowroot.jar\""
echo "     CHECK_HTTP=\"yes\""
echo "     CHECK_HTTP_URL=\"http://localhost:8080/xwiki\""
echo ""
echo "3. Apply configuration to systemd:"
echo "   xinit setup-systemd"
echo "   systemctl daemon-reload"
echo ""
echo "4. Enable monitoring (choose one):"
echo "   xinit timer on"
echo "   xinit cronjob on"
echo ""
echo "5. Test:"
echo "   xinit check-proc"
echo "   xinit check-http"
echo ""
