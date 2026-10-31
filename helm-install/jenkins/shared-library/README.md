# ci-lib: Jenkins Shared Library

Shared CI pipeline for Maven (Java, Spring Boot), Python and Node.js applications on the EKS platform.
This folder is the source copy; Jenkins loads the library from the GitLab repository
`devops/ci-cd/jenkins-shared-library` (JCasC `shared-library` in `helm-install/jenkins/jenkins/values.yaml`).

Full guide (Vietnamese): [docs/jenkins/07-shared-library.md](../../../docs/jenkins/07-shared-library.md)

## Maven application

```groovy
@Library('ci-lib@v1.0.0') _

mavenPipeline(
  name: 'shopping-cart',     // image dev-backend/shopping-cart, Sonar project key
  javaVersion: '8',          // 8, 11, 17 (default), 21
  pomFile: 'pom.xml',        // default
  mavenGoals: 'clean verify',// default; tests + JaCoCo must run here
  mavenArgs: '-Pci',         // optional extra options (no quotes, $, ;, |, &)
  trivyWaiverUntil: '2026-12-31'
)
```

Stages: Checkout → Build & Test → SonarQube Analysis → Quality Gate → Publish Package (`mvn deploy`) →
Docker Build → Trivy Scan Image (reports + CycloneDX SBOM) → Push Image. Publish and Push only run on
`main`, `develop` and `release/*`. All parameters: `ciConfig.app()`.

## Layout

```
vars/
  mavenPipeline.groovy  entry point for Maven apps (ciPipeline with type 'maven')
  ciPipeline.groovy     entry point for every type: ciPipeline(type: 'maven'|'python'|'node', ...)
  ciConfig.groovy       platform settings (endpoints, credential IDs, images) + parameter validation
  ciPod.groovy          agent pod (jnlp, build, sonar, docker, trivy) on the ci-agents node group
  ciMaven.groovy        Maven: build/test/JaCoCo, Sonar, deploy
  ciPython.groovy       Python: venv/pytest/coverage, Sonar, twine upload
  ciNode.groovy         Node.js: npm ci/lint/test:ci/build, Sonar, npm publish
  ciImage.groovy        docker build, Trivy gate (dated waiver) + SBOM, push
resources/ci/
  maven-settings.xml    Nexus mirror, credentials from env vars
examples/               Jenkinsfile for each kind of application
test/                   unit tests (Gradle + JUnit, Groovy 2.4 like Jenkins)
```

## Tests

```sh
gradle test
```

`test/PipelineHarness.groovy` loads every `vars/*.groovy` with mocked pipeline steps (sh, stage,
podTemplate, withCredentials, waitForQualityGate...) and records what the library would run. The tests
check parameter validation (including shell injection), the stages per branch, the agent pod (node
group, images, dind), the Maven commands, the Quality Gate and the Trivy gate/waiver. They do not
replace one real build on Jenkins (CPS serialization, plugins, cluster access).

## Release

1. Change + tests on a branch, `gradle test` green, try it from an app branch with
   `@Library('ci-lib@<branch>') _`.
2. Merge request reviewed by the platform team, merge to `main`.
3. Tag `vX.Y.Z` (semver), update `CHANGELOG.md`; apps move to the new tag by merge request.
