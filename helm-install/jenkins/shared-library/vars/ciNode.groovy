// Node.js: npm ci + lint + tests with coverage + build, SonarQube, optional npm publish to Nexus.
// Contract for the app repo:
//   - package.json + package-lock.json (npm ci)
//   - script "test:ci" writing JUnit to reports/junit.xml and LCOV to coverage/lcov.info, e.g. with jest:
//       "test:ci": "jest --ci --coverage --reporters=default --reporters=jest-junit"
//   - optional scripts "lint" and "build"
// Nexus needs the repositories npm-proxy, npm-hosted and npm-group.

def version(Map app) {
  return readJSON(file: 'package.json').version ?: '0.0.0'
}

def build(Map app, Map cfg) {
  withNpm(cfg) {
    container('build') {
      sh npmAuth() + '''
        npm ci
        npm run lint --if-present
        mkdir -p reports
        JEST_JUNIT_OUTPUT_DIR=reports npm run test:ci
        npm run build --if-present
      '''
    }
  }
  junit testResults: 'reports/junit.xml'
}

// Runs inside withSonarQubeEnv
def sonar(Map app, Map cfg) {
  container('sonar') {
    sh """
      sonar-scanner \\
        -Dsonar.projectKey=${app.sonarProjectKey} \\
        -Dsonar.projectVersion=${app.version} \\
        -Dsonar.sources=. \\
        -Dsonar.exclusions=node_modules/**,coverage/**,dist/**,build/**,reports/** \\
        -Dsonar.test.inclusions=**/*.test.js,**/*.spec.js,**/*.test.ts,**/*.spec.ts \\
        -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info
    """
  }
}

def publish(Map app, Map cfg) {
  withNpm(cfg) {
    container('build') {
      sh npmAuth() + "\nnpm publish --registry ${cfg.nexusUrl}/repository/npm-hosted/"
    }
  }
}

// npm reads its registry and auth from .ci-npmrc. The file only holds ${NPM_AUTH}, which npm
// expands from the environment; NPM_AUTH is derived from the Nexus credentials inside each sh
// step (npmAuth()), so neither the password nor its base64 form is written to disk or the log.
def withNpm(Map cfg, Closure body) {
  withCredentials([usernamePassword(credentialsId: cfg.nexusCredId, usernameVariable: 'NX_USER', passwordVariable: 'NX_PASS')]) {
    def registry = "${cfg.nexusUrl}/repository"
    def authPath = registry.replaceFirst('^https?:', '')
    writeFile file: '.ci-npmrc', text: """registry=${registry}/npm-group/
${authPath}/npm-group/:_auth=\${NPM_AUTH}
${authPath}/npm-hosted/:_auth=\${NPM_AUTH}
"""
    withEnv(["NPM_CONFIG_USERCONFIG=${env.WORKSPACE}/.ci-npmrc"]) {
      body()
    }
  }
}

def npmAuth() {
  return 'export NPM_AUTH="$(printf \'%s:%s\' "$NX_USER" "$NX_PASS" | base64 | tr -d \'\\n\')"'
}
