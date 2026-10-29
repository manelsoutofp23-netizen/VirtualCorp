#!/usr/bin/env bash

# Paràmetres globals de configuració
SSH_USER="${SSH_USER:-sysadmin}"

# Carregar funcions i variables entorn
source "$SCRIPT_DIR/common.sh"

# =========================
# DOWNLOAD CHR
# =========================
download_vdi() {
    if [[ ! -f "$ROUTEROS_VDI_PATH" ]]; then
        local image_dir
        local zip_file
        image_dir="$(dirname "$ROUTEROS_VDI_PATH")"
        mkdir -p "$image_dir"

        log_info "Downloading CHR..."
        zip_file="${image_dir}/chr.zip"

        curl -L "$URL" -o "$zip_file"
        unzip -o "$zip_file" -d "$image_dir"
        rm -f "$zip_file"
    fi
}

# Funció per verificar dependències i fitxers
check_prerequisites() {

    download_vdi

    if [[ ! -f "$ROUTEROS_VDI_PATH" ]]; then
        log_err "No s'ha trobat la imatge disc de base a '$ROUTEROS_VDI_PATH'."
        exit 1
    fi
}


# =========================================================
# CREACIÓ DE LA PLANTILLA (TEMPLATE)
# =========================================================
create_router_template() {
    local template_name="${VM_NAME:-routeros_template}"
    local router_nics="${ROUTER_NICS:-8}"

    # Validació bàsica
    if ! [[ "$router_nics" =~ ^[1-8]$ ]]; then
        log_error "ROUTER_NICS ha de ser un valor entre 1 i 8."
        return 1
    fi

    # Si la plantilla ja existeix, s'omet la creació
    if "$VBOXMANAGE_BIN" showvminfo "$template_name" &>/dev/null; then
        log_info "La plantilla '$template_name' ja existeix. S'omet la seva creació."
        return 0
    fi

    # =========================
    # CREATE VM
    # =========================

    log_info "Creating RouterOS template with $router_nics network interfaces"

    "$VBOXMANAGE_BIN" createvm --name "$VM_NAME" --register \
        --memory "$ROUTER_MEMORY" \
        --cpus "$ROUTER_CPU" \
        --groups "$VM_ROUTERS_GROUP"

    "$VBOXMANAGE_BIN" modifyvm "$VM_NAME" \
        --groups "$VM_ROUTERS_GROUP"


    # NIC2..NICN = Internal Network
    #
    # No importa en aquesta fase quina xarxa interna utilitzin.
    # El objetivo es que RouterOS detecti totes les NIC des del
    # primer arranque de la plantilla.
    for ((nic=2; nic<=router_nics; nic++)); do
        "$VBOXMANAGE_BIN" modifyvm "$VM_NAME" \
            "--nic${nic}" intnet \
            "--intnet${nic}" "routeros-template-unused"
    done

    # SSH temporal de la NIC1 NAT
    "$VBOXMANAGE_BIN" modifyvm "$VM_NAME" \
        --natpf1 "ssh,tcp,127.0.0.1,${SSH_PORT},,22"

    # =========================
    # STORAGE
    # =========================

    "$VBOXMANAGE_BIN" storagectl "$VM_NAME" \
        --name "SATA" \
        --add sata \
        --controller IntelAhci

    VM_DIR=$(dirname "$("$VBOXMANAGE_BIN" showvminfo "$VM_NAME" --machinereadable \
        | grep "CfgFile=" \
        | cut -d'"' -f2)")

    "$VBOXMANAGE_BIN" clonemedium disk \
        "$ROUTEROS_VDI_PATH" \
        "$VM_DIR/$ROUTEROS_VDI_FILENAME"

    "$VBOXMANAGE_BIN" storageattach "$VM_NAME" \
        --storagectl "SATA" \
        --port 0 \
        --device 0 \
        --type hdd \
        --medium "$VM_DIR/$ROUTEROS_VDI_FILENAME"

    # =========================
    # START VM
    # =========================

    log_info "Starting VM"

    "$VBOXMANAGE_BIN" startvm "$VM_NAME" --type headless

    # =========================
    # WAIT SSH
    # =========================

    log_info "Cleaning SSH known_hosts entry"

    ssh-keygen -R "[127.0.0.1]:$SSH_PORT" 2>/dev/null || true

    wait_ssh 127.0.0.1 "$SSH_PORT"

    # =========================
    # PROVISION ROUTEROS
    # =========================

    log_info "Configuring RouterOS users + SSH"

    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" \
        admin@127.0.0.1 <<EOF

# enable SSH service
/ip service enable ssh
/ip ssh set password-authentication=yes

# create sysadmin user
/user add name=sysadmin group=full password="Asdqwe!23" comment="sysadmin user" disabled=no

# create vcorp_auditor user
/user add name=vcorp_auditor group=full password="Asdqwe!23" comment="sysadmin user" disabled=no

EOF

    # =========================
    # INSTALL SYSADMIN KEY
    # =========================

    log_info "Injecting sysadmin key"

    scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -P "$SSH_PORT" \
        "$SSH_PUBLIC_KEY_DIR/vcorp_sysadmin.pub" \
        admin@127.0.0.1:sysadmin.pub

    scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -P "$SSH_PORT" \
        "$SSH_PUBLIC_KEY_DIR/vcorp_auditor.pub" \
        admin@127.0.0.1:vcorp_auditor.pub

    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" \
        admin@127.0.0.1 <<EOF

/user ssh-keys import user=sysadmin public-key-file=sysadmin.pub
/user ssh-keys import user=vcorp_auditor public-key-file=vcorp_auditor.pub

EOF

    # =========================
    # SHOW INTERFACES
    # =========================

    log_info "Checking RouterOS interfaces before shutdown"

    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" \
        admin@127.0.0.1 \
        "/interface print detail"

    # =========================
    # SHUTDOWN
    # =========================

    log_info "Shutting down VM"

    "$VBOXMANAGE_BIN" controlvm "$VM_NAME" acpipowerbutton || true
    sleep 20

    # =========================
    # SNAPSHOT
    # =========================

    log_info "Creant la plantilla RouterOS '$template_name' al grup '$TEMPLATE_GROUP'..."

    log_info "Creant snapshot base a la plantilla per a permetre clons enllaçats..."

    "$VBOXMANAGE_BIN" snapshot "$template_name" take "BaseSnapshot" \
        --description "Snapshot base per a clons enllaçats"

    log_ok "Plantilla '$template_name' creada correctament amb $router_nics interfícies."
}

# =========================================================
# VALIDACIONS
# =========================================================

validate_router_nics() {
    local router_nics="$1"

    if ! [[ "$router_nics" =~ ^[1-8]$ ]]; then
        log_error "ROUTER_NICS ha de ser un valor entre 1 i 8."
        return 1
    fi
}


router_exists() {
    local name="$1"

    "$VBOXMANAGE_BIN" showvminfo "$name" &>/dev/null
}


validate_router_config() {
    local router_nics="$1"
    local intnets_name="$2"
    local ips_name="$3"

    # Recuperem els arrays mitjançant nameref
    local -n ref_intnets="$intnets_name"
    local -n ref_ips="$ips_name"

    # NIC1 queda reservada per a la interfície de management/NAT.
    #
    # Per tant, com a màxim podem configurar:
    #
    #   ether2 ... etherN
    #
    local max_internal_nics=$((router_nics - 1))

    if (( ${#ref_intnets[@]} > max_internal_nics )); then
        log_error \
            "S'han especificat ${#ref_intnets[@]} xarxes internes, " \
            "però només hi ha $max_internal_nics NICs disponibles " \
            "(NIC2..NIC${router_nics})."
        return 1
    fi

    if (( ${#ref_intnets[@]} != ${#ref_ips[@]} )); then
        log_error \
            "--intnets i --ips han de tenir el mateix nombre d'elements."
        return 1
    fi

    return 0
}

# =========================================================
# PARSEIG DELS ARGUMENTS
# =========================================================

parse_router_args() {
    local -n ref_intnets="$1"
    local -n ref_ips="$2"
    local -n ref_nat="$3"
    local -n ref_gateway="$4"

    shift 4

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --intnets)
                shift
                while [[ $# -gt 0 && "$1" != --* ]]; do
                    ref_intnets+=("$1")
                    shift
                done
                ;;

            --ips)
                shift
                while [[ $# -gt 0 && "$1" != --* ]]; do
                    ref_ips+=("$1")
                    shift
                done
                ;;

            --nat)
                ref_nat=true
                shift
                ;;

            --gateway)
                if [[ $# -lt 2 ]]; then
                    log_error "--gateway requereix un valor."
                    return 1
                fi

                ref_gateway="$2"
                shift 2
                ;;

            *)
                log_error "Opció desconeguda: $1"
                return 1
                ;;
        esac
    done
}


# =========================================================
# CREACIÓ DE LA VM
# =========================================================

create_router_vm() {
    local name="$1"
    local router_nics="$2"
    local ssh_port="$3"

    log_info "Creant VM '$name'"

    "$VBOXMANAGE_BIN" createvm \
        --name "$name" \
        --register

    "$VBOXMANAGE_BIN" modifyvm "$name" \
        --memory "$ROUTER_MEMORY" \
        --cpus "$ROUTER_CPU" \
        --groups "$VM_ROUTERS_GROUP" || return 1

    configure_router_nics \
        "$name" \
        "$router_nics" || return 1

    # NIC1 = NAT temporal per poder fer el bootstrap per SSH
    log_info "Configurant NAT temporal per SSH: localhost:$ssh_port → RouterOS:22"

    "$VBOXMANAGE_BIN" modifyvm "$name" \
        --natpf1 "ssh,tcp,127.0.0.1,${ssh_port},,22" || return 1
}


# =========================================================
# CONFIGURACIÓ DE LES NICs
# =========================================================

configure_router_nics() {
    local name="$1"
    local router_nics="$2"

    log_info "Configurant $router_nics interfícies de xarxa"

    # -----------------------------------------------------
    # NIC1
    # -----------------------------------------------------
    #
    # NAT temporal.
    #
    # Aquesta NIC és la que permet fer el bootstrap inicial
    # de RouterOS abans de connectar-la a la xarxa definitiva.
    #
    "$VBOXMANAGE_BIN" modifyvm "$name" \
        --nic1 nat \
        --cableconnected1 on || return 1


    # -----------------------------------------------------
    # NIC2..NICN
    # -----------------------------------------------------
    #
    # Inicialment les deixem desconnectades.
    #
    # Posteriorment configure_router_internal_networks()
    # les connectarà a les xarxes intnet corresponents.
    #
    for ((nic=2; nic<=router_nics; nic++)); do

        "$VBOXMANAGE_BIN" modifyvm "$name" \
            "--nic${nic}" intnet \
            "--intnet${nic}" "unused${nic}" \
            "--cableconnected${nic}" off \
            || return 1

    done
}


# =========================================================
# CONFIGURACIÓ DE LES XARXES INTERNES
# =========================================================

configure_router_internal_networks() {
    local name="$1"
    local intnets_name="$2"

    local -n ref_intnets="$intnets_name"

    local nic_idx=2

    for net in "${ref_intnets[@]}"; do

        log_info "NIC${nic_idx} → xarxa interna '$net'"

        "$VBOXMANAGE_BIN" modifyvm "$name" \
            "--nic${nic_idx}" intnet \
            "--intnet${nic_idx}" "$net" \
            "--cableconnected${nic_idx}" on \
            || return 1

        ((nic_idx++))
    done
}


# =========================================================
# STORAGE
# =========================================================

attach_router_disk() {
    local name="$1"

    local vm_dir
    local disk_path

    log_info "Configurant storage"

    "$VBOXMANAGE_BIN" storagectl "$name" \
        --name "SATA" \
        --add sata \
        --controller IntelAhci \
        || return 1

    vm_dir="$(
        "$VBOXMANAGE_BIN" showvminfo "$name" --machinereadable |
            grep '^CfgFile=' |
            cut -d'"' -f2
    )"

    if [[ -z "$vm_dir" ]]; then
        log_error "No s'ha pogut determinar el directori de la VM '$name'."
        return 1
    fi

    vm_dir="$(dirname "$vm_dir")"

    disk_path="$vm_dir/$ROUTEROS_VDI_FILENAME"

    log_info "Clonant VDI RouterOS → $disk_path"

    "$VBOXMANAGE_BIN" clonemedium disk \
        "$ROUTEROS_VDI_PATH" \
        "$disk_path" \
        || return 1

    "$VBOXMANAGE_BIN" storageattach "$name" \
        --storagectl "SATA" \
        --port 0 \
        --device 0 \
        --type hdd \
        --medium "$disk_path" \
        || return 1
}


# =========================================================
# BOOTSTRAP DE ROUTEROS
# =========================================================

bootstrap_routeros() {
    local name="$1"
    local ssh_port="$2"

    log_info "Arrencant '$name' per fer el bootstrap"
    "$VBOXMANAGE_BIN" startvm "$name" --type headless || return 1

    log_info "Esperant SSH de RouterOS a 127.0.0.1:$ssh_port"

    ssh-keygen -R "[127.0.0.1]:$ssh_port" 2>/dev/null || true

    wait_ssh 127.0.0.1 "$ssh_port" || {
        log_error "No s'ha pogut establir SSH amb '$name'."
        return 1
    }


    # -----------------------------------------------------
    # Crear usuari sysadmin
    # -----------------------------------------------------

    log_info "Configurant usuari sysadmin"

    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$ssh_port" \
        admin@127.0.0.1 <<'EOF'

/ip service enable ssh
/ip ssh set password-authentication=yes
/user add name=sysadmin group=full password="Asdqwe!23" comment="sysadmin user" disabled=no

# create vcorp_auditor user
/user add name=vcorp_auditor group=full password="Asdqwe!23" comment="sysadmin user" disabled=no


EOF

    if [[ $? -ne 0 ]]; then
        log_err "No s'ha pogut crear l'usuari sysadmin."
        return 1
    fi


    # -----------------------------------------------------
    # Instal·lar clau pública
    # -----------------------------------------------------

    log_info "Injectant clau SSH de sysadmin"

    scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -P "$ssh_port" \
        "$SSH_PUBLIC_KEY_DIR/vcorp_sysadmin.pub" \
        admin@127.0.0.1:sysadmin.pub \
        || return 1

    # Subir la nueva clave
    scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -P "$ssh_port" \
        "$SSH_PUBLIC_KEY_DIR/vcorp_auditor.pub" \
        admin@127.0.0.1:vcorp_auditor.pub \
        || return 1

    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$ssh_port" \
        admin@127.0.0.1 <<'EOF'

/user ssh-keys import user=sysadmin public-key-file=sysadmin.pub
/user ssh-keys import user=vcorp_auditor public-key-file=vcorp_auditor.pub

EOF

    if [[ $? -ne 0 ]]; then
        log_err "No s'ha pogut instal·lar la clau SSH."
        return 1
    fi

    log_ok "Bootstrap de '$name' completat"
}


# =========================================================
# GENERACIÓ DE CONFIGURACIÓ ROUTEROS
# =========================================================

generate_router_config() {
    local rsc_file="$1"
    local gateway="$2"
    local ips_name="$3"
    local nat=$4
    local name=$5

    local -n ref_ips="$ips_name"

    # Comencem amb un fitxer buit
    : > "$rsc_file"

    # -----------------------------------------------------
    # Default gateway
    # -----------------------------------------------------

    if [[ -n "$gateway" ]]; then

        cat >> "$rsc_file" <<EOF
/ip route add dst-address=0.0.0.0/0 gateway=$gateway
EOF

    fi

    # -----------------------------------------------------
    # Adreces IP
    # -----------------------------------------------------

    local idx
    local ether_iface

    for idx in "${!ref_ips[@]}"; do

        ether_iface="ether$((idx + 2))"

        cat >> "$rsc_file" <<EOF
/ip address add address=${ref_ips[$idx]} interface=${ether_iface}
EOF

    done

    # -----------------------------------------------------
    # RIP & hostname
    # -----------------------------------------------------

    cat >> "$rsc_file" <<EOF
/system identity set name="$name"
/routing rip instance add name=rip1 redistribute=connected,rip
EOF

    for idx in "${!ref_ips[@]}"; do

        ether_iface="ether$((idx + 2))"

        cat >> "$rsc_file" <<EOF
/routing rip interface-template add instance=rip1 interfaces=${ether_iface}
EOF

    done

    if [[ "$nat" == true ]]; then
        cat >> "$rsc_file" <<EOF
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
EOF
    fi

}

# =========================================================
# APLICACIÓ DE LA CONFIGURACIÓ ROUTEROS
# =========================================================

apply_router_config() {
    local name="$1"
    local ssh_port="$2"
    local gateway="$3"
    local ips_name="$4"
    local nat="$5"

    local rsc_file="/tmp/${name}_config.rsc"

    log_info "Generant configuració RouterOS $name"

    generate_router_config \
        "$rsc_file" \
        "$gateway" \
        "$ips_name" \
        "$nat" \
        "$name" \
        || return 1


    # -----------------------------------------------------
    # Pujar configuració
    # -----------------------------------------------------

    log_info "Pujant configuració RSC a '$name'"

    scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$SYSADMIN_PRIVATE_KEY_FILE" \
        -P "$ssh_port" \
        "$rsc_file" \
        "$SSH_USER@127.0.0.1:/config.rsc" \
        || {
            rm -f "$rsc_file"
            return 1
        }


    # -----------------------------------------------------
    # Importar configuració
    # -----------------------------------------------------

    log_info "Aplicant configuració RSC"

    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$SYSADMIN_PRIVATE_KEY_FILE" \
        -p "$ssh_port" \
        "$SSH_USER@127.0.0.1" \
        "/import file-name=config.rsc" \
        || {
            rm -f "$rsc_file"
            return 1
        }


    rm -f "$rsc_file"

    log_ok "Configuració RouterOS aplicada"
}


# =========================================================
# CONFIGURACIÓ FINAL DE LA NIC1
# =========================================================

configure_final_network() {
    local name="$1"
    local nat="$2"
    local intnets_name="$3"

    local -n ref_intnets="$intnets_name"

    # Si es demana conservar NAT, no fem res.
    if [[ "$nat" == true ]]; then
        log_info "NIC1 es manté en mode NAT"
        return 0
    fi

    # NIC1 serà la primera xarxa interna especificada.
    local initial_intnet="${ref_intnets[0]}"

    if [[ -z "$initial_intnet" ]]; then
        log_warn "No s'ha especificat xarxa per a NIC1."
        return 0
    fi

    log_info "NIC1 → xarxa interna definitiva '$initial_intnet'"

    "$VBOXMANAGE_BIN" modifyvm "$name" \
        --nic1 intnet \
        --intnet1 "$initial_intnet" \
        --cableconnected1 on \
        || return 1
}


# =========================================================
# CREACIÓ D'UN ROUTER CONCRET
# =========================================================

create_router() {

    local router_nics="${ROUTER_NICS:-8}"

    local name="$1"
    local ssh_port="$2"

    if [[ -z "$name" || -z "$ssh_port" ]]; then
        log_error "Ús: create_router <name> <ssh_port> [opcions]"
        return 1
    fi

    shift 2


    # -----------------------------------------------------
    # VALIDACIONS
    # -----------------------------------------------------

    validate_router_nics "$router_nics" || return 1


    # -----------------------------------------------------
    # PARÀMETRES DE CONFIGURACIÓ
    # -----------------------------------------------------

    local intnets=()
    local ips=()
    local nat=false
    local gateway=""

    parse_router_args \
        intnets \
        ips \
        nat \
        gateway \
        "$@" \
        || return 1


    validate_router_config \
        "$router_nics" \
        intnets \
        ips \
        || return 1


    # -----------------------------------------------------
    # COMPROVAR SI JA EXISTEIX
    # -----------------------------------------------------

    if router_exists "$name"; then

        log_warn \
            "El router '$name' ja existeix. " \
            "S'omet el desplegament."

        return 0
    fi


    # -----------------------------------------------------
    # INFORMACIÓ
    # -----------------------------------------------------

    log_info "=========================================="
    log_info "Desplegant router: $name"
    log_info "=========================================="


    # -----------------------------------------------------
    # 1. CREAR VM
    # -----------------------------------------------------

    create_router_vm \
        "$name" \
        "$router_nics" \
        "$ssh_port" \
        || return 1


    # -----------------------------------------------------
    # 2. CONFIGURAR STORAGE
    # -----------------------------------------------------

    attach_router_disk \
        "$name" \
        || return 1


    # -----------------------------------------------------
    # 3. CONFIGURAR XARXES INTERNES
    # -----------------------------------------------------

    configure_router_internal_networks \
        "$name" \
        intnets \
        || return 1


    # -----------------------------------------------------
    # 4. BOOTSTRAP ROUTEROS
    # -----------------------------------------------------

    bootstrap_routeros \
        "$name" \
        "$ssh_port" \
        || return 1


    # -----------------------------------------------------
    # 5. CONFIGURACIÓ ROUTEROS
    # -----------------------------------------------------

    apply_router_config \
        "$name" \
        "$ssh_port" \
        "$gateway" \
        ips \
        "$nat" \
        || return 1


    # -----------------------------------------------------
    # 6. APAGAR ROUTER
    # -----------------------------------------------------

    log_info "Apagant '$name'"

    "$VBOXMANAGE_BIN" controlvm "$name" acpipowerbutton || {
        log_warn "No s'ha pogut enviar ACPI shutdown a '$name'."
    }


    # -----------------------------------------------------
    # 7. ESPERAR APAGADA
    # -----------------------------------------------------

    log_info "Esperant que '$name' s'apagui..."

    while true; do

        local vm_state

        vm_state="$(
            "$VBOXMANAGE_BIN" showvminfo "$name" --machinereadable |
                grep '^VMState=' |
                cut -d'"' -f2
        )"

        if [[ "$vm_state" == "poweroff" ]]; then
            break
        fi

        sleep 2
    done


    # -----------------------------------------------------
    # 8. CONFIGURACIÓ FINAL DE NIC1
    # -----------------------------------------------------

    configure_final_network \
        "$name" \
        "$nat" \
        intnets \
        || return 1


    log_ok \
        "Router '$name' creat i configurat correctament."
}

