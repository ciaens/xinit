#!/usr/bin/env bats
# `xinit maint` on a real host. Scenarios S-MAINT-* of docs/TESTING.md.

load helpers

setup() {
  xinit_conf
  in_env rm -rf /var/lib/xinit
}

teardown() {
  in_env rm -rf /var/lib/xinit
}

# as_nobody <xinit args...>: run xinit in the container as the user nobody.
as_nobody() {
  run --separate-stderr docker exec -e "XINIT_CONF_DIR=$XT_XINIT_CONF_DIR" "$XT_CONTAINER" \
    setpriv --reuid=nobody --regid=nogroup --clear-groups /src/xinit/bin/xinit "$@"
}

@test "S-MAINT-01 maint: on, status and off as root, with files for root only" {
  local left
  xinit maint on --for 10m --reason "integration test" --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = True ]
  [ "$(json 'd["by"]')" = root ]
  [ "$(json 'd["reason"]')" = "integration test" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit)" = "root 700" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default)" = "root 700" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/maintenance)" = "root 600" ]

  xinit maint status --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = True ]
  left="$(json 'd["remaining_seconds"]')"
  [ "$left" -gt 540 ] && [ "$left" -le 600 ]
  in_env_sh "journalctl -t xinit --since -2min -o cat | grep -q 'instance default: maintenance on'"

  xinit maint off --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = False ]
  run ! in_env test -e /var/lib/xinit/default/maintenance
  # A user who may not look into the state is not told "off".
  as_nobody maint status --format json
  [ "$status" -eq 3 ]
}

@test "S-MAINT-02 maint: root writes as the owner of the state directory" {
  in_env install -d -o nobody -g nogroup -m 700 /var/lib/xinit
  xinit maint on --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = True ]
  [ "$(json 'd["by"]')" = root ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default)" = "nobody 700" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/maintenance)" = "nobody 600" ]
  # The owner, as the periodic job will be, reads what root set.
  as_nobody maint status --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = True ]
  xinit maint off --format json
  [ "$status" -eq 0 ]
  run ! in_env test -e /var/lib/xinit/default/maintenance
}

@test "S-MAINT-03 maint: a maintenance ends by itself" {
  xinit maint on --for 3s --format json
  [ "$(json 'd["maintenance"]')" = True ]
  sleep 4
  xinit maint status --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = False ]
}
