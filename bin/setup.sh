#!/usr/bin/env bash
# bin/setup.sh — install Erlang/OTP + Elixir + Hex on Ubuntu 24.04.
#
# Tested combo: Erlang/OTP 25.3 (apt) + Elixir 1.18.4 (precompiled) + Hex 2.4.1.
# Jido v2.2 + jido_ai v2.1 require Elixir ~> 1.18, OTP 25-27.
#
# Run from any directory. Requires sudo.
#
# After this completes, run from the project root:
#   mix deps.get && mix compile && mix test

set -euo pipefail

ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4}"
ELIXIR_OTP_BUILD="${ELIXIR_OTP_BUILD:-25}"  # matches the elixir-otp-NN.zip artifact
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Installing Erlang/OTP from apt..."
sudo apt-get update -q
sudo apt-get install -y -q \
  erlang-base erlang-dev erlang-eunit erlang-parsetools \
  erlang-public-key erlang-ssl erlang-inets erlang-crypto \
  erlang-tools build-essential unzip curl

echo "==> Downloading Elixir ${ELIXIR_VERSION} (otp-${ELIXIR_OTP_BUILD})..."
curl -fsSL -o "$TMP/elixir.zip" \
  "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${ELIXIR_OTP_BUILD}.zip"
sudo rm -rf /usr/local/elixir
sudo unzip -q "$TMP/elixir.zip" -d /usr/local/elixir
for bin in elixir elixirc iex mix; do
  sudo ln -sf "/usr/local/elixir/bin/$bin" "/usr/local/bin/$bin"
done

echo "==> Versions installed:"
erl -eval 'io:format("Erlang/OTP ~s, ERTS ~s~n", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().' -noshell
elixir --version

echo "==> Installing Hex (from github, since repo.hex.pm requires CSV download)..."
mix archive.install github hexpm/hex branch latest --force

echo ""
echo "Done. From the project root run:  mix deps.get && mix compile && mix test"
echo ""
echo "Note: if you are behind a TLS-intercepting proxy with non-strict CA,"
echo "you may need: 'export HEX_UNSAFE_HTTPS=1' before mix deps.get."
