/********************************************************************************
 * Copyright (c) 2024 T-Systems International GmbH
 * Copyright (c) 2026 Contributors to the Factory-X project
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/

// IDENTITY OFF (benchmarking G2) runnable control plane. Identical to
// edc-controlplane-postgresql-hashicorp-vault except it pulls the fx-mock-identity
// base instead of the DCP base. `./gradlew :edc-controlplane:edc-controlplane-postgresql-hashicorp-vault-fxmock:dockerize`
// produces image edc-controlplane-postgresql-hashicorp-vault-fxmock:latest, which
// coexists with the identity-ON image so both arms can run.

import com.github.jengelman.gradle.plugins.shadow.tasks.ShadowJar

plugins {
    `java-library`
    id("application")
    alias(libs.plugins.shadow)
}

dependencies {
    runtimeOnly(libs.eclipse.tractusx.edc.controlplane.postgresql.hashicorp.vault) {
        exclude("org.eclipse.tractusx.edc", "edc-controlplane-base")
        exclude("org.eclipse.tractusx.edc", "bpns-evaluation-store-sql")
        // Mirror the base (Strategy 2): exclude the DCP providers + the two registry
        // consumers so fx-mock-identity is the sole provider.
        exclude("org.eclipse.tractusx.edc", "tx-dcp")
        exclude("org.eclipse.tractusx.edc", "tx-dcp-sts-dim")
        exclude("org.eclipse.edc", "identity-trust-core")
        exclude("org.eclipse.edc", "identity-did-core")
        exclude("org.eclipse.edc", "identity-trust-issuers-configuration")
        exclude("org.eclipse.edc", "identity-did-web")
    }
    runtimeOnly(project(":edc-controlplane:edc-controlplane-base-fxmock"))
}

tasks.withType<ShadowJar> {
    mergeServiceFiles()
    archiveFileName.set("${project.name}.jar")
    transform(com.github.jengelman.gradle.plugins.shadow.transformers.Log4j2PluginsCacheFileTransformer())
}

application {
    mainClass.set("org.eclipse.edc.boot.system.runtime.BaseRuntime")
}
