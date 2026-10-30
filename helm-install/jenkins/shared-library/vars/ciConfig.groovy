// Platform settings (endpoints, credential IDs, images) and validation of the parameters an app
// passes to ciPipeline. Apps cannot override what is in call(): the platform team owns it.

def call() {
  return [
    nexusUrl        : 'http://nexus.nexus.svc.cluster.local:8081',
    nexusHost       : 'nexus.nexus.svc.cluster.local',
    registry        : 'docker-internal.gitlabonlinecom.click',
    trivyServer     : 'http://trivy.trivy.svc.cluster.local:9090',
    sonarServer     : 'SonarQube',
    sonarMavenPlugin: '5.1.0.4751',
    nexusCredId     : 'nexus-creds',
    dockerCredId    : 'docker-user-internal',
    images          : [
      jnlp  : 'jenkins/inbound-agent:3355.v388858a_47b_33-3-jdk21',
      docker: 'docker:24-dind',
      trivy : 'aquasec/trivy:0.68.2',
      sonar : 'sonarsource/sonar-scanner-cli:12.2',
      maven : ['8' : 'maven:3.9.9-eclipse-temurin-8',
               '17': 'maven:3.9.9-eclipse-temurin-17',
               '21': 'maven:3.9.11-eclipse-temurin-21'],
      python: ['3.12': 'python:3.12.12-slim',
               '3.13': 'python:3.13.9-slim'],
      node  : ['22': 'node:22.21.1-alpine',
               '24': 'node:24.11.0-alpine']
    ]
  ]
}

// Parameters accepted from the Jenkinsfile, with their defaults
def app(Map args) {
  def allowed = ['type', 'name', 'sonarProjectKey', 'javaVersion', 'pythonVersion', 'nodeVersion',
                 'imageGroup', 'dockerfile', 'buildImage', 'publish', 'trivyWaiverUntil']
  def unknown = args.keySet().findAll { !(it in allowed) }
  if (unknown) {
    error "ciPipeline: unknown parameter(s) ${unknown}, allowed: ${allowed}"
  }
  if (!(args.type in ['maven', 'python', 'node'])) {
    error "ciPipeline: type must be maven, python or node (got '${args.type}')"
  }
  def cfg = call()
  def app = [
    type            : args.type,
    name            : args.name,
    sonarProjectKey : args.sonarProjectKey ?: args.name,
    javaVersion     : (args.javaVersion ?: '17').toString(),
    pythonVersion   : (args.pythonVersion ?: '3.12').toString(),
    nodeVersion     : (args.nodeVersion ?: '22').toString(),
    imageGroup      : args.imageGroup ?: 'dev-backend',
    dockerfile      : args.dockerfile ?: 'Dockerfile',
    buildImage      : args.buildImage != false,
    publish         : args.publish != null ? args.publish : (args.type == 'maven'),
    trivyWaiverUntil: args.trivyWaiverUntil
  ]
  ['name', 'sonarProjectKey', 'imageGroup', 'dockerfile'].each { k ->
    if (!app[k] || !(app[k] ==~ /[A-Za-z0-9][A-Za-z0-9._\/-]*/)) {
      error "ciPipeline: invalid ${k} '${app[k]}'"
    }
  }
  if (app.trivyWaiverUntil && !(app.trivyWaiverUntil ==~ /\d{4}-\d{2}-\d{2}/)) {
    error "ciPipeline: trivyWaiverUntil must be YYYY-MM-DD (got '${app.trivyWaiverUntil}')"
  }
  def versions = [maven: app.javaVersion, python: app.pythonVersion, node: app.nodeVersion]
  if (!cfg.images[app.type][versions[app.type]]) {
    error "ciPipeline: ${app.type} version ${versions[app.type]} not supported, use one of ${cfg.images[app.type].keySet()}"
  }
  def branch = env.BRANCH_NAME ?: 'develop'
  app.branch = branch
  // Only these branches publish packages and push images; feature branches and MRs only verify
  app.protectedBranch = branch in ['main', 'develop'] || branch.startsWith('release/')
  return app
}
