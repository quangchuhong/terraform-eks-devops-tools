// Read-only security report of the Jenkins controller. Prints settings and IDs only, never secret values.
def j = jenkins.model.Jenkins.get()
def out = { String k, v -> println(String.format('%-34s %s', k, v)) }
def safe = { String k, Closure c -> try { out(k, c()) } catch (Throwable t) { out(k, "ERROR ${t.class.simpleName}: ${t.message}") } }

println '== Core'
safe('Jenkins version')          { jenkins.model.Jenkins.VERSION }
safe('Jenkins URL')              { jenkins.model.JenkinsLocationConfiguration.get().url }
safe('Executors on built-in')    { j.numExecutors }
safe('Agent TCP port')           { j.slaveAgentPort }
safe('Markup formatter')         { j.markupFormatter?.class?.name }

println '== Authentication / authorization'
safe('Security realm')           { j.securityRealm.class.name }
safe('Sign-up allowed')          { j.securityRealm.hasProperty('allowsSignup') ? j.securityRealm.allowsSignup : 'n/a' }
safe('Users (ids)')              { hudson.model.User.getAll()*.id.sort() }
safe('Authorization strategy')   { j.authorizationStrategy.class.name }
safe('Anonymous can READ')       { j.authorizationStrategy.getACL(j).hasPermission2(jenkins.model.Jenkins.ANONYMOUS2, jenkins.model.Jenkins.READ) }
safe('Remember me disabled')     { j.disableRememberMe }
safe('CSRF crumb issuer')        { j.crumbIssuer?.class?.name ?: 'NONE (CSRF protection off)' }

println '== Credentials (ids only)'
safe('System credentials')       {
  com.cloudbees.plugins.credentials.SystemCredentialsProvider.getInstance().credentials.collect { "${it.id} (${it.class.simpleName})" }
}

println '== Script approval'
safe('Pending scripts')          { org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval.get().pendingScripts.size() }
safe('Pending signatures')       { org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval.get().pendingSignatures.size() }

println '== Plugins'
safe('Installed plugins')        { j.pluginManager.plugins.size() }
safe('Plugins with updates')     { j.pluginManager.plugins.findAll { it.hasUpdate() }.collect { "${it.shortName} ${it.version}" }.sort() }

println '== Security warnings (update center)'
safe('Core warnings')            {
  hudson.ExtensionList.lookupSingleton(jenkins.security.UpdateSiteWarningsMonitor).activeCoreWarnings.collect { it.id }
}
safe('Plugin warnings')          {
  hudson.ExtensionList.lookupSingleton(jenkins.security.UpdateSiteWarningsMonitor).activePluginWarningsByPlugin.collect { p, ws -> "${p.shortName} ${p.version}: ${ws*.id}" }.sort()
}

println '== Active administrative monitors'
safe('Monitors')                 { j.administrativeMonitors.findAll { it.isEnabled() && it.isActivated() }*.id.sort() }
