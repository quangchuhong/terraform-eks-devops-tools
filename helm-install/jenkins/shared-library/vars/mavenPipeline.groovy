// Pipeline for Maven applications (Java, Spring Boot): ciPipeline with type 'maven'.
//
//   @Library('ci-lib@v1.0.0') _
//   mavenPipeline(name: 'shopping-cart', javaVersion: '8')
//
// Maven parameters: javaVersion (8, 11, 17, 21), pomFile, mavenGoals, mavenArgs, publish (default true),
// buildImage, dockerfile, imageGroup, sonarProjectKey, trivyWaiverUntil. See ciConfig.app().

def call(Map args = [:]) {
  if (args.type && args.type != 'maven') {
    error "mavenPipeline: type is always 'maven' (got '${args.type}'), use ciPipeline for other types"
  }
  ciPipeline(args + [type: 'maven'])
}
