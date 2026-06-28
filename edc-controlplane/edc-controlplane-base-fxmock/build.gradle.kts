/********************************************************************************
 * Copyright (c) 2024 T-Systems International GmbH
 * Copyright (c) 2025 SAP SE
 * Copyright (c) 2026 Contributors to the Factory-X project
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/

// IDENTITY OFF (benchmarking G2) control-plane base — variant of
// edc-controlplane-base. Identity is the ONLY varied factor: the DCP stack
// (fx-dcp + did-validation + the EDC identity-trust impl providers) is replaced by
// the in-process mock providers in fx-mock-identity. All other Factory-X extensions
// are kept identical so the ON/OFF deployments differ only in identity.
//
// Strategy 2 (exclude-and-provide): the EDC DCP identity-trust IMPL modules that
// provide IdentityService / SecureTokenService / DidPublicKeyResolver /
// AudienceResolver are excluded so fx-mock-identity is the sole provider. This is
// safe (unlike the abandoned external iam-mock) because fx-mock-identity SUPPLIES
// those services — including SecureTokenService, whose absence cascaded before.
// The exact exclusion set is iterated empirically at boot (see PLAN.md §7).

plugins {
    `java-library`
    id(libs.plugins.swagger.get().pluginId)
}

dependencies {
    runtimeOnly(libs.eclipse.tractusx.edc.controlplane.base) {
        exclude("org.eclipse.tractusx.edc", "cx-policy")
        exclude("org.eclipse.tractusx.edc", "tx-dcp")
        exclude("org.eclipse.tractusx.edc", "tx-dcp-sts-dim")
        exclude("org.eclipse.tractusx.edc", "bdrs-client")
        exclude("org.eclipse.tractusx.edc", "data-flow-properties-provider")
        exclude("org.eclipse.tractusx.edc", "bpn-validation")
        exclude("org.eclipse.tractusx.edc", "agreements-bpns")
        exclude("org.eclipse.tractusx.edc", "connector-discovery-api")
        exclude("org.eclipse.tractusx.edc", "provision-additional-headers")
        exclude("org.eclipse.tractusx.edc", "dataspace-protocol")
        exclude("org.eclipse.tractusx.edc", "json-ld-core")

        // IDENTITY OFF (Strategy 2 — sole provider, deterministic). EDC last-registered-wins
        // makes Strategy 1's override go the wrong way, so we EXCLUDE the EDC providers of the
        // services fx-mock-identity supplies (IdentityService/SecureTokenService/AudienceResolver
        // from identity-trust-core; DidPublicKeyResolver from identity-did-core) and the two
        // extensions that consume the now-absent registries (identity-trust-issuers-configuration
        // -> TrustedIssuerRegistry; identity-did-web -> DidResolverRegistry). The remaining
        // unavoidable consumer is the DSP core (DefaultParticipantIdExtractionFunction), which
        // fx-mock-identity also provides. Keep the *-sts-remote-lib LIBRARY (no NoClassDefFound).
        exclude("org.eclipse.edc", "identity-trust-core")
        exclude("org.eclipse.edc", "identity-did-core")
        exclude("org.eclipse.edc", "identity-trust-issuers-configuration")
        exclude("org.eclipse.edc", "identity-did-web")
    }

    // fx-edc extensions (unchanged vs the identity-ON base)
    runtimeOnly(project(":edc-extensions:fx-json-ld-core"))
    runtimeOnly(project(":edc-extensions:contract-validation"))
    runtimeOnly(project(":edc-extensions:data-flow-properties-provider"))
    runtimeOnly(project(":edc-extensions:dataspace-protocol"))
    runtimeOnly(project(":edc-extensions:mqtt"))
    runtimeOnly(project(":edc-extensions:fx-policy"))

    // IDENTITY OFF: in-process mock identity instead of DCP.
    //   identity-ON base uses: project(":edc-extensions:dcp:fx-dcp") + project(":edc-extensions:did-validation")
    runtimeOnly(project(":edc-extensions:fx-mock-identity"))
}
