FROM ghcr.io/astral-sh/uv:0.13.10@sha256:a3ea1357342c1a4bf9a0c53a3deb1b55379aefa037338d8113d5771efa01774f AS uv

FROM mcr.microsoft.com/devcontainers/base:3.0.14-noble@sha256:88171bb581e19bbb45db77a16a3a5475e2f9ddce025b044c2e5a69a6a1e24fa1

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gh \
    && case "$(dpkg --print-architecture)" in \
        amd64) arch=x64 ;; \
        arm64) arch=arm64 ;; \
        *) exit 1 ;; \
    esac \
    && curl -fL "https://github.com/github/copilot-cli/releases/latest/download/copilot-linux-${arch}.tar.gz" -o /tmp/copilot.tar.gz \
    && tar -xzf /tmp/copilot.tar.gz -C /usr/local/bin copilot \
    && rm -f /tmp/copilot.tar.gz \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

# Install the tools (and the Python uv downloads for them) outside /home/vscode,
# so vscode can run them and they survive the home volume mount.
RUN export UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    && uv tool install commitizen \
    && uv tool install pre-commit

USER vscode
