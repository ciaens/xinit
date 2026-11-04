#!/usr/bin/env bats
# Baseline: the test instance is what the other tests assume. If this file fails, every other
# result is meaningless.

load helpers

@test "env: systemd runs and the servlet unit is active" {
  run in_env systemctl is-active "$XT_UNIT"
  [ "$output" = active ]
}

@test "env: the servlet unit's MainPID is a JVM" {
  run jvm_pid
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "env: XWiki home page answers 200 without the Distribution Wizard" {
  wait_healthy 300
  run http_code /bin/view/Main/
  [ "$output" = 200 ]
}

@test "env: Admin:admin is an administrator" {
  run http_code /bin/admin/XWiki/XWikiPreferences -u Admin:admin
  [ "$output" = 200 ]
}

@test "env: standard:standard is a logged-in user without admin rights" {
  run http_code /bin/admin/XWiki/XWikiPreferences -u standard:standard
  [ "$output" = 403 ]
}

@test "env: superadmin is disabled" {
  run http_code /bin/admin/XWiki/XWikiPreferences -u superadmin:system
  [ "$output" = 302 ]
}

@test "env: the repository is mounted at /src/xinit" {
  run in_env test -f /src/xinit/docs/DESIGN.md
  [ "$status" -eq 0 ]
}
