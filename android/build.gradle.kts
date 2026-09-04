allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val requestedBuildDir = providers.environmentVariable("EMPORION_BUILD_DIR").orNull
val newBuildDir: Directory = if (requestedBuildDir.isNullOrBlank()) {
    rootProject.layout.buildDirectory.dir("../../build").get()
} else {
    rootProject.layout.projectDirectory.dir(requestedBuildDir)
}
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
