# Stage 1: Build the application
FROM debian:bookworm-slim AS builder

# Install dependencies required to download and extract Zig
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Set Zig version
ARG ZIG_VERSION=0.15.2
ARG ZIG_URL=https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz

# Download and extract Zig
WORKDIR /usr/local
RUN curl -L ${ZIG_URL} -o zig.tar.xz && \
    tar -xf zig.tar.xz && \
    mv zig-x86_64-linux-${ZIG_VERSION} zig && \
    rm zig.tar.xz

# Add Zig to PATH
ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /app

# Copy the build files
COPY build.zig build.zig.zon ./

# Copy the source code
COPY src/ src/

# Build the application
# -Doptimize=ReleaseSafe: Optimizes for safety and speed
# -Dtarget=x86_64-linux-musl: Statically links for Alpine Linux compatibility
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# Stage 2: Create the minimal runtime image
FROM alpine:latest

WORKDIR /app

# Copy the compiled binary from the builder stage
COPY --from=builder /app/zig-out/bin/jolzz_server .

# Create a non-root user for security
RUN addgroup -S jolzz && adduser -S jolzz -G jolzz
USER jolzz

# Expose the server port
EXPOSE 3333

# Run the server
CMD ["./jolzz_server"]
