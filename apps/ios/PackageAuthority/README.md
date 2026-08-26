# AIES iOS package authority

The generated iOS project and the standalone Swift packages have different
dependency roots. Their resolved-file authorities must stay separate.

`apps/swabble/Package.resolved` is the standalone Swabble lock. It contains
only Swabble's three pins and is never used as the aggregate iOS project lock.

`aggregate-package-graph.json` is the portable semantic authority for the
generated iOS project's nine source-control pins. It records declaration
provenance, exact locations, versions, revisions, requirements, graph roles,
and the WebRTC binary-artifact checksum. Its declaration hashes fail closed if
`project.yml` or either local `Package.swift` changes without a reviewed graph
update.

The concrete aggregate `Package.resolved` is derived only inside the final
disposable build root, at the generated project's workspace-scoped location:

```text
apps/ios/OpenClaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

SwiftPM 6.2.3 includes absolute local-package locations in `originHash`, so a
concrete file is intentionally bound to one build root. The validator compares
all semantic fields exactly while treating only that verified `originHash` as
derived metadata. A concrete lock from one absolute root is rejected in every
other root.

`Tools/prepare_aies_package_build_root.py` implements the shared unsigned and
protected-release preparation contract:

1. clone the exact clean source SHA without hard links;
2. run pinned XcodeGen twice and require identical, clean output;
3. materialize the project-scoped concrete lock for that final path;
4. perform one cold strict package resolution with automatic updates disabled;
5. validate the concrete graph, SwiftPM workspace state, and WebRTC checksum;
6. emit a receipt, strict xcodebuild arguments, and the exact Gym environment;
7. verify that the source, lock inventory, and prepared root remain unchanged.

The project lock and caches are derived runner artifacts. They must not be
committed, copied between roots, or substituted for the semantic authority.
Package declaration changes require a separately reviewed authority update.
