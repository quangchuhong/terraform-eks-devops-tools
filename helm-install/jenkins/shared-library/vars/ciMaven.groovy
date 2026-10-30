// Maven (Java, Spring Boot): build + unit tests + JaCoCo, SonarQube, deploy to Nexus.
// Contract for the app repo:
//   - pom.xml with the JaCoCo plugin (report goal bound to verify -> target/site/jacoco/jacoco.xml)
//   - distributionManagement with ids maven-releases / maven-snapshots when publish = true

def version(Map app) {
  return readMavenPom(file: 'pom.xml').version
}

def build(Map app, Map cfg) {
  withNexus(cfg) {
    container('build') {
      sh 'mvn -B -s .ci-settings.xml clean verify'
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
        mvn -B -s .ci-settings.xml org.sonarsource.scanner.maven:sonar-maven-plugin:${cfg.sonarMavenPlugin}:sonar \\
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
      sh 'mvn -B -s .ci-settings.xml deploy -DskipTests'
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
