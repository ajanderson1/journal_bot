FROM python:3.11-slim

# OCI Image Labels
LABEL org.opencontainers.image.title="Journal Bot"
LABEL org.opencontainers.image.description="A Telegram bot connecting a Git-backed journal to Claude AI CLI"
LABEL org.opencontainers.image.version="1.2.0"
LABEL org.opencontainers.image.authors="AJ Anderson"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/ajanderson/journal-bot"

# Install system tools including gosu for UID switching
RUN apt-get update && apt-get install -y \
    git \
    curl \
    nodejs \
    npm \
    sudo \
    gosu \
    && rm -rf /var/lib/apt/lists/* \
    && gosu --version

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user with default UID 1000
# The entrypoint will adjust UID/GID at runtime to match host volumes
RUN groupadd -g 1000 botuser && \
    useradd -m -u 1000 -g botuser -s /bin/bash botuser

# Set up working directory
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy bot code, license, and entrypoint
COPY bot.py LICENSE ./
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create mount points with default permissions (entrypoint will adjust at runtime)
RUN mkdir -p /Journal && chown botuser:botuser /Journal && \
    mkdir -p /app/data && chown botuser:botuser /app/data && \
    chown -R botuser:botuser /app

# Environment setup (no USER directive - entrypoint handles user switching with gosu)
ENV HOME=/home/botuser
ENV PATH="/home/botuser/.local/bin:${PATH}"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python", "bot.py"]