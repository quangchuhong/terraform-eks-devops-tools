// Maven (Java, Spring Boot): build + unit tests + JaCoCo, SonarQube, deploy to Nexus.
// Contract for the app repo:
//   - pom.xml (or pomFile) with the JaCoCo plugin (report goal bound to verify -> target/site/jacoco/jacoco.xml)
//   - distributionManagement with ids maven-releases / maven-snapshots when publish = true
// Parameters (ciConfig.app): pomFile (default pom.xml), mavenGoals (default "clean verify"),
// mavenArgs (extra options such as "-Pci -DskipITs=false", default empty).

def version(Map app) {
  def pom = readMavenPom(file: app.pomFile)
  // A module may inherit its version from the parent POM
  def v = pom.version ?: pom.parent?.version
  if (!v) {
    error "ciMaven: no version in ${app.pomFile}"
  }
  return v
}

def mvn(Map app, String goals) {
  return "mvn -B -s .ci-settings.xml -f ${app.pomFile} ${goals} ${app.mavenArgs}".trim()
}

def build(Map app, Map cfg) {
  withNexus(cfg) {
    container('build') {
      sh mvn(app, app.mavenGoals)
    }
  }
  junit testResults: '**/target/surefire-reports/*.xml'
}

// Runs inside withSonarQubeEnv
def sonar(Map app, Map cfg) {
  def scanContainer = (app.javaVersion as Integer) < 17 ? 'sonar' : 'build'
  withNexus(cfg) {
    container(scanContainer) {
      // The workspace belongs to uid 1000 (jnlp) and this container runs as root: without
      // safe.directory git refuses the repo and SonarQube has no blame data (all code looks new).
      sh """
        git config --global --add safe.directory "\$WORKSPACE"
        ${mvn(app, "org.sonarsource.scanner.maven:sonar-maven-plugin:${cfg.sonarMavenPlugin}:sonar")} \\
          -Dsonar.projectKey=${app.sonarProjectKey} \\
          -Dsonar.projectVersion=${app.version} \\
          -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
      """
    }
  }
}

def publish(Map app, Map cfg) {
  withNexus(cfg) {
    container('build') {
      sh mvn(app, 'deploy -DskipTests')
    }
  }
}

def withNexus(Map cfg, Closure body) {
  withCredentials([usernamePassword(credentialsId: cfg.nexusCredId, usernameVariable: 'NX_USER', passwordVariable: 'NX_PASS')]) {
    writeFile file: '.ci-settings.xml',
              text: libraryResource('ci/maven-settings.xml').replace('@NEXUS_URL@', cfg.nexusUrl)
    body()
  }
}
