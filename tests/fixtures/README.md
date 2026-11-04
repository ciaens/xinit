# Test fixtures

Real files copied from the test images (`tests/env/`), used as inputs by the unit tests: package
configuration files, `systemctl show`/`systemctl cat` outputs, XWiki configuration files.

- One directory per image variant: `tests/fixtures/<variant>/`.
- Replace generated secrets with `REDACTED` before committing.
- Name each file after where it came from: `etc/xwiki/hibernate.cfg.xml`, or for command outputs
  `cmd/systemctl-show-tomcat10.txt`.
