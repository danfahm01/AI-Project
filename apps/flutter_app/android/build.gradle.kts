allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Some plugins pin an old Android SDK and NDK. mp_audio_stream 0.3.0 (the latest
// release) compiles against android-31 with NDK 21, but its AndroidX dependencies
// need compileSdk 34+, and Google Play needs native libraries built with a current
// NDK (16 KB memory pages). Raise every Android library to the app's compileSdk and
// minSdk (never lower them) and build its native code with the app's NDK.
subprojects {
    pluginManager.withPlugin("com.android.library") {
        val appProject = project(":app")
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
            finalizeDsl { library ->
                val app = appProject.extensions.getByType<com.android.build.api.dsl.ApplicationExtension>()
                val appCompileSdk = app.compileSdk
                if (appCompileSdk != null && (library.compileSdk ?: 0) < appCompileSdk) {
                    library.compileSdk = appCompileSdk
                }
                val appMinSdk = app.defaultConfig.minSdk
                if (appMinSdk != null && (library.defaultConfig.minSdk ?: 0) < appMinSdk) {
                    library.defaultConfig.minSdk = appMinSdk
                }
                library.ndkVersion = app.ndkVersion
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
