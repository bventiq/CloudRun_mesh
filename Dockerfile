ARG MESHCENTRAL_VERSION=latest
FROM ghcr.io/ylianst/meshcentral:${MESHCENTRAL_VERSION}

# Switch to root to ensuring permission for install (if needed)
# However, standard practice for this image implies running as node.
# We will install dependencies in the meshcentral module directory.

USER root

# Pre-install dependencies for OIDC to prevent runtime installation
RUN cd ./node_modules/meshcentral && \
    npm install passport@0.7.0 connect-flash@0.1.1 openid-client@5.7.1

USER node
