/********************************************************************************
 * Copyright (c) 2023 Bayerische Motoren Werke Aktiengesellschaft (BMW AG)
 * Copyright (c) 2025 SAP SE
 * Copyright (c) 2026 Contributors to the Factory-X project
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/

package org.factoryx.edc.mock.identity;

import com.fasterxml.jackson.core.type.TypeReference;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.CredentialSubject;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.Issuer;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.VerifiableCredential;
import org.eclipse.edc.spi.iam.ClaimToken;
import org.eclipse.edc.spi.iam.IdentityService;
import org.eclipse.edc.spi.iam.TokenParameters;
import org.eclipse.edc.spi.iam.TokenRepresentation;
import org.eclipse.edc.spi.iam.VerificationContext;
import org.eclipse.edc.spi.result.Result;
import org.eclipse.edc.spi.types.TypeManager;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import static java.lang.String.format;

/**
 * An {@link IdentityService} that injects a MembershipCredential into every token and
 * verifies by parsing it back — NO signature, NO DID resolution, NO credential-service
 * query. Ported verbatim (behaviour) from the project's e2e fixtures; the only change
 * is that the {@link TypeManager} is injected instead of constructed, so this can live
 * in a runtime extension. Benchmarking identity-OFF use only.
 */
public class MockVcIdentityService implements IdentityService {

    private static final String VC_CLAIM = "vc";
    private final String did;
    private final TypeManager typeManager;

    public MockVcIdentityService(String did, TypeManager typeManager) {
        this.did = did;
        this.typeManager = typeManager;
    }

    @Override
    public Result<TokenRepresentation> obtainClientCredentials(TokenParameters parameters) {
        var credentials = List.of(membershipCredential());
        var token = Map.of(VC_CLAIM, credentials);

        var tokenRepresentation = TokenRepresentation.Builder.newInstance()
                .token(typeManager.writeValueAsString(token))
                .build();
        return Result.success(tokenRepresentation);
    }

    @Override
    public Result<ClaimToken> verifyJwtToken(TokenRepresentation tokenRepresentation, VerificationContext verificationContext) {
        var token = tokenRepresentation.getToken().replace("Bearer ", "");
        var tokenParsed = typeManager.readValue(token, Map.class);

        if (tokenParsed.containsKey(VC_CLAIM)) {
            var credentials = typeManager.getMapper().convertValue(tokenParsed.get(VC_CLAIM), new TypeReference<List<VerifiableCredential>>() {
            });
            var claimToken = ClaimToken.Builder.newInstance()
                    .claim(VC_CLAIM, credentials)
                    .build();
            return Result.success(claimToken);
        }
        return Result.failure(format("Expected %s claim, but token did not contain them", VC_CLAIM));
    }

    private VerifiableCredential membershipCredential() {
        return VerifiableCredential.Builder.newInstance()
                .type("VerifiableCredential")
                .type("MembershipCredential")
                .credentialSubject(CredentialSubject.Builder.newInstance()
                        .id(did)
                        .claim("holderIdentifier", did)
                        .build())
                .issuer(new Issuer("issuer", Map.of()))
                .issuanceDate(Instant.now())
                .build();
    }
}
