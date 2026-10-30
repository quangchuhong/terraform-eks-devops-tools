# ci-lib: Jenkins Shared Library

Shared CI pipeline for Java/Spring Boot (Maven), Python and Node.js applications on the EKS platform.
This folder is the reference copy; the library itself lives in its own GitLab repository
`devops/ci-cd/jenkins-shared-library` (copy this folder there, then tag `v1.0.0`).

Full guide (Vietnamese): [docs/jenkins/07-shared-library.md](../../../docs/jenkins/07-shared-library.md)

```
vars/
  ciPipeline.groovy   entry point: ciPipeline(type: 'maven'|'python'|'node', name: ..., ...)
  ciConfig.groovy     platform settings (endpoints, credential IDs, images) + parameter validation
  ciPod.groovy        agent pod (jnlp, build, sonar, docker, trivy) on the ci-agents node group
  ciMaven.groovy      Maven: build/test/JaCoCo, Sonar, deploy
  ciPython.groovy     Python: venv/pytest/coverage, Sonar, twine upload
  ciNode.groovy       Node.js: npm ci/lint/test:ci/build, Sonar, npm publish
  ciImage.groovy      docker build, Trivy gate (with dated waiver), push
resources/ci/
  maven-settings.xml  Nexus mirror, credentials from env vars
examples/             Jenkinsfile for each kind of application
```

Minimal Jenkinsfile:

```groovy
@Library('ci-lib@v1.0.0') _
ciPipeline(type: 'maven', name: 'shopping-cart', javaVersion: '8')
```
