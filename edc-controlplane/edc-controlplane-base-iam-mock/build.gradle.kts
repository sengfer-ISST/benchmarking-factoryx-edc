/********************************************************************************
 * Copyright (c) 2024 T-Systems International GmbH
 * Copyright (c) 2025 SAP SE
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

// IDENTITY OFF (G2) control-plane base — benchmarking variant of
// edc-controlplane-base. The ONLY difference from the identity-ON base is the
// identity layer: the DCP stack (fx-dcp + did-validation) is replaced by the
// stock EDC iam-mock extension, which supplies a no-op IdentityService. All
// other Factory-X extensions (json-ld, contract-validation, data-flow props,
// dataspace-protocol, mqtt, fx-policy) are kept identical so that identity is
// the only varied factor between the ON and OFF arms.
//
// NOTE: fx-policy/contract-validation/dataspace-protocol depend only on EDC SPI
// interfaces (identity-trust, policy-engine), not on the fx-dcp implementation,
// so they remain wired correctly against iam-mock. Because iam-mock issues no
// MembershipCredential, the seeded contract/access policies for this arm must be
// OPEN (no credential constraint) — otherwise the policy engine denies. See the
// OFF compose / seed for the open-policy definitions.

plugins {
    `java-library`
    id(libs.plugins.swagger.get().pluginId)
}

dependencies {
    runtimeOnly(libs.eclipse.tractusx.edc.controlplane.base) {
        exclude("org.eclipse.tractusx.edc", "cx-policy")
        exclude("org.eclipse.tractusx.edc", "tx-dcp")
        exclude("org.eclipse.tractusx.edc", "bdrs-client")
        exclude("org.eclipse.tractusx.edc", "data-flow-properties-provider")
        exclude("org.eclipse.tractusx.edc", "bpn-validation")
        exclude("org.eclipse.tractusx.edc", "agreements-bpns")
        exclude("org.eclipse.tractusx.edc", "connector-discovery-api")
        exclude("org.eclipse.tractusx.edc", "provision-additional-headers")
        exclude("org.eclipse.tractusx.edc", "dataspace-protocol")
        exclude("org.eclipse.tractusx.edc", "json-ld-core")
    }

    // fx-edc extensions (unchanged vs the identity-ON base)
    runtimeOnly(project(":edc-extensions:fx-json-ld-core"))
    runtimeOnly(project(":edc-extensions:contract-validation"))
    runtimeOnly(project(":edc-extensions:data-flow-properties-provider"))
    runtimeOnly(project(":edc-extensions:dataspace-protocol"))
    runtimeOnly(project(":edc-extensions:mqtt"))
    // Credentials FX policies (depends only on identity-trust SPI, safe without fx-dcp)
    runtimeOnly(project(":edc-extensions:fx-policy"))

    // IDENTITY OFF: iam-mock replaces the DCP identity stack.
    //   - identity-ON base uses: project(":edc-extensions:dcp:fx-dcp")
    //                            project(":edc-extensions:did-validation")
    //   - identity-OFF base uses:
    runtimeOnly(libs.edc.iam.mock)
}
