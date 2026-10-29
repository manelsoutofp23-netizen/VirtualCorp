#!/usr/bin/env bash

set -e

# Carregar les funcions d'ajuda
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/router_base.sh"


check_prerequisites

# Crea el template pel router
# create_router_template

# Desplegament de mikrotik0
create_router "mikrotik0" 2200 \
  --intnets "r0-r1" "dmz" \
  --ips "10.26.0.225/30" "10.26.0.193/27" \
  --nat

# Desplegament de mikrotik1
create_router "mikrotik1" 2201 \
  --intnets "r0-r1" "r1-r2" "pl0" \
  --ips "10.26.0.226/30" "10.26.0.229/30" "10.26.0.1/25" \
  --gateway "10.26.0.225"

# Desplegament de mikrotik2
create_router "mikrotik2" 2202 \
  --intnets "r1-r2" "r2-r3" "pl1" "pl2" \
  --ips "10.26.0.230/30" "10.26.0.233/30" "10.26.1.1/24" "10.26.2.1/24" \
  --gateway "10.26.0.229"

# Desplegament de mikrotik3
create_router "mikrotik3" 2203 \
  --intnets "r2-r3" "pl3" "pl3-direccio" \
  --ips "10.26.0.234/30" "10.26.3.1/25" "10.26.3.129/25" \
  --gateway "10.26.0.233"

log_info "=========================================="
log_info "[+] Routers desplegats correctament."
log_info "=========================================="
