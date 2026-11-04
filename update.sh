#!/usr/bin/env bash

set -e

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Updating xinit to 2.0.0..."
echo "=========================="
echo ""

echo "Backing up current configuration..."
if [[ -f /etc/xinit/xinit.cfg ]]; then
    cp -p /etc/xinit/xinit.cfg /etc/xinit/xinit.cfg.backup.$(date +%Y%m%d-%H%M%S)
    echo "  Backed up: /etc/xinit/xinit.cfg"
fi

echo ""
echo "Installing updated files..."

install -m 755 bin/xinit /usr/local/bin/xinit
echo "  Installed: /usr/local/bin/xinit"

install -m 755 bin/xinit-manager /usr/local/bin/xinit-manager
echo "  Installed: /usr/local/bin/xinit-manager"

install -m 755 etc/init.d/xwiki.sh /etc/init.d/xwiki.sh
echo "  Installed: /etc/init.d/xwiki.sh"

cp -r var/lib/xinit/* /var/lib/xinit/
chmod 755 /var/lib/xinit/functions
chmod 755 /var/lib/xinit/check-xwiki-install
echo "  Updated: /var/lib/xinit/*"

if [[ ! -f /etc/xinit/xinit.cfg ]]; then
    cp etc/xinit/xinit.cfg /etc/xinit/xinit.cfg
    echo "  Installed: /etc/xinit/xinit.cfg"
else
    echo "  Kept existing: /etc/xinit/xinit.cfg (backup created)"
fi

echo ""
echo "Update complete!"
echo ""
echo "IMPORTANT: Memory settings workflow"
echo "===================================="
echo "If you want to configure memory or add JVM agents (like Glowroot):"
echo ""
echo "  1. Edit /etc/xinit/xinit.cfg and set:"
echo "       XWIKI_OPTS=\"-Xms2048m -Xmx4096m -javaagent:/opt/glowroot/glowroot.jar\""
echo ""
echo "  2. Run: xinit setup-systemd"
echo "     (Creates systemd override with your settings)"
echo ""
echo "  3. Run: systemctl daemon-reload && systemctl restart xwiki.service"
echo "     (Applies and restarts with new memory)"
echo ""
echo "Next steps for monitoring:"
echo "=========================="
echo "  1. Run: xinit detect"
echo "     (Verify container and database detection)"
echo ""
echo "  2. Configure monitoring in /etc/xinit/xinit.cfg:"
echo "     CHECK_HTTP=\"yes\""
echo "     CHECK_HTTP_URL=\"http://localhost:8080/xwiki\""
echo "     SEND_MAIL_NOTIFICATION=\"yes\""
echo "     MAIL=\"admin@example.com\""
echo ""
echo "  3. Enable monitoring:"
echo "     xinit cronjob on"
echo ""
echo "  4. Test:"
echo "     xinit check-proc"
echo "     xinit check-http"
echo ""
