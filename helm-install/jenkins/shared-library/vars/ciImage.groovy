// Container image: docker build -> Trivy scan (server mode) -> push to the Nexus docker registry.
// The Trivy gate (HIGH/CRITICAL) is enforced here. The only way around it is a dated waiver
// (trivyWaiverUntil in the Jenkinsfile, approved by Security through CODEOWNERS): until that date
// findings make the build UNSTABLE instead of FAILED. Per-CVE exceptions go in .trivyignore.

def build(Map app, Map cfg) {
  container('docker') {
    sh """
      timeout 60 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
      docker build -f ${app.dockerfile} -t ${app.image} \\
        --label org.opencontainers.image.revision=${app.commit} \\
        --label org.opencontainers.image.version=${app.version} \\
        --label org.opencontainers.image.source=${env.GIT_URL ?: app.name} .
      docker save ${app.image} -o image.tar
      ls -lh image.tar
    """
  }
}

def scan(Map app, Map cfg) {
  def today = new Date().format('yyyy-MM-dd')
  def waived = app.trivyWaiverUntil && today <= app.trivyWaiverUntil
  def rc = 0
  container('trivy') {
    sh """
      trivy image --server ${cfg.trivyServer} --input image.tar --scanners vuln \\
        --format json --output trivy-report.json --no-progress
      trivy convert --format table --output trivy-report.txt trivy-report.json
    """
    rc = sh(returnStatus: true, script: """
      trivy image --server ${cfg.trivyServer} --input image.tar --scanners vuln \\
        --severity HIGH,CRITICAL --exit-code 1 --no-progress
    """)
  }
  archiveArtifacts artifacts: 'trivy-report.json,trivy-report.txt', allowEmptyArchive: true
  if (rc != 0) {
    if (waived) {
      unstable "Trivy: HIGH/CRITICAL vulnerabilities found, accepted by waiver until ${app.trivyWaiverUntil}"
    } else {
      error 'Trivy: HIGH/CRITICAL vulnerabilities found (see trivy-report.txt in the build artifacts)'
    }
  }
}

def push(Map app, Map cfg) {
  container('docker') {
    withCredentials([usernamePassword(credentialsId: cfg.dockerCredId, usernameVariable: 'REG_USER', passwordVariable: 'REG_PASS')]) {
      sh """
        echo "\$REG_PASS" | docker login ${cfg.registry} -u "\$REG_USER" --password-stdin
        docker push ${app.image}
        docker logout ${cfg.registry}
      """
    }
  }
}
