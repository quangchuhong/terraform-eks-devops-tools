# Changelog

## v1.0.0

- `ciPipeline(type: 'maven' | 'python' | 'node', ...)` and `mavenPipeline(...)` for Maven apps.
- Maven: `javaVersion` 8/11/17/21 (Sonar on JDK 17+), `pomFile`, `mavenGoals`, `mavenArgs`, version from the
  POM or its parent, `mvn deploy` to Nexus on main/develop/release/*.
- Agent pod on the `ci-agents` node group (nodeSelector + toleration).
- SonarQube analysis + Quality Gate (blocking).
- Docker build, Trivy gate HIGH/CRITICAL (dated waiver `trivyWaiverUntil`), JSON/table reports and CycloneDX
  SBOM archived, push to the Nexus docker registry on main/develop/release/*.
- Parameter validation (unknown parameters, shell injection) and unit tests (`gradle test`).
