import org.junit.Test

import static org.junit.Assert.*

/** Every examples/Jenkinsfile.* must run through the library (the @Library line is what Jenkins resolves). */
class ExampleJenkinsfilesTest {

    private PipelineHarness runExample(String name, String branch = 'develop') {
        def h = new PipelineHarness(BRANCH_NAME: branch)
        def file = new File(h.libDir, "examples/${name}")
        def text = file.readLines().findAll { !it.trim().startsWith('@Library(') }.join('\n')
        assertTrue("${name} must load ci-lib", file.text.contains("@Library('ci-lib@v1.0.0') _"))
        new GroovyShell(h.binding).evaluate(text)
        return h
    }

    @Test
    void springBoot() {
        def h = runExample('Jenkinsfile.springboot')
        assertTrue(h.shScripts.any { it.startsWith('[build] mvn -B -s .ci-settings.xml -f pom.xml clean verify') })
        assertTrue(h.shScripts.any { it.contains('docker push docker-internal.gitlabonlinecom.click/dev-backend/shopping-cart:1.2.0-abc1234') })
        assertEquals('maven:3.9.9-eclipse-temurin-8', h.pod().spec.containers.find { it.name == 'build' }.image)
    }

    @Test
    void mavenLibrary() {
        def h = runExample('Jenkinsfile.maven-library')
        assertFalse(h.stages.contains('Docker Build'))
        assertTrue(h.shScripts.any { it.contains('deploy -DskipTests') })
    }

    @Test
    void mavenMultiModule() {
        def h = runExample('Jenkinsfile.maven-multimodule')
        assertTrue(h.shScripts.any { it.startsWith('[build] mvn -B -s .ci-settings.xml -f pom.xml clean verify -Pci -pl payment-api -am') })
        assertTrue(h.shScripts.any { it.contains('docker build -f payment-api/Dockerfile') })
    }

    @Test
    void python() {
        def h = runExample('Jenkinsfile.python')
        assertTrue(h.shIn('build').any { it.contains('pytest --junitxml=reports/junit.xml') })
        assertTrue(h.shIn('sonar').any { it.contains('sonar-scanner') })
    }

    @Test
    void nodejs() {
        def h = runExample('Jenkinsfile.nodejs')
        assertTrue(h.shIn('build').any { it.contains('npm run test:ci') })
        assertTrue(h.shScripts.any { it.contains('dev-frontend/customer-portal:2.0.0-abc1234') })
    }
}
