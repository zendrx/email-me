# Build stage
FROM crystallang/crystal:1.13.1-alpine AS builder

WORKDIR /app

# Copy dependency files first for better caching
COPY shard.yml ./
RUN shards install --production

# Copy source code
COPY . .

# Build the application
RUN crystal build src/server.cr --release --static -o bin/emailme

# Runtime stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    libgcc \
    libstdc++ \
    openssl \
    ca-certificates \
    tzdata

WORKDIR /app

# Copy built binary from builder
COPY --from=builder /app/bin/emailme .

# Copy any static assets/views if needed
COPY --from=builder /app/views ./views
COPY --from=builder /app/public ./public

# Set environment (Render will override these)
ENV PORT=3000

EXPOSE 3000

# Run the application
CMD ["./emailme"]
