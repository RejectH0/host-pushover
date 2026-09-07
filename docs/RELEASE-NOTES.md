host-pushover v2.1.0 adds update notifications, offline diagnostics, and readable
update status while preserving the existing system and DSM configuration layout.

- Successful checks announce newer stable releases through Pushover. Notices
  default to quiet priority, remember successful delivery per version, and retry
  failed delivery on a later eligible check. Use --notify-priority 0 for normal
  priority or --no-notify to suppress notices for a check.
- DSM delivery runs as the installation owner using runuser or sudo. The root
  checker streams verified code to that account before loading its configuration.
- --doctor reports local PASS/WARN/FAIL diagnostics without sourcing
  configuration, making network requests, or sending notifications.
- --update-status --human shows UTC dates, cached availability, the last recorded
  discovery failure, and any update-notice result. Default output is unchanged.

The existing v2.0.0 updater can install this release. Existing scheduled tasks
continue using the replaced checker. Automatic update notices become available
for releases discovered after installing v2.1.0; v2.0.0 detects this release using
its original update flag and status command. Root must explicitly invoke --update
to install. Configuration files and script ownership/mode are preserved.

The standalone manifest is attached to this release and published through:
https://github.com/RejectH0/host-pushover/releases/latest/download/update-manifest.txt

Follow docs/ROLLOUT.md for deployment and rollback instructions.
