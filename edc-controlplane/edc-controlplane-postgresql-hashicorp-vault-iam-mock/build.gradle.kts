/********************************************************************************
 * Copyright (c) 2024 T-Systems International GmbH
 *
 * See the NOTICE file(s) distributed with this work for additional
 * information regarding copyright ownership.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/

// IDENTITY OFF (G2) runnable control plane. Identical to
// edc-controlplane-postgresql-hashicorp-vault except it pulls the iam-mock base
// instead of the DCP base. `./gradlew :edc-controlplane:edc-controlplane-postgresql-hashicorp-vault-iam-mock:dockerize`
// produces image  edc-controlplane-postgresql-hashicorp-vault-iam-mock:latest
// which coexists with the identity-ON image so both arms can run.

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
    }
    runtimeOnly(project(":edc-controlplane:edc-controlplane-base-iam-mock"))
}


tasks.withType<ShadowJar> {
    mergeServiceFiles()
    archiveFileName.set("${project.name}.jar")
    transform(com.github.jengelman.gradle.plugins.shadow.transformers.Log4j2PluginsCacheFileTransformer())
}


application {
    mainClass.set("org.eclipse.edc.boot.system.runtime.BaseRuntime")
}
