# syntax=docker/dockerfile:1

# Build stage
FROM swift:6.0-jammy AS build
WORKDIR /app

# Leverage Docker layer caching
COPY Package.* ./
RUN swift package resolve

# Copy sources and build
COPY Sources ./Sources
RUN swift build -c release --product KGProxy

# Runtime stage (use Swift slim to include Swift libs with minimal size)
FROM swift:6.0-jammy-slim AS runtime
WORKDIR /app
ENV PORT=8080
EXPOSE 8080

COPY --from=build /app/.build/release/KGProxy /app/KGProxy

ENTRYPOINT ["./KGProxy"]