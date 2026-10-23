# Changelog

All notable changes to this project. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [Semantic Versioning](https://semver.org/). The section of a version becomes the text of its GitHub release.

## [Unreleased]

## [0.1.0] - 2026-10-23

### Added
- `00-preflight.sh`: RAM/disk, tools, Apache modules, free ports, outbound port 25, free Docker subnet, A and PTR checks.
- `01-install-mailcow.sh`: mailcow bound to loopback, own ACME client disabled, custom Docker subnet, IPv6/ClamAV
  switches, host-only API, resource limits (`templates/docker-compose.override.yml`).
- `02-apache-proxy.sh`: Apache reverse proxy (UI, SOGo, websockets, ActiveSync, autodiscover), certbot certificate and
  deploy hook copying every renewal into mailcow.
- `03-add-domain.sh`, `04-dns-publish.sh`: domain + DKIM creation, DNS records, publication through Gandi, Cloudflare,
  dns-lexicon (100+ DNS hosts) or as a zone snippet for any other host, with
  backup, SPF merge, DKIM splitting and re-publication when LiveDNS does not apply a TXT update.
- `05-add-mailbox.sh`, `06-webmail-redirects.sh`, `check.sh` (full health check, optional test message).
- Documentation in English and French: pitfalls, domain migration, operations.
- CI (ShellCheck, bats unit tests, Apache configtest, weekly mailcow compatibility check), release workflow,
  Dependabot on `dev`.

[Unreleased]: https://github.com/BorisGautier/mailcow-behind-apache/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/BorisGautier/mailcow-behind-apache/releases/tag/v0.1.0
