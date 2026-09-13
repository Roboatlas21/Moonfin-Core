buildscript {
    repositories {
        maven {
            url = uri("$rootDir/.media3/repo")
        }
        google()
        mavenCentral()
    }
    dependencies {
        // Moonfin's Android/Kotlin plugin versions.
        classpath("com.android.tools.build:gradle:8.13.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")

        // Required by Media3 1.10.1 legacy module build.gradle files.
    }
}

allprojects {
    repositories {
        maven {
            url = uri("$rootDir/.media3/repo")
        }
        google()
        mavenCentral()
    }
}

val media3Version = "1.10.1"

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    configurations.configureEach {
        resolutionStrategy.dependencySubstitution {
            substitute(module("androidx.media3:media3-exoplayer-hls:1.10.1"))
                .using(module("androidx.media3:media3-exoplayer-hls:1.10.1-moonfin-trace"))

            substitute(module("androidx.media3:media3-extractor:1.10.1"))
                .using(module("androidx.media3:media3-extractor:1.10.1-moonfin-trace"))
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
