/********************************************************************************
 * Copyright (c) 2024 Bayerische Motoren Werke Aktiengesellschaft (BMW AG)
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

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import org.eclipse.edc.iam.did.spi.resolution.DidPublicKeyResolver;
import org.eclipse.edc.iam.identitytrust.spi.SecureTokenService;
import org.eclipse.edc.iam.verifiablecredentials.spi.model.VerifiableCredential;
import org.eclipse.edc.protocol.spi.DefaultParticipantIdExtractionFunction;
import org.eclipse.edc.runtime.metamodel.annotation.Extension;
import org.eclipse.edc.runtime.metamodel.annotation.Inject;
import org.eclipse.edc.runtime.metamodel.annotation.Provider;
import org.eclipse.edc.security.token.jwt.DefaultJwsSignerProvider;
import org.eclipse.edc.spi.iam.AudienceResolver;
import org.eclipse.edc.spi.iam.IdentityService;
import org.eclipse.edc.spi.result.Result;
import org.eclipse.edc.spi.system.ServiceExtension;
import org.eclipse.edc.spi.system.ServiceExtensionContext;
import org.eclipse.edc.spi.types.TypeManager;
import org.eclipse.edc.token.JwtGenerationService;
import org.eclipse.edc.token.spi.KeyIdDecorator;
import org.eclipse.edc.token.spi.TokenDecorator;

import java.security.PrivateKey;
import java.util.List;

/**
 * Benchmarking identity-OFF (G2) extension for Factory-X. Provides in-process mock
 * implementations of the four identity SPIs that the DCP stack would otherwise supply,
 * so the control plane runs with NO Identity Hub / STS and NO signature verification:
 *
 * <ul>
 *   <li>{@link IdentityService}     -> {@link MockVcIdentityService} (injects a MembershipCredential)</li>
 *   <li>{@link SecureTokenService}  -> local JWT signing with a self-generated key (no remote STS)</li>
 *   <li>{@link DidPublicKeyResolver}-> returns the runtime's own public key (no remote did:web resolution)</li>
 *   <li>{@link AudienceResolver}    -> the counter-party address</li>
 * </ul>
 *
 * Used with a control-plane runtime that excludes the DCP providers of these SPIs
 * (Strategy 2: exclude-and-provide). fx-policy stays in force — the injected
 * MembershipCredential satisfies it, so policy cost is held constant vs. the ON arm.
 *
 * Behaviour ported from the project's own e2e fixtures (MockVcIdentityService +
 * ParticipantRuntimeExtension.SignServicesExtension). DO NOT use outside benchmarking.
 */
@Extension(FxMockIdentityExtension.NAME)
public class FxMockIdentityExtension implements ServiceExtension {

    public static final String NAME = "Factory-X Mock Identity (benchmarking identity-OFF)";

    private static final String ISSUER_ID = "edc.iam.issuer.id";

    @Inject
    private TypeManager typeManager;

    private ECKey key;
    private String kid;

    @Override
    public String name() {
        return NAME;
    }

    @Override
    public void initialize(ServiceExtensionContext context) {
        key(context); // generate the runtime key eagerly
        context.getMonitor().warning("[" + NAME + "] identity verification is MOCKED — for benchmarking only.");
    }

    @Provider
    public IdentityService identityService(ServiceExtensionContext context) {
        return new MockVcIdentityService(context.getConfig().getString(ISSUER_ID), typeManager);
    }

    @Provider
    public SecureTokenService secureTokenService(ServiceExtensionContext context) {
        var ecKey = key(context);
        final PrivateKey privateKey;
        try {
            privateKey = ecKey.toPrivateKey();
        } catch (JOSEException e) {
            throw new RuntimeException(e);
        }
        var jwtGenerationService = new JwtGenerationService(new DefaultJwsSignerProvider(s -> Result.success(privateKey)));
        // SecureTokenService is a functional interface: (claims, bearerAccessScope) -> Result<TokenRepresentation>.
        return (claims, bearerAccessScope) -> {
            TokenDecorator decorator = builder -> {
                claims.forEach(builder::claims);
                return builder;
            };
            return jwtGenerationService.generate(kid, new KeyIdDecorator(kid), decorator);
        };
    }

    @Provider
    public DidPublicKeyResolver didPublicKeyResolver(ServiceExtensionContext context) {
        var ecKey = key(context);
        // Any keyId resolves to the runtime's own public key (verification is mocked).
        return keyId -> {
            try {
                return Result.success(ecKey.toPublicKey());
            } catch (JOSEException e) {
                return Result.failure(e.getMessage());
            }
        };
    }

    @Provider
    public AudienceResolver audienceResolver() {
        return remoteMessage -> Result.success(remoteMessage.getCounterPartyAddress());
    }

    // Normally provided by the EDC DCP DcpDefaultServicesExtension (excluded in the
    // fxmock runtime); the DSP core DspApiConfiguration extensions @Inject it. Extract
    // the counter-party participant id from the MembershipCredential the mock injected.
    @Provider
    public DefaultParticipantIdExtractionFunction participantIdExtractionFunction() {
        return claimToken -> {
            var claim = claimToken.getClaim("vc");
            if (claim instanceof List<?> list && !list.isEmpty() && list.get(0) instanceof VerifiableCredential vc
                    && !vc.getCredentialSubject().isEmpty()) {
                return vc.getCredentialSubject().get(0).getId();
            }
            return null;
        };
    }

    private synchronized ECKey key(ServiceExtensionContext context) {
        if (key == null) {
            kid = context.getConfig().getString(ISSUER_ID) + "#key-1";
            try {
                key = new ECKeyGenerator(Curve.P_256).keyID(kid).generate();
            } catch (JOSEException e) {
                throw new RuntimeException(e);
            }
        }
        return key;
    }
}
