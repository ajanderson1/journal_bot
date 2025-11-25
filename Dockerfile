FROM python:3.11-slim

# OCI Image Labels
LABEL org.opencontainers.image.title="Journal Bot"
LABEL org.opencontainers.image.description="A Telegram bot connecting a Git-backed journal to Claude AI CLI"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.authors="AJ Anderson"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/ajanderson/journal-bot"

# Install system tools
RUN apt-get update && apt-get install -y \
    git \
    curl \
    nodejs \
    npm \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user matching Raspberry Pi standard user (UID 1000)
# This prevents permission issues with the git repo
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN groupadd -g ${GROUP_ID} botuser && \
    useradd -m -u ${USER_ID} -g ${GROUP_ID} botuser

# Set up working directory
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy bot code and license
COPY bot.py LICENSE ./

# Create mount points with correct permissions and fix app permissions
RUN mkdir /Journal && chown botuser:botuser /Journal && \
    mkdir /app/data && chown botuser:botuser /app/data && \
    chown -R botuser:botuser /app

# Switch to secure user
USER botuser
ENV HOME=/home/botuser
ENV PATH="/home/botuser/.local/bin:${PATH}"

CMD ["python", "bot.py"]