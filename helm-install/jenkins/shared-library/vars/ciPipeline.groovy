// Standard CI pipeline for Java/Spring Boot (Maven), Python and Node.js applications.
//
//   @Library('ci-lib@v1.0.0') _
//   ciPipeline(type: 'maven', name: 'shopping-cart', javaVersion: '8')
//
// Checkout -> Build & Test -> SonarQube -> Quality Gate -> Publish package -> Docker Build
// -> Trivy -> Push Image. Publish and Push only run on main, develop and release/*.
// Parameters and defaults: ciConfig.app().

def call(Map args = [:]) {
  def cfg = ciConfig()
  def app = ciConfig.app(args)

  properties([
    disableConcurrentBuilds(),
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
  ])

  timeout(time: 60, unit: 'MINUTES') {
    ciPod(cfg, app) {
      stage('Checkout') {
        checkout scm
        app.commit = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
        app.version = langVersion(app)
        def tag = "${app.version}-${app.commit}".replaceAll('[^A-Za-z0-9_.-]', '-')
        app.image = "${cfg.registry}/${app.imageGroup}/${app.name}:${tag}".toString()
        currentBuild.displayName = "#${env.BUILD_NUMBER} ${tag}".toString()
        echo "[ci-lib] type=${app.type} branch=${app.branch} version=${app.version} image=${app.image}"
      }

      stage('Build & Test') {
        lang(app).build(app, cfg)
      }

      stage('SonarQube Analysis') {
        withSonarQubeEnv(cfg.sonarServer) {
          lang(app).sonar(app, cfg)
        }
      }

      stage('Quality Gate') {
        // Needs the SonarQube webhook to http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/
        timeout(time: 5, unit: 'MINUTES') {
          def qg = waitForQualityGate()
          if (qg.status != 'OK') {
            error "Quality Gate failed: ${qg.status}"
          }
        }
      }

      stage('Publish Package') {
        if (!app.publish || !app.protectedBranch) {
          echo "[ci-lib] skipped (publish=${app.publish}, branch ${app.branch})"
          return
        }
        lang(app).publish(app, cfg)
      }

      if (app.buildImage) {
        stage('Docker Build') {
          ciImage.build(app, cfg)
        }
        stage('Trivy Scan Image') {
          ciImage.scan(app, cfg)
        }
        stage('Push Image') {
          if (!app.protectedBranch) {
            echo "[ci-lib] skipped on branch ${app.branch}: images are pushed from main, develop and release/* only"
            return
          }
          ciImage.push(app, cfg)
        }
      }
    }
  }
}

def lang(Map app) {
  if (app.type == 'maven') {
    return ciMaven
  }
  if (app.type == 'python') {
    return ciPython
  }
  return ciNode
}

def langVersion(Map app) {
  return lang(app).version(app)
}
