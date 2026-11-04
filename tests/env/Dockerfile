# Base image for xinit integration tests: a Debian with systemd as PID 1, so that xinit is tested
# against the real units of the XWiki Debian packages. XWiki itself is installed by
# xwiki-env.sh build, with systemd running: the packages' maintainer scripts start PostgreSQL /
# MariaDB and create the database, which cannot happen during a plain `docker build`.
ARG BASE=debian:13
FROM ${BASE}
ENV container=docker
# policy-rc.d (shipped by the Debian image) forbids starting services from maintainer scripts:
# remove it, the database must start when the xwiki-*-{pgsql,mysql,mariadb} package is configured.
RUN rm -f /usr/sbin/policy-rc.d \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus curl ca-certificates gnupg procps iproute2 less \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# The XWiki APT repository; its key is fetched by provision.sh (an HTTPS proxy CA may be needed first).
COPY xwiki-stable.list /etc/apt/sources.list.d/xwiki-stable.list
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
