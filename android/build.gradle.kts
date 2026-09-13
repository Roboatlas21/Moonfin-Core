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
        resolutionStrategy.eachDependency {
            // This force covers only the androidx.media3 group. The bundled
            // FFmpeg audio extension (org.jellyfin.media3:media3-ffmpeg-decoder
            // in moonfin_native_video) isn't rewritten and ships against
            // media3 1.9.x, since no 1.10.x build of it exists yet.
            // Media3VideoView emits an "ffmpegDecoderDiagnostics" event at
            // first player build. If that ever reports unavailable, pin
            // media3Version back to the decoder's line until jellyfin
            // publishes a matched artifact.
            if (requested.group == "androidx.media3") {
                useVersion(media3Version)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
