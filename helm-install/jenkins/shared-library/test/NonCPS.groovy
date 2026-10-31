import java.lang.annotation.ElementType
import java.lang.annotation.Retention
import java.lang.annotation.RetentionPolicy
import java.lang.annotation.Target

// Stand-in for com.cloudbees.groovy.cps.NonCPS (only needed so vars/*.groovy compile in tests)
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
@interface NonCPS {}
