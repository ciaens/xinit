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
install -m 755 bin/xinit-manager /usr/local/bin/xinit-manager
echo "  Installed executables to /usr/local/bin/"

mkdir -p /var/lib/xinit
cp -r var/lib/xinit/* /var/lib/xinit/
chmod 755 /var/lib/xinit/functions
chmod 755 /var/lib/xinit/check-xwiki-install
echo "  Installed libraries to /var/lib/xinit/"

install -m 755 etc/init.d/xwiki.sh /etc/init.d/xwiki.sh
echo "  Installed init.d script to /etc/init.d/xwiki.sh"

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

#if [[ -n "${CONTAINER_USER}" ]] && id "${CONTAINER_USER}" &>/dev/null; then
#    chown -R "${CONTAINER_USER}:${CONTAINER_USER}" /var/run/xinit 2>/dev/null || true
#    echo "  Set ownership on /var/run/xinit"
#fi

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
