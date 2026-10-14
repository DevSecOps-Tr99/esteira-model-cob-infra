#!/usr/bin/env bash
# Registra a VM como self-hosted runner do repositorio e instala como
# servico systemd (sobrevive a reboot e ao auto-shutdown).
#
# Executado como root via "az vm run-command invoke" por
# provisionar.ps1. Uso:
#   registrar-runner.sh <url-do-repo> <token-de-registro> <nome> <labels>
set -euo pipefail

REPO_URL="$1"
REG_TOKEN="$2"
RUNNER_NAME="$3"
RUNNER_LABELS="$4"
RUNNER_DIR=/opt/actions-runner

# cloud-init pode ainda estar instalando pacotes na primeira subida
cloud-init status --wait >/dev/null || true

cd "$RUNNER_DIR"

if [ -f .runner ]; then
  ./svc.sh stop || true
  ./svc.sh uninstall || true
  sudo -u ghrunner ./config.sh remove --token "$REG_TOKEN" || rm -f .runner .credentials .credentials_rsaparams
fi

if [ ! -x ./config.sh ]; then
  VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
  curl -fsSL -o runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-x64-${VERSION}.tar.gz"
  tar xzf runner.tar.gz
  rm runner.tar.gz
  chown -R ghrunner:ghrunner "$RUNNER_DIR"
  ./bin/installdependencies.sh
fi

sudo -u ghrunner ./config.sh \
  --unattended \
  --replace \
  --url "$REPO_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work _work

./svc.sh install ghrunner
./svc.sh start
./svc.sh status --no-pager | head -n 5
