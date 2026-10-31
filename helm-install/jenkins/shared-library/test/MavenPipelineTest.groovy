import org.junit.Test

import static org.junit.Assert.*

class MavenPipelineTest {

    static final String IMAGE = 'docker-internal.gitlabonlinecom.click/dev-backend/shopping-cart:1.2.0-abc1234'
    static final List<String> ALL_STAGES = ['Checkout', 'Build & Test', 'SonarQube Analysis', 'Quality Gate',
                                            'Publish Package', 'Docker Build', 'Trivy Scan Image', 'Push Image']

    private PipelineHarness runOn(String branch, Map args = [:], Closure setup = {}) {
        def h = new PipelineHarness(BRANCH_NAME: branch)
        setup(h)
        h.run('mavenPipeline', [name: 'shopping-cart'] + args)
        return h
    }

    @Test
    void mainBranchRunsEveryStage() {
        def h = runOn('main')
        assertEquals(ALL_STAGES, h.stages)
        assertTrue(h.ran('sh', '[build] mvn -B -s .ci-settings.xml -f pom.xml clean verify'))
        assertTrue(h.ran('junit', '**/target/surefire-reports/*.xml'))
        assertTrue(h.ran('withSonarQubeEnv', 'SonarQube'))
        assertTrue(h.ran('sh', '[build] mvn -B -s .ci-settings.xml -f pom.xml deploy -DskipTests'))
        assertTrue(h.shIn('docker').any { it.contains("docker build -f Dockerfile -t ${IMAGE}") })
        assertTrue(h.shIn('docker').any { it.contains("docker push ${IMAGE}") })
        assertEquals('#7 1.2.0-abc1234', h.binding.getVariable('currentBuild').displayName)
    }

    @Test
    void sonarRunsWithPomVersionAndSafeDirectory() {
        def h = runOn('main')
        def sonar = h.shScripts.find { it.contains('sonar-maven-plugin:5.1.0.4751:sonar') }
        assertNotNull(sonar)
        assertTrue(sonar.startsWith('[build] '))
        assertTrue(sonar.contains('git config --global --add safe.directory'))
        assertTrue(sonar.contains('-Dsonar.projectKey=shopping-cart'))
        assertTrue(sonar.contains('-Dsonar.projectVersion=1.2.0'))
        assertTrue(sonar.contains('-Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml'))
    }

    @Test
    void java8BuildsOnJdk8AndAnalysesOnJdk17() {
        def h = runOn('main', [javaVersion: '8'])
        def containers = h.pod().spec.containers.collectEntries { [(it.name): it.image] }
        assertEquals('maven:3.9.9-eclipse-temurin-8', containers.build)
        assertEquals('maven:3.9.9-eclipse-temurin-17', containers.sonar)
        assertTrue(h.shScripts.find { it.contains('sonar-maven-plugin') }.startsWith('[sonar] '))
        assertTrue(h.ran('sh', '[build] mvn -B -s .ci-settings.xml -f pom.xml clean verify'))
    }

    @Test
    void podRunsOnCiNodeGroupWithDindForTheRegistry() {
        def spec = runOn('main').pod().spec
        assertEquals([workload: 'ci-agents'], spec.nodeSelector)
        assertEquals([[key: 'workload', operator: 'Equal', value: 'ci-agents', effect: 'NoSchedule']], spec.tolerations)
        def names = spec.containers*.name
        assertEquals(['jnlp', 'build', 'docker', 'trivy'], names)
        def docker = spec.containers.find { it.name == 'docker' }
        assertTrue(docker.securityContext.privileged)
        assertEquals(['--insecure-registry=docker-internal.gitlabonlinecom.click'], docker.args)
        assertEquals('jenkins/inbound-agent:3355.v388858a_47b_33-3-jdk21', spec.containers[0].image)
    }

    @Test
    void featureBranchVerifiesButDoesNotPublishOrPush() {
        def h = runOn('feature/login')
        assertEquals(ALL_STAGES, h.stages)
        assertFalse(h.shScripts.any { it.contains('deploy -DskipTests') })
        assertFalse(h.shScripts.any { it.contains('docker push') })
        assertTrue(h.shScripts.any { it.contains('docker build') })
        assertTrue(h.shScripts.any { it.contains('trivy image') })
        assertTrue(h.ran('echo', 'images are pushed from main, develop and release/* only'))
    }

