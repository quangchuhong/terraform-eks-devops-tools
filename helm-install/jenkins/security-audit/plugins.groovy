// Prints every installed plugin as name:version, ready to paste into controller.installPlugins
jenkins.model.Jenkins.get().pluginManager.plugins.sort(false) { it.shortName }.each { println "    - ${it.shortName}:${it.version}" }
