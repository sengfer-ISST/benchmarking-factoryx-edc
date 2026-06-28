/********************************************************************************
 * Copyright (c) 2026 Contributors to the Factory-X project
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/

// Factory-X identity-OFF (benchmarking G2) extension. Provides in-process mock
// implementations of IdentityService / SecureTokenService / DidPublicKeyResolver /
// AudienceResolver so the control plane runs with NO external Identity Hub / STS and
// NO signature verification — while keeping fx-policy in force (the mock injects a
// MembershipCredential). Ported from the project's own e2e fixtures
// (MockVcIdentityService + SignServicesExtension). USE ONLY for benchmarking.

plugins {
    `java-library`
    `maven-publish`
}

dependencies {
    api(libs.edc.spi.core)              // IdentityService, AudienceResolver, ServiceExtension, Result, TypeManager
    implementation(libs.edc.spi.protocol)       // DefaultParticipantIdExtractionFunction (needed by DSP core)
    implementation(libs.edc.spi.identitytrust)  // SecureTokenService
    implementation(libs.edc.spi.identity.did)   // DidPublicKeyResolver
    implementation(libs.edc.spi.vc)             // VerifiableCredential model
    implementation(libs.edc.lib.token)          // JwtGenerationService, DefaultJwsSignerProvider, KeyIdDecorator, TokenDecorator
    implementation(libs.edc.lib.cryptocommon)   // nimbus ECKey/ECKeyGenerator (transitive)
}
