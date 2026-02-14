FROM mcr.microsoft.com/devcontainers/go:1.22

# Install tools needed for root image building and testing
RUN apt-get update && apt-get install -y --no-install-recommends \
    e2fsprogs \
    && rm -rf /var/lib/apt/lists/*
