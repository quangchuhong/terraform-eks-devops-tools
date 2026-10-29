// Jenkinsfile - Scripted Pipeline + podTemplate (Kubernetes)

def AWS_REGION     = "ap-southeast-1"
def AWS_ACCOUNT_ID = "123456789012"
def ECR_REPO_NAME  = "my-maven-app"
def ECR_REPO       = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

def SONARQUBE_SERVER  = "sonarqube"        // tên cấu hình SonarQube trong Jenkins (Manage Jenkins → Configure System)
def SONAR_PROJECT_KEY = "my-maven-app"

def APP_VERSION = "1.0.0"

podTemplate(
  label: 'maven-ci-pod',
  containers: [
    containerTemplate(
      name: 'jnlp',
      image: 'jenkins/inbound-agent:latest-jdk17',
      args: '${computer.jnlpmac} ${computer.name}',
      resourceRequestCpu: '200m',
      resourceRequestMemory: '256Mi',
      resourceLimitCpu: '500m',
      resourceLimitMemory: '512Mi'
    ),
    containerTemplate(
      name: 'maven',
      image: 'maven:3.8.8-eclipse-temurin-17',
      command: 'cat',
      ttyEnabled: true,
      envVars: [
        envVar(key: 'MAVEN_OPTS', value: '-Dmaven.repo.local=/home/jenkins/.m2/repository')
      ],
      resourceRequestCpu: '500m',
      resourceRequestMemory: '1Gi',
      resourceLimitCpu: '1000m',
      resourceLimitMemory: '2Gi'
    ),
    containerTemplate(
      name: 'sonar',
      image: 'sonarsource/sonar-scanner-cli:latest',
      command: 'cat',
      ttyEnabled: true
    ),
    containerTemplate(
      name: 'docker',
      image: 'docker:24-cli',
      command: 'cat',
      ttyEnabled: true,
      volumeMounts: [
        // giả sử Jenkins agent node có docker.sock; nếu không, bạn dùng dind riêng
        volumeMount(mountPath: '/var/run/docker.sock', name: 'docker-sock')
      ]
    ),
    containerTemplate(
      name: 'trivy',
      image: 'aquasec/trivy:latest',
      command: 'cat',
      ttyEnabled: true
    ),
    containerTemplate(
      name: 'gitops',
      image: 'bit
