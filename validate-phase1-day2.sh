#!/bin/bash

# ==============================================================================
# Phase 1 Day 2: K3s + Longhorn Validation Script
# ==============================================================================
# This script runs 5 essential checks to validate the health of the K3s
# cluster, storage systems, and Ansible configuration.
#
# Usage: ./validate-phase1-day2.sh
# ==============================================================================

# --- Configuration ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color
KUBE_SYSTEM_NS="kube-system"
LONGHORN_SYSTEM_NS="longhorn-system"

# --- Helper Functions ---
print_check() {
    printf "\n--- CHECK %s: %s ---\\n" "$1" "$2"
}

print_result() {
    if [ "$1" -eq 0 ]; then
        printf "${GREEN}[PASS]${NC} - %s\n" "$2"
        return 0
    else
        printf "${RED}[FAIL]${NC} - %s\n" "$2"
        return 1
    fi
}

# --- Validation Checks ---

# CHECK 1: Node Ready
check_1() {
    print_check "1" "Node Ready"
    local output
    output=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')
    
    if [[ $(echo "$output" | awk '{print $2}') == "True" ]]; then
        print_result 0 "Node is Ready."
        echo "$output"
        return 0
    else
        print_result 1 "Node is not Ready."
        echo "$output"
        return 1
    fi
}

# CHECK 2: Core Pods Running
check_2() {
    print_check "2" "Core Pods Running in '$KUBE_SYSTEM_NS'"
    local not_running
    not_running=$(kubectl get pods -n "$KUBE_SYSTEM_NS" -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}')

    if [ -z "$not_running" ]; then
        print_result 0 "All pods in '$KUBE_SYSTEM_NS' are Running."
        return 0
    else
        print_result 1 "Some pods in '$KUBE_SYSTEM_NS' are not Running:"
        echo "$not_running"
        return 1
    fi
}

# CHECK 3: Longhorn Healthy
check_3() {
    print_check "3" "Longhorn Pods Healthy in '$LONGHORN_SYSTEM_NS'"
    local not_running
    not_running=$(kubectl get pods -n "$LONGHORN_SYSTEM_NS" -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}')

    if [ -z "$not_running" ]; then
        print_result 0 "All pods in '$LONGHORN_SYSTEM_NS' are Running."
        return 0
    else
        print_result 1 "Some pods in '$LONGHORN_SYSTEM_NS' are not Running:"
        echo "$not_running"
        return 1
    fi
}

# CHECK 4: Default StorageClass (Longhorn)
check_4() {
    print_check "4" "Default StorageClass is 'longhorn'"
    local default_sc
    default_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass.kubernetes.io/is-default-class=="true")].metadata.name}')

    if [[ "$default_sc" == "longhorn" ]]; then
        print_result 0 "Default StorageClass is correctly set to 'longhorn'."
        return 0
    else
        print_result 1 "Default StorageClass is '$default_sc', not 'longhorn'."
        return 1
    fi
}

# CHECK 5: Ansible Connectivity
check_5() {
    print_check "5" "Ansible Connectivity & Dry-Run"
    if ansible-playbook playbooks/00-k3s-server-n100.yml --check >/dev/null; then
        print_result 0 "Ansible playbook dry-run completed successfully."
        return 0
    else
        print_result 1 "Ansible playbook dry-run failed. Run 'ansible-playbook playbooks/00-k3s-server-n100.yml --check' for details."
        return 1
    fi
}

# --- Main Execution ---
main() {
    total_checks=5
    passed_checks=0
    failed_checks=0

    echo "================================================="
    echo " Starting K3s Phase 1 Day 2 Validation"
    echo "================================================="

    check_1 && ((passed_checks++)) || ((failed_checks++))
    check_2 && ((passed_checks++)) || ((failed_checks++))
    check_3 && ((passed_checks++)) || ((failed_checks++))
    check_4 && ((passed_checks++)) || ((failed_checks++))
    check_5 && ((passed_checks++)) || ((failed_checks++))

    echo ""
    echo "================================================="
    echo " Validation Summary"
    echo "================================================="
    printf "Total Checks: %d\n" "$total_checks"
    printf "${GREEN}Passed: %d${NC}\n" "$passed_checks"
    printf "${RED}Failed: %d${NC}\n" "$failed_checks"
    echo "================================================="

    if [ "$failed_checks" -ne 0 ]; then
        exit 1
    fi
    exit 0
}

main
