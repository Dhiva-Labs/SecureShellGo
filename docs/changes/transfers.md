### Added
- A direct server-to-server copy now runs on the source server itself and finishes even if the app is closed, the phone sleeps or the network drops. The app picks the result up the next time both servers are open.

### Changed
- Direct transfer is ticked by default whenever it can be used.

### Fixed
- A server-to-server copy that finished at the moment the app checked on it could be reported as lost.