    @Test
    void customPomGoalsAndArgs() {
        def h = runOn('develop', [pomFile: 'services/api/pom.xml', mavenGoals: 'clean install', mavenArgs: '-Pci'])
        assertTrue(h.ran('readMavenPom', 'services/api/pom.xml'))
        assertTrue(h.ran('sh', '[build] mvn -B -s .ci-settings.xml -f services/api/pom.xml clean install -Pci'))
        assertTrue(h.ran('sh', '[build] mvn -B -s .ci-settings.xml -f services/api/pom.xml deploy -DskipTests -Pci'))
    }

    @Test
    void versionInheritedFromParentPom() {
        def h = runOn('main', [:]) { PipelineHarness x -> x.pom = [version: null, parent: [version: '3.0.0-SNAPSHOT']] }
        assertTrue(h.shScripts.any { it.contains('dev-backend/shopping-cart:3.0.0-SNAPSHOT-abc1234') })
    }

    @Test
    void mavenSettingsHaveNexusMirrorAndNoPassword() {
        def h = runOn('main')
        def settings = h.writtenFiles['.ci-settings.xml']
        assertTrue(settings.contains('<url>http://nexus.nexus.svc.cluster.local:8081/repository/maven-public/</url>'))
        assertTrue(settings.contains('${env.NX_PASS}'))
        assertFalse(settings.contains('@NEXUS_URL@'))
        assertTrue(h.ran('withCredentials', 'nexus-creds'))
    }

    @Test
    void failedQualityGateStopsThePipeline() {
        try {
            runOn('main', [:]) { PipelineHarness x -> x.qualityGate = 'ERROR' }
            fail('expected the Quality Gate to stop the build')
        } catch (PipelineHarness.PipelineError e) {
            assertEquals('Quality Gate failed: ERROR', e.message)
        }
    }

    @Test
    void trivyFindingsFailTheBuildWithoutWaiver() {
        def h = new PipelineHarness(BRANCH_NAME: 'main')
        h.trivyGateStatus = 1
        try {
            h.run('mavenPipeline', [name: 'shopping-cart'])
            fail('expected Trivy to stop the build')
        } catch (PipelineHarness.PipelineError e) {
            assertTrue(e.message.startsWith('Trivy: HIGH/CRITICAL vulnerabilities found'))
        }
        assertFalse(h.stages.contains('Push Image'))
        assertTrue(h.ran('archiveArtifacts', 'sbom.cdx.json'))
    }

    @Test
    void trivyWaiverMakesTheBuildUnstableAndStillPushes() {
        def h = runOn('main', [trivyWaiverUntil: '2999-12-31']) { PipelineHarness x -> x.trivyGateStatus = 1 }
        assertEquals(1, h.unstableMessages.size())
        assertTrue(h.unstableMessages[0].contains('waiver until 2999-12-31'))
        assertTrue(h.shScripts.any { it.contains('docker push') })
    }

    @Test
    void expiredWaiverFailsTheBuild() {
        try {
            runOn('main', [trivyWaiverUntil: '2020-01-01']) { PipelineHarness x -> x.trivyGateStatus = 1 }
            fail('expected an expired waiver to fail')
        } catch (PipelineHarness.PipelineError e) {
            assertTrue(e.message.startsWith('Trivy: HIGH/CRITICAL'))
        }
    }

    @Test
    void trivyProducesReportsAndSbom() {
        def h = runOn('main')
        def trivy = h.shIn('trivy').join('\n')
        assertTrue(trivy.contains('--server http://trivy.trivy.svc.cluster.local:9090 --input image.tar'))
        assertTrue(trivy.contains('--format cyclonedx --output sbom.cdx.json'))
        assertTrue(trivy.contains('--severity HIGH,CRITICAL --exit-code 1'))
        assertTrue(h.ran('archiveArtifacts', 'trivy-report.json,trivy-report.txt,sbom.cdx.json'))
    }

    @Test
    void libraryWithoutImage() {
        def h = runOn('main', [buildImage: false])
        assertEquals(ALL_STAGES.take(5), h.stages)
        assertEquals(['jnlp', 'build'], h.pod().spec.containers*.name)
    }

    @Test
    void publishCanBeDisabled() {
        def h = runOn('main', [publish: false])
        assertFalse(h.shScripts.any { it.contains('deploy -DskipTests') })
        assertTrue(h.ran('echo', 'skipped (publish=false'))
    }

    @Test
    void mavenPipelineRefusesOtherTypes() {
        try {
            runOn('main', [type: 'node'])
            fail('expected an error')
        } catch (PipelineHarness.PipelineError e) {
            assertTrue(e.message.contains("type is always 'maven'"))
        }
    }
}
