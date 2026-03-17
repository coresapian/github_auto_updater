# v0.1.1 Roadmap

Target: first stabilization release after v0.1.0.

Goals:
- Verify remote notifications end-to-end on physical devices
- Improve helper discovery and pairing UX on real networks
- Tighten release configuration and signing workflow
- Address CI/release issues found after public release

Candidate work items:
1. APNs credential validation flow and test harness
2. Better pairing error states and retry UX
3. More robust Bonjour discovery presentation and caching
4. Physical-device QA checklist completion
5. App Store metadata/screenshots finalization
6. Optional helper authentication hardening and device management UI

Suggested milestone exit criteria:
- Successful TestFlight archive/upload
- Successful real-device pairing on LAN
- Successful local and remote notification tests
- No critical CI failures on main
