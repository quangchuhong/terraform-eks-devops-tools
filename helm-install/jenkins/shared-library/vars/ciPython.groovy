// Python: venv + pytest + coverage, SonarQube, optional wheel upload to Nexus (pypi-hosted).
// Contract for the app repo:
//   - requirements.txt (and optionally requirements-dev.txt), or a pyproject.toml installable with pip
//   - tests runnable with pytest
//   - version in pyproject.toml ([project] or [tool.poetry]) or in a VERSION file
// Nexus needs the repositories pypi-proxy, pypi-hosted and pypi-group.

def version(Map app) {
  if (fileExists('pyproject.toml')) {
    def v = pyprojectVersion(readFile('pyproject.toml'))
    if (v) {
      return v
    }
  }
  if (fileExists('VERSION')) {
    return readFile('VERSION').trim()
  }
  return '0.0.0'
}

@NonCPS
def pyprojectVersion(String text) {
  def m = text =~ /(?m)^version\s*=\s*["']([^"']+)["']/
  return m.find() ? m.group(1) : null
}

def build(Map app, Map cfg) {
  withPypi(cfg) {
    container('build') {
      sh '''
        python -m venv .venv
        . .venv/bin/activate
        pip install --upgrade pip
        if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
        if [ -f requirements-dev.txt ]; then pip install -r requirements-dev.txt; fi
        if [ ! -f requirements.txt ] && [ -f pyproject.toml ]; then pip install -e '.[test]' || pip install -e .; fi
        pip install pytest pytest-cov
        mkdir -p reports
        pytest --junitxml=reports/junit.xml --cov=. --cov-report=xml:coverage.xml
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
        -Dsonar.exclusions=.venv/**,reports/**,dist/**,build/** \\
        -Dsonar.test.inclusions=**/test_*.py,**/*_test.py,tests/** \\
        -Dsonar.python.version=${app.pythonVersion} \\
        -Dsonar.python.coverage.reportPaths=coverage.xml \\
        -Dsonar.python.xunit.reportPath=reports/junit.xml
    """
  }
}

def publish(Map app, Map cfg) {
  withPypi(cfg) {
    container('build') {
      sh """
        . .venv/bin/activate
        pip install build twine
        rm -rf dist
        python -m build
        TWINE_USERNAME="\$NX_USER" TWINE_PASSWORD="\$NX_PASS" \\
          twine upload --non-interactive --repository-url ${cfg.nexusUrl}/repository/pypi-hosted/ dist/*
      """
    }
  }
}

// pip reads the index from PIP_INDEX_URL and the password from a netrc file kept in the
// container's /tmp (never in the workspace, never in the log).
def withPypi(Map cfg, Closure body) {
  withCredentials([usernamePassword(credentialsId: cfg.nexusCredId, usernameVariable: 'NX_USER', passwordVariable: 'NX_PASS')]) {
    withEnv(["PIP_INDEX_URL=${cfg.nexusUrl}/repository/pypi-group/simple",
             "PIP_TRUSTED_HOST=${cfg.nexusHost}",
             "NX_HOST=${cfg.nexusHost}",
             'NETRC=/tmp/.ci-netrc']) {
      container('build') {
        sh 'umask 077; printf "machine %s login %s password %s\\n" "$NX_HOST" "$NX_USER" "$NX_PASS" > "$NETRC"'
      }
      body()
    }
  }
}
