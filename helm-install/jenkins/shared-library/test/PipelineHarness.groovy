import groovy.json.JsonSlurper

/**
 * Minimal Jenkins pipeline emulator for the vars/ scripts of the library.
 * Every pipeline step is a closure in the shared Binding and records its call in `calls`;
 * each global variable (vars/<name>.groovy) is a closure delegating to the parsed script,
 * so both `ciConfig()` and `ciConfig.app(args)` work as in Jenkins.
 */
class PipelineHarness {

    static class PipelineError extends RuntimeException {
        PipelineError(String msg) { super(msg) }
    }

    final Binding binding = new Binding()
    final List<String> calls = []        // "step: detail", in call order
    final List<String> stages = []
    final List<String> shScripts = []    // [container] script
    final List<String> unstableMessages = []
    final Map<String, String> writtenFiles = [:]
    final List<String> podYamls = []
    String libDir
    String currentContainer = 'jnlp'

    // Behaviour knobs set by the tests
    Map pom = [version: '1.2.0']
    String qualityGate = 'OK'
    int trivyGateStatus = 0
    String commit = 'abc1234'

    PipelineHarness(Map env = [:]) {
        libDir = System.getProperty('lib.dir', '.')
        binding.setVariable('env', [BRANCH_NAME: 'main', WORKSPACE: '/home/jenkins/agent/workspace/app',
                                    BUILD_NUMBER: '7', GIT_URL: 'http://gitlab.example/app.git'] + env)
        binding.setVariable('currentBuild', new Expando(displayName: '#7', result: null))
        binding.setVariable('scm', 'SCM')
        binding.setVariable('POD_LABEL', 'pod-label')
        registerSteps()
        loadVars()
    }

    private void record(String step, Object detail = '') {
        calls << "${step}: ${detail}".toString()
    }

    private void loadVars() {
        def shell = new GroovyShell(this.class.classLoader, binding)
        new File(libDir, 'vars').eachFileMatch(~/.*\.groovy/) { File f ->
            Script script = shell.parse(f)
            script.binding = binding
            Closure proxy = { Object[] args -> script.invokeMethod('call', args) }
            proxy.delegate = script
            proxy.resolveStrategy = Closure.DELEGATE_FIRST
            binding.setVariable(f.name - '.groovy', proxy)
        }
    }

    private void registerSteps() {
        def b = binding
        def h = this
        b.setVariable('echo', { Object m -> h.record('echo', m) })
        b.setVariable('error', { Object m -> h.record('error', m); throw new PipelineError(m.toString()) })
        b.setVariable('unstable', { Object m -> h.record('unstable', m); h.unstableMessages << m.toString() })
        b.setVariable('stage', { String name, Closure body -> h.stages << name; h.record('stage', name); body() })
        b.setVariable('timeout', { Map m, Closure body -> h.record('timeout', m); body() })
        b.setVariable('properties', { List l -> h.record('properties', l.size()) })
        b.setVariable('disableConcurrentBuilds', { -> 'disableConcurrentBuilds' })
        b.setVariable('logRotator', { Map m -> m })
        b.setVariable('buildDiscarder', { Object o -> o })
        b.setVariable('podTemplate', { Map m, Closure body -> h.podYamls << m.yaml.toString(); h.record('podTemplate', ''); body() })
        b.setVariable('node', { Object label, Closure body -> h.record('node', label); body() })
        b.setVariable('container', { String name, Closure body ->
            def previous = h.currentContainer
            h.currentContainer = name
            try { body() } finally { h.currentContainer = previous }
        })
        b.setVariable('checkout', { Object o -> h.record('checkout', o) })
        b.setVariable('sh', { Object arg ->
            Map m = arg instanceof Map ? arg : [script: arg.toString()]
            String script = m.script.toString()
            h.shScripts << "[${h.currentContainer}] ${script.trim()}".toString()
            h.record('sh', "[${h.currentContainer}] ${script.trim().readLines().first()}")
            if (m.returnStdout) {
                return script.contains('git rev-parse') ? h.commit + '\n' : ''
            }
            if (m.returnStatus) {
                return script.contains('--exit-code 1') ? h.trivyGateStatus : 0
            }
            return null
        })
        b.setVariable('readMavenPom', { Map m -> h.record('readMavenPom', m.file); h.pom })
        b.setVariable('readJSON', { Map m -> h.record('readJSON', m.file); [version: '2.0.0'] })
        b.setVariable('readFile', { Object f -> '' })
        b.setVariable('fileExists', { Object f -> false })
        b.setVariable('writeFile', { Map m -> h.writtenFiles[m.file.toString()] = m.text.toString(); h.record('writeFile', m.file) })
        b.setVariable('libraryResource', { String p -> new File(h.libDir, "resources/${p}").text })
        b.setVariable('usernamePassword', { Map m -> m })
        b.setVariable('withCredentials', { List l, Closure body -> h.record('withCredentials', l*.credentialsId); body() })
        b.setVariable('withEnv', { List l, Closure body -> h.record('withEnv', l); body() })
        b.setVariable('withSonarQubeEnv', { String n, Closure body -> h.record('withSonarQubeEnv', n); body() })
        b.setVariable('waitForQualityGate', { -> h.record('waitForQualityGate', h.qualityGate); [status: h.qualityGate] })
        b.setVariable('junit', { Object o -> h.record('junit', o) })
        b.setVariable('archiveArtifacts', { Map m -> h.record('archiveArtifacts', m.artifacts) })
    }

    /** Calls a global variable like a Jenkinsfile does: run('mavenPipeline', [name: 'x']) */
    Object run(String var, Object... args) {
        Closure c = (Closure) binding.getVariable(var)
        return c.call(args)
    }

    boolean ran(String step, String text = '') {
        calls.any { it.startsWith("${step}: ") && it.contains(text) }
    }

    List<String> shIn(String container) {
        shScripts.findAll { it.startsWith("[${container}] ") }
    }

    Map pod() {
        new JsonSlurper().parseText(podYamls.last()) as Map
    }
}
