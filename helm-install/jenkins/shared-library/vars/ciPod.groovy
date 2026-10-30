// Agent pod for one build: jnlp + the language build container + the SonarQube scanner
// (+ docker and trivy when the app builds an image). Runs on the CI node group.

def call(Map cfg, Map app, Closure body) {
  def containers = [
    [name: 'jnlp', image: cfg.images.jnlp,
     resources: res('200m', '256Mi', '500m', '512Mi')]
  ]

  if (app.type == 'maven') {
    containers << tool('build', cfg.images.maven[app.javaVersion], res('500m', '1Gi', '1', '2Gi'))
    // The Maven Sonar plugin needs Java 17+; older builds get a second Maven container for the analysis
    if ((app.javaVersion as Integer) < 17) {
      containers << tool('sonar', cfg.images.maven['17'], res('500m', '1Gi', '1', '2Gi'))
    }
  } else if (app.type == 'python') {
    containers << tool('build', cfg.images.python[app.pythonVersion], res('250m', '512Mi', '1', '1Gi'))
    containers << tool('sonar', cfg.images.sonar, res('250m', '1Gi', '1', '2Gi'))
  } else {
    containers << tool('build', cfg.images.node[app.nodeVersion], res('500m', '1Gi', '1', '2Gi'))
    containers << tool('sonar', cfg.images.sonar, res('250m', '1Gi', '1', '2Gi'))
  }

  if (app.buildImage) {
    containers << [name: 'docker', image: cfg.images.docker, tty: true,
                   securityContext: [privileged: true],
                   args: ["--insecure-registry=${cfg.registry}".toString()],
                   resources: res('500m', '1Gi', '2', '4Gi')]
    containers << tool('trivy', cfg.images.trivy, res('100m', '256Mi', '1', '1Gi'))
  }

  def pod = [
    apiVersion: 'v1',
    kind      : 'Pod',
    spec      : [
      nodeSelector: [workload: 'ci-agents'],
      tolerations : [[key: 'workload', operator: 'Equal', value: 'ci-agents', effect: 'NoSchedule']],
      containers  : containers
    ]
  ]

  // JSON is valid YAML
  podTemplate(yaml: groovy.json.JsonOutput.toJson(pod)) {
    node(POD_LABEL) {
      body()
    }
  }
}

def tool(String name, String image, Map resources) {
  return [name: name, image: image, command: ['cat'], tty: true, resources: resources]
}

def res(String cpu, String memory, String cpuLimit, String memoryLimit) {
  return [requests: [cpu: cpu, memory: memory], limits: [cpu: cpuLimit, memory: memoryLimit]]
}
